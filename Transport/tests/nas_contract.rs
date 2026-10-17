//! Explicit, disposable-share integration test. Ignored by default.
use nas_transport::{CancellationToken, Connection, Error, Nas};
use smb2::{ClientConfig, ErrorKind, SmbClient};
use std::{io::Read, path::PathBuf};
use zeroize::Zeroizing;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a dedicated test share, NAS_TEST_ENABLE=1 and password on stdin"]
async fn signed_roundtrip_and_range_contract() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("NAS_TEST_ENABLE").as_deref() != Ok("1") {
        return Err("set NAS_TEST_ENABLE=1 only for the approved disposable test share".into());
    }
    let mut password = Zeroizing::new(String::new());
    std::io::stdin().take(4096).read_to_string(&mut password)?;
    while password.ends_with(['\r', '\n']) {
        password.pop();
    }
    let root = std::env::var("NAS_TEST_ROOT")?;
    // Independent signed session for the sharing-exclusion checks. Its writes
    // target disposable fixtures in the exact same explicit run directory.
    let mut other = SmbClient::connect(ClientConfig {
        addr: std::env::var("NAS_TEST_HOST")?,
        username: std::env::var("NAS_TEST_USER")?,
        password: password.to_string(),
        auto_reconnect: false,
        dfs_enabled: false,
        compression: false,
        response_timeout: Some(std::time::Duration::from_secs(5)),
        ..Default::default()
    })
    .await?;
    assert!(other.diagnostics().primary.signing.active);
    let other_tree = other
        .connect_share(&std::env::var("NAS_TEST_SHARE")?)
        .await?;
    let mut nas = Nas::connect(Connection {
        address: std::env::var("NAS_TEST_HOST")?,
        share: std::env::var("NAS_TEST_SHARE")?,
        username: std::env::var("NAS_TEST_USER")?,
        password,
        require_encryption: std::env::var("NAS_TEST_ENCRYPTION").as_deref() == Ok("1"),
        mutation_root: Some(root.clone()),
    })
    .await?;
    assert!(nas.security().signing);
    nas.prepare_experiment().await?;
    let work = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(".work")
        .join(format!("contract-{}", std::process::id()));
    tokio::fs::create_dir_all(&work).await?;
    let source = work.join("source.bin");
    let destination = work.join("range.bin");
    let full = work.join("full.bin");
    let data: Vec<u8> = (0..(nas_transport::CHUNK_BYTES * 10 + 17))
        .map(|i| (i % 251) as u8)
        .collect();
    tokio::fs::write(&source, &data).await?;
    let cancel = CancellationToken::new();
    let active_path = format!("{root}/contract-active-writer.bin");
    let mut active = other
        .create_file_writer_exclusive(&other_tree, &active_path)
        .await?;
    active.write_chunk(b"writer still owns this handle").await?;
    let denied_local = work.join("denied.bin");
    assert!(matches!(
        nas.download(&active_path, &denied_local, 0, None, &cancel, |_| {})
            .await,
        Err(Error::Smb(ErrorKind::SharingViolation))
    ));
    assert!(!denied_local.exists());
    active.finish().await?;
    nas.delete("contract-active-writer.bin", false).await?;
    assert_eq!(
        nas.upload(&source, "contract-original.bin", &cancel, |_| {})
            .await?,
        data.len() as u64
    );
    // An existing destination must survive a second upload attempt.
    tokio::fs::write(&source, b"replacement must never overwrite original").await?;
    assert!(nas
        .upload(&source, "contract-original.bin", &cancel, |_| {})
        .await
        .is_err());
    let offset = nas_transport::CHUNK_BYTES as u64 - 3;
    assert_eq!(
        nas.download(
            &format!("{root}/contract-original.bin"),
            &destination,
            offset,
            Some(12),
            &cancel,
            |_| {}
        )
        .await?
        .bytes,
        12
    );
    assert_eq!(
        tokio::fs::read(&destination).await?,
        data[offset as usize..offset as usize + 12]
    );
    let (start_writer, started) = tokio::sync::oneshot::channel();
    let (writer_result, wait_writer) = std::sync::mpsc::sync_channel(1);
    let busy_path = format!("{root}/contract-original.bin");
    let contender = tokio::spawn(async move {
        started.await?;
        let result = match other.create_file_writer(&other_tree, &busy_path).await {
            Err(error) => Some(error.kind()),
            Ok(writer) => {
                writer.abort().await?;
                None
            }
        };
        other.disconnect_share(&other_tree).await?;
        writer_result.send(result)?;
        Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
    });
    let mut start_writer = Some(start_writer);
    let hydrated = nas
        .download(
            &format!("{root}/contract-original.bin"),
            &full,
            0,
            None,
            &cancel,
            |_| {
                if let Some(start) = start_writer.take() {
                    start.send(()).expect("writer task still waiting");
                    // The second runtime worker attempts the conflicting open
                    // while this callback keeps the guarded read handle alive.
                    assert_eq!(
                        wait_writer
                            .recv_timeout(std::time::Duration::from_secs(8))
                            .unwrap(),
                        Some(ErrorKind::SharingViolation)
                    );
                }
            },
        )
        .await?;
    contender.await?.map_err(|error| error.to_string())?;
    assert_eq!(hydrated.bytes, data.len() as u64);
    assert_eq!(hydrated.entry.bytes, hydrated.bytes);
    assert!(hydrated.entry.index_number.is_some());
    assert_eq!(tokio::fs::read(&full).await?, data);
    nas.rename("contract-original.bin", "contract-renamed.bin", false)
        .await?;
    let mut found = false;
    let (_, complete) = nas
        .list(&root, None, &cancel, |batch| {
            found |= batch
                .iter()
                .any(|entry| entry.name == "contract-renamed.bin");
            Ok(())
        })
        .await?;
    assert!(found && complete);
    nas.delete("contract-renamed.bin", false).await?;
    nas.disconnect().await?;
    tokio::fs::remove_dir_all(&work).await?;
    Ok(())
}
