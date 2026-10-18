use super::*;
#[path = "guarded_download_test_peer.rs"]
mod peer;
use peer::*;
use smb2::{
    msg::{header::Header, read::ReadRequest},
    pack::{ReadCursor, Unpack},
    types::Command,
};
use std::{os::unix::fs::PermissionsExt, time::Duration};
fn strict() -> Purpose {
    Purpose::Strict {
        offset: 0,
        length: None,
    }
}

#[tokio::test]
async fn full_hydration_and_strict_ranges_share_real_bytes_progress_and_private_output() {
    for size in [0, 1, 65537] {
        for hydration in [false, true] {
            let fixture = Fixture::new().await;
            let config = Config::new((0..size).map(|i| (i % 251) as u8).collect());
            let mut progress = vec![];
            let (result, stats) = execute(
                &fixture,
                &config,
                "cafe\u{301}.txt",
                if hydration {
                    Purpose::Hydration
                } else {
                    strict()
                },
                &CancellationToken::new(),
                |n| progress.push(n),
            )
            .await;
            let result = result.unwrap();
            assert_eq!(result.bytes, size as u64);
            assert_eq!(result.entry.name.as_bytes(), "cafe\u{301}.txt".as_bytes());
            assert_eq!(std::fs::read(fixture.local.output()).unwrap(), config.body);
            assert_eq!(
                std::fs::metadata(fixture.local.output())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert_eq!(stats.snapshots, 2);
            assert_eq!(stats.closes, 1);
            if size == 0 {
                assert!(progress.is_empty());
            } else {
                assert_eq!(progress.last(), Some(&(size as u64)));
            }
            fixture.mock.assert_fully_consumed();
            fixture.mock.close();
        }
    }
    let fixture = Fixture::new().await;
    let config = Config::new(b"0123456789".to_vec());
    let (result, _) = execute(
        &fixture,
        &config,
        "file",
        Purpose::Strict {
            offset: 3,
            length: Some(4),
        },
        &CancellationToken::new(),
        |_| {},
    )
    .await;
    assert_eq!(result.unwrap().bytes, 4);
    assert_eq!(std::fs::read(fixture.local.output()).unwrap(), b"3456");
    fixture.mock.close();
}

#[tokio::test]
async fn default_only_hidden_readonly_system_ea_and_link_files_keep_both_read_purposes() {
    for (attributes, ea, links) in [(34, 0, 1), (33, 0, 1), (36, 0, 1), (32, 4, 1), (32, 0, 2)] {
        let mut config = Config::new(b"stage".to_vec());
        config.attributes = attributes;
        config.ea = ea;
        config.links = links;
        for hydration in [false, true] {
            let fixture = Fixture::new().await;
            let (result, stats) = execute(
                &fixture,
                &config,
                ".mydrive.stage",
                if hydration {
                    Purpose::Hydration
                } else {
                    strict()
                },
                &CancellationToken::new(),
                |_| {},
            )
            .await;
            let result = result.unwrap();
            assert_eq!(result.entry.attributes, attributes);
            assert_eq!(result.bytes, config.body.len() as u64);
            assert_eq!(stats.snapshots, 2);
            assert_eq!(stats.reads, 1);
            assert_eq!(stats.closes, 1);
            assert_eq!(std::fs::read(fixture.local.output()).unwrap(), config.body);
            fixture.mock.assert_fully_consumed();
            fixture.mock.close();
        }
    }
}

#[tokio::test]
async fn exact_provenance_is_only_a_hydration_sync_exclusion_on_a_qualifying_runtime() {
    let mut config = Config::new(b"body".to_vec());
    config.provenance = true;
    for hydration in [false, true] {
        let fixture = Fixture::new().await;
        let (result, stats) = execute(
            &fixture,
            &config,
            "file",
            if hydration {
                Purpose::Hydration
            } else {
                strict()
            },
            &CancellationToken::new(),
            |_| {},
        )
        .await;
        let permitted = hydration && crate::held_metadata::sync_exclusion_allowed();
        assert_eq!(result.is_ok(), permitted);
        assert_eq!(stats.reads, usize::from(permitted));
        assert_eq!(stats.closes, 1);
        assert_eq!(fixture.local.output().exists(), permitted);
        fixture.mock.close();
    }
}

#[tokio::test]
async fn provenance_exclusion_keeps_its_narrow_profile_before_any_body_read() {
    for (attributes, ea, links) in [(34, 0, 1), (33, 0, 1), (36, 0, 1), (32, 4, 1), (32, 0, 2)] {
        let mut config = Config::new(b"body".to_vec());
        config.provenance = true;
        config.attributes = attributes;
        config.ea = ea;
        config.links = links;
        let fixture = Fixture::new().await;
        let (result, stats) = execute(
            &fixture,
            &config,
            "file",
            Purpose::Hydration,
            &CancellationToken::new(),
            |_| {},
        )
        .await;
        assert!(result.is_err());
        assert_eq!(stats.reads, 0);
        assert_eq!(stats.closes, 1);
        assert!(!fixture.local.output().exists());
        fixture.mock.assert_fully_consumed();
        fixture.mock.close();
    }
}

#[tokio::test]
async fn changed_metadata_bad_commands_read_errors_or_terminal_failure_never_complete_output() {
    for fault in [
        Fault::AfterVersion,
        Fault::AfterEa,
        Fault::AfterStreams,
        Fault::MalformedClose,
        Fault::WrongClose,
        Fault::WrongCreate,
        Fault::WrongRead,
        Fault::ShortRead,
        Fault::DeniedRead,
    ] {
        let fixture = Fixture::new().await;
        let mut config = Config::new(b"body".to_vec());
        config.fault = fault;
        let (result, _) = execute(
            &fixture,
            &config,
            "file",
            Purpose::Hydration,
            &CancellationToken::new(),
            |_| {},
        )
        .await;
        assert!(result.is_err(), "{fault:?}");
        assert!(!fixture.local.output().exists(), "{fault:?}");
        fixture.mock.close();
    }
    let fixture = Fixture::new().await;
    let mut config = Config::new(b"body".to_vec());
    config.ea = 1;
    config.provenance = true;
    let (result, stats) = execute(
        &fixture,
        &config,
        "file",
        Purpose::Hydration,
        &CancellationToken::new(),
        |_| {},
    )
    .await;
    assert!(result.is_err());
    assert_eq!(stats.reads, 0);
    assert_eq!(stats.closes, 1);
    fixture.mock.close();
}

#[tokio::test]
async fn checked_parent_close_and_cancellation_during_first_create_read_or_close_are_terminal() {
    for fault in [
        Fault::ParentClose,
        Fault::CancelCreate,
        Fault::CancelRead,
        Fault::CancelClose,
    ] {
        let fixture = Fixture::new().await;
        let mut config = Config::new(b"body".to_vec());
        config.fault = fault;
        let cancel = CancellationToken::new();
        let (result, stats) = execute(
            &fixture,
            &config,
            "parent/file",
            Purpose::Hydration,
            &cancel,
            |_| {},
        )
        .await;
        assert!(result.is_err(), "{fault:?}");
        assert!(!fixture.local.output().exists());
        if fault == Fault::ParentClose {
            assert_eq!(stats.closes, 2);
        } else {
            assert!(matches!(result, Err(Error::Cancelled)));
        }
        assert!(fixture.connection.outstanding_requests().is_empty());
        fixture.mock.close();
    }
}

#[tokio::test]
async fn dropping_pending_first_ancestor_or_leaf_create_retires_connection_and_owned_output() {
    for remote in ["file", "parent/file"] {
        let fixture = Fixture::new().await;
        let cancel = CancellationToken::new();
        let output = fixture.local.output();
        let mut future = Box::pin(run(
            fixture.connection.clone(),
            &fixture.tree,
            remote,
            &output,
            Purpose::Hydration,
            &cancel,
            |_| {},
        ));
        tokio::select! {result=&mut future=>panic!("CREATE unexpectedly completed: {}",result.is_ok()),_=sent(&fixture.mock,1)=>{}}
        assert!(output.exists());
        drop(future);
        assert!(!output.exists());
        assert!(fixture.connection.outstanding_requests().is_empty());
        fixture.mock.close();
    }
}

#[tokio::test]
async fn exclusive_output_preserves_preexisting_and_replaced_names_on_all_cleanup_paths() {
    let fixture = Fixture::new().await;
    std::fs::write(fixture.local.output(), b"preexisting").unwrap();
    let (result, stats) = execute(
        &fixture,
        &Config::new(vec![]),
        "file",
        Purpose::Hydration,
        &CancellationToken::new(),
        |_| {},
    )
    .await;
    assert!(result.is_err());
    assert_eq!(stats.reads, 0);
    assert_eq!(fixture.mock.sent_count(), 0);
    assert_eq!(
        std::fs::read(fixture.local.output()).unwrap(),
        b"preexisting"
    );
    fixture.mock.close();

    let local = Local::new();
    let output = OwnedOutput::create(&local.output()).unwrap();
    std::fs::rename(local.output(), local.other()).unwrap();
    std::fs::write(local.output(), b"replacement").unwrap();
    drop(output);
    assert_eq!(std::fs::read(local.output()).unwrap(), b"replacement");
    assert!(local.other().exists());
}

#[tokio::test]
async fn staged_output_ownership_survives_outer_fence_close_and_does_not_unlink_a_replacement() {
    let fixture = Fixture::new().await;
    let config = Config::new(b"body".to_vec());
    let cancel = CancellationToken::new();
    // The outer read reservation models download_tree_scoped's retained scope.
    let done = CancellationToken::new();
    let operation = async {
        let outer = crate::mutation_io::MutationIO::for_read(
            fixture.connection.clone(),
            &fixture.tree,
            "outer/file",
            &cancel,
        )
        .await
        .unwrap();
        let staged = run(
            fixture.connection.clone(),
            &fixture.tree,
            "file",
            &fixture.local.output(),
            strict(),
            &cancel,
            |_| {},
        )
        .await
        .unwrap();
        let closing = outer.close_checked();
        tokio::pin!(closing);
        tokio::select! {result=&mut closing=>panic!("outer close finished: {result:?}"),_=sent(&fixture.mock,15)=>{}}
        std::fs::rename(fixture.local.output(), fixture.local.other()).unwrap();
        std::fs::write(fixture.local.output(), b"unowned replacement").unwrap();
        let requests = fixture.mock.sent_messages();
        let last = requests.last().unwrap();
        assert_eq!(
            Header::unpack(&mut ReadCursor::new(last)).unwrap().command,
            Command::Close
        );
        answer(
            &fixture.mock,
            last,
            None,
            smb2::types::status::NtStatus::SUCCESS,
            &crate::test_wire::Empty,
        );
        assert!(closing.await.is_err());
        drop(staged);
        done.cancel();
    };
    // Serve only the outer CREATE and inner complete download, leaving the last
    // outer CLOSE blocked so the namespace substitution occurs during that await.
    let peer = async {
        let mut stats = Stats::default();
        let mut consumed = 0;
        loop {
            let requests = tokio::select! {biased;_=done.cancelled()=>break,v=sent(&fixture.mock,consumed+1)=>v};
            for request in &requests[consumed..] {
                let command = Header::unpack(&mut ReadCursor::new(request))
                    .unwrap()
                    .command;
                if command == Command::Close && stats.closes == 1 {
                    continue;
                }
                respond(&fixture.mock, request, &config, &mut stats, &cancel);
            }
            consumed = requests.len();
        }
    };
    tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(operation, peer)
    })
    .await
    .unwrap();
    assert_eq!(
        std::fs::read(fixture.local.output()).unwrap(),
        b"unowned replacement"
    );
    assert_eq!(std::fs::read(fixture.local.other()).unwrap(), b"body");
    fixture.mock.close();
}

#[tokio::test]
async fn more_than_one_window_shuffled_replies_preserve_byte_order_bound_and_refill() {
    let fixture = Fixture::new().await;
    let cancel = CancellationToken::new();
    let done = CancellationToken::new();
    let size = CHUNK_BYTES * (READ_WINDOW + 3) + 17;
    let config = Config::new(
        (0..size)
            .map(|i| ((i * 17 + i / 65536) % 251) as u8)
            .collect(),
    );
    let mut progress = vec![];
    let operation = async {
        let staged = run(
            fixture.connection.clone(),
            &fixture.tree,
            "file",
            &fixture.local.output(),
            Purpose::Hydration,
            &cancel,
            |n| progress.push(n),
        )
        .await;
        let result = match staged {
            Ok(staged) => staged.finish(&cancel).await,
            Err(e) => Err(e),
        };
        done.cancel();
        result
    };
    let peer = async {
        let mut consumed = 0;
        let mut stats = Stats::default();
        let mut held: Option<Vec<u8>> = None;
        let mut completed_later = 0;
        let mut released = false;
        loop {
            let requests = tokio::select! {biased;_=done.cancelled()=>break,v=sent(&fixture.mock,consumed+1)=>v};
            for message in &requests[consumed..] {
                let header = Header::unpack(&mut ReadCursor::new(message)).unwrap();
                if header.command == Command::Read {
                    assert!(fixture.connection.outstanding_requests().len() <= READ_WINDOW);
                    let request =
                        ReadRequest::unpack(&mut ReadCursor::new(&message[64..])).unwrap();
                    if !released && request.offset == 0 {
                        held = Some(message.clone());
                        continue;
                    }
                    if !released {
                        assert!(
                            request.offset < (READ_WINDOW * CHUNK_BYTES) as u64,
                            "buffered results admitted an unbounded refill"
                        );
                        if (request.offset + u64::from(request.length)) % CHUNK_BYTES as u64 == 0 {
                            completed_later += 1;
                        }
                    }
                }
                respond(&fixture.mock, message, &config, &mut stats, &cancel);
            }
            consumed = requests.len();
            if !released && completed_later == READ_WINDOW - 1 {
                // Seven whole later ranges are buffered. The missing first
                // range still counts, so no ninth range has been issued.
                assert!(held.is_some());
                assert_eq!(stats.reads, (READ_WINDOW - 1) * 4);
                respond(
                    &fixture.mock,
                    held.as_ref().unwrap(),
                    &config,
                    &mut stats,
                    &cancel,
                );
                released = true;
            }
        }
        assert!(released);
        assert_eq!(stats.snapshots, 2);
        assert_eq!(stats.closes, 1);
    };
    let (result, ()) = tokio::time::timeout(Duration::from_secs(5), async {
        tokio::join!(operation, peer)
    })
    .await
    .unwrap();
    assert_eq!(result.unwrap().bytes, size as u64);
    assert_eq!(std::fs::read(fixture.local.output()).unwrap(), config.body);
    assert_eq!(progress.last(), Some(&(size as u64)));
    assert!(progress.windows(2).all(|w| w[0] < w[1]));
    assert_eq!(progress.len(), READ_WINDOW + 4);
    assert!(fixture.connection.outstanding_requests().is_empty());
    fixture.mock.close();
}

#[tokio::test]
async fn cancel_drop_or_first_read_error_retires_a_full_window_and_removes_only_owned_output() {
    for drop_operation in [false, true] {
        let fixture = Fixture::new().await;
        let config = Config::new(vec![5; CHUNK_BYTES * (READ_WINDOW + 1)]);
        let cancel = CancellationToken::new();
        let output = fixture.local.output();
        let mut future = Box::pin(run(
            fixture.connection.clone(),
            &fixture.tree,
            "file",
            &output,
            Purpose::Hydration,
            &cancel,
            |_| {},
        ));
        let peer = async {
            let mut consumed = 0;
            let mut stats = Stats::default();
            let mut waiting = 0;
            loop {
                let requests = sent(&fixture.mock, consumed + 1).await;
                for request in &requests[consumed..] {
                    if Header::unpack(&mut ReadCursor::new(request))
                        .unwrap()
                        .command
                        == Command::Read
                    {
                        waiting += 1;
                    } else {
                        respond(&fixture.mock, request, &config, &mut stats, &cancel);
                    }
                }
                consumed = requests.len();
                if waiting == READ_WINDOW {
                    break;
                }
            }
        };
        tokio::select! { result = &mut future => panic!("held read unexpectedly completed: {}", result.is_ok()), _ = peer => {} }
        assert!(output.exists());
        assert_eq!(fixture.connection.outstanding_requests().len(), READ_WINDOW);
        if drop_operation {
            drop(future);
        } else {
            cancel.cancel();
            assert!(matches!(future.await, Err(Error::Cancelled)));
        }
        assert!(!output.exists());
        assert!(fixture.connection.outstanding_requests().is_empty());
        fixture.mock.close();
    }
    let fixture = Fixture::new().await;
    let mut config = Config::new(vec![9; CHUNK_BYTES * (READ_WINDOW + 1)]);
    config.fault = Fault::DeniedRead;
    let (result, stats) = execute(
        &fixture,
        &config,
        "file",
        Purpose::Hydration,
        &CancellationToken::new(),
        |_| {},
    )
    .await;
    assert!(result.is_err());
    assert_eq!(stats.reads, READ_WINDOW);
    assert_eq!(stats.closes, 0); // Unknown in-flight replies retire the session.
    assert!(fixture.connection.outstanding_requests().is_empty());
    assert!(!fixture.local.output().exists());
    fixture.mock.close();
}
