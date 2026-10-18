use nas_transport::{CancellationToken, Connection, Error, Nas};
use serde_json::{json, Value};
use std::{
    io::{IsTerminal, Read, Write},
    path::Path,
    time::Instant,
};
use zeroize::Zeroizing;

mod progress;
mod request;

const USAGE: &str = r#"nas-transport --host HOST:445 --share SHARE --username USER --password-stdin [--test-root .mydrive-transport-tests/RUN] [--require-encryption] COMMAND

Commands:
  shares
  probe
  list [REMOTE] [--pages N]
  read REMOTE NEW_LOCAL_FILE [--offset N] [--length N]
  prepare
  cleanup
  write LOCAL_FILE REMOTE_RELATIVE
  mkdir REMOTE_RELATIVE
  rename FROM_RELATIVE TO_RELATIVE [--replace]
  delete REMOTE_RELATIVE [--directory]

Passwords must arrive through piped stdin; they are never accepted as arguments.
Native callers may use --request-stdin alone for a bounded versioned JSON request.
Mutations are relative to an explicit test root. prepare creates that namespace.
cleanup removes only the configured empty test root, never its parent or children.
Omit --share only for the read-only shares command.
Ctrl-C cancels I/O and invalidates the session. Output is JSON Lines."#;

struct Args {
    host: String,
    share: String,
    user: String,
    root: Option<String>,
    encrypted: bool,
    command: String,
    paths: Vec<String>,
    pages: Option<usize>,
    offset: u64,
    length: Option<u64>,
    replace: bool,
    directory: bool,
    mutation: Option<nas_transport::mutation::MutationRequest>,
    delete_scope: Option<nas_transport::mutation::DeleteScope>,
    tree_scope: Option<nas_transport::mutation::TreeScope>,
}

impl Args {
    fn parse(mut input: impl Iterator<Item = String>) -> Result<Self, Error> {
        let mut result = Self {
            host: String::new(),
            share: String::new(),
            user: String::new(),
            root: None,
            encrypted: false,
            command: String::new(),
            paths: Vec::new(),
            pages: None,
            offset: 0,
            length: None,
            replace: false,
            directory: false,
            mutation: None,
            delete_scope: None,
            tree_scope: None,
        };
        let mut stdin = false;
        while let Some(arg) = input.next() {
            let mut value = || {
                input
                    .next()
                    .ok_or(Error::Input("an option is missing its value"))
            };
            match arg.as_str() {
                "--host" => result.host = value()?,
                "--share" => result.share = value()?,
                "--username" => result.user = value()?,
                "--test-root" => result.root = Some(value()?),
                "--password-stdin" => stdin = true,
                "--require-encryption" => result.encrypted = true,
                "--pages" => {
                    result.pages = Some(
                        value()?
                            .parse()
                            .map_err(|_| Error::Input("invalid page limit"))?,
                    )
                }
                "--offset" => {
                    result.offset = value()?
                        .parse()
                        .map_err(|_| Error::Input("invalid range offset"))?
                }
                "--length" => {
                    result.length = Some(
                        value()?
                            .parse()
                            .map_err(|_| Error::Input("invalid range length"))?,
                    )
                }
                "--replace" => result.replace = true,
                "--directory" => result.directory = true,
                _ if arg.starts_with('-') => {
                    return Err(Error::Input("unknown option; use --help"))
                }
                _ if result.command.is_empty() => result.command = arg,
                _ => result.paths.push(arg),
            }
        }
        if result.host.is_empty()
            || result.user.is_empty()
            || !stdin
            || (result.command != "shares" && result.share.is_empty())
        {
            return Err(Error::Input(
                "host, share, username and --password-stdin are required",
            ));
        }
        if result.host.contains(['/', '\\', '@']) || !result.host.contains(':') {
            return Err(Error::Input(
                "host must be HOST:PORT without credentials or a path",
            ));
        }
        let expected = match result.command.as_str() {
            "shares" | "probe" | "prepare" | "cleanup" => 0,
            "list" if result.paths.is_empty() => 0,
            "list" | "mkdir" | "delete" => 1,
            "read" | "write" | "rename" => 2,
            _ => return Err(Error::Input("unknown command; use --help")),
        };
        if result.paths.len() != expected {
            return Err(Error::Input("wrong number of command arguments"));
        }
        if result.pages == Some(0) {
            return Err(Error::Input("page limit must be positive"));
        }
        if result.command == "cleanup" && result.root.is_none() {
            return Err(Error::Input("cleanup requires an explicit experiment root"));
        }
        Ok(result)
    }
}

fn emit(value: Value) -> Result<(), Error> {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, &value).map_err(|_| Error::Input("JSON output failed"))?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}

fn password() -> Result<Zeroizing<String>, Error> {
    if std::io::stdin().is_terminal() {
        return Err(Error::Input(
            "pipe the password to stdin; terminal echo is disabled by refusing interactive input",
        ));
    }
    let mut bytes = Zeroizing::new(Vec::new());
    std::io::stdin().take(4097).read_to_end(&mut bytes)?;
    if bytes.len() > 4096 {
        return Err(Error::Input("password input exceeds 4096 bytes"));
    }
    while matches!(bytes.last(), Some(b'\n' | b'\r')) {
        bytes.pop();
    }
    let value = std::str::from_utf8(&bytes).map_err(|_| Error::Input("password is not UTF-8"))?;
    Ok(Zeroizing::new(value.to_owned()))
}

async fn run(args: Args, password: Zeroizing<String>) -> Result<(), Error> {
    let cancelled = CancellationToken::new();
    let signal = cancelled.clone();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            signal.cancel();
        }
    });
    let started = Instant::now();
    let config = Connection {
        address: args.host,
        share: args.share,
        username: args.user,
        password,
        mutation_root: args.root,
        require_encryption: args.encrypted,
    };
    if args.command == "shares" {
        let (security, shares) = tokio::select! {
            biased;
            _ = cancelled.cancelled() => return Err(Error::Cancelled),
            result = nas_transport::discover_shares(config) => result?,
        };
        return emit(
            json!({"type":"shares","security":security,"shares":shares,"milliseconds":started.elapsed().as_millis()}),
        );
    }
    let mut nas = tokio::select! {
        biased;
        _ = cancelled.cancelled() => return Err(Error::Cancelled),
        result = Nas::connect(config) => result?,
    };
    emit(
        json!({"type":"connected","milliseconds":started.elapsed().as_millis(),"security":nas.security()}),
    )?;
    let operation = Instant::now();
    let mut progress_gate = progress::ProgressGate::default();
    let progress = |bytes: u64| {
        if progress_gate.should_emit(bytes, operation.elapsed()) {
            let _ = emit(json!({"type":"progress","bytes":bytes}));
        }
    };
    let result = match args.command.as_str() {
        "probe" => Ok(json!({})),
        "stat" => {
            let entry = if let Some(scope) = &args.tree_scope {
                nas.stat_tree_scoped(&args.paths[0], scope, &cancelled)
                    .await
            } else {
                nas.stat_scoped(&args.paths[0], args.delete_scope.as_ref(), &cancelled)
                    .await
            };
            entry.map(|entry| json!({"entry":entry}))
        }
        "mutate" | "reconcile" => nas
            .mutate(
                args.mutation.as_ref().expect("typed native mutation"),
                args.command == "reconcile",
                &cancelled,
                progress,
            )
            .await
            .map(|result| json!(result)),
        "list" => {
            let mut pages = 0;
            let page = |entries: Vec<nas_transport::Entry>| {
                for entries in entries.chunks(1000) {
                    pages += 1;
                    emit(
                        json!({"type":"page","number":pages,"elapsed_ms":operation.elapsed().as_millis(),"entries":entries}),
                    )?;
                }
                Ok(())
            };
            let listing = if let Some(scope) = &args.tree_scope {
                nas.list_tree_scoped(
                    args.paths.first().map_or("", String::as_str),
                    args.pages,
                    scope,
                    &cancelled,
                    page,
                )
                .await
            } else {
                nas.list_scoped(
                    args.paths.first().map_or("", String::as_str),
                    args.pages,
                    args.delete_scope.as_ref(),
                    &cancelled,
                    page,
                )
                .await
            };
            listing.map(|listing| json!({"entries":listing.entries,"pages":pages,"complete":listing.complete,"entry":listing.entry}))
        }
        "read" => {
            let download = if let Some(scope) = &args.tree_scope {
                nas.download_tree_scoped(
                    &args.paths[0],
                    Path::new(&args.paths[1]),
                    scope,
                    &cancelled,
                    progress,
                )
                .await
            } else {
                nas.download(
                    &args.paths[0],
                    Path::new(&args.paths[1]),
                    args.offset,
                    args.length,
                    &cancelled,
                    progress,
                )
                .await
            };
            download.map(|download| json!({"bytes":download.bytes,"entry":download.entry}))
        }
        "hydrate" => nas
            .hydrate(
                &args.paths[0],
                Path::new(&args.paths[1]),
                &cancelled,
                progress,
            )
            .await
            .map(|download| json!({"bytes":download.bytes,"entry":download.entry})),
        "prepare" => nas.prepare_experiment().await.map(|_| json!({})),
        "cleanup" => nas.cleanup_experiment().await.map(|_| json!({})),
        "write" => nas
            .upload(
                Path::new(&args.paths[0]),
                &args.paths[1],
                &cancelled,
                progress,
            )
            .await
            .map(|n| json!({"bytes":n})),
        "mkdir" => nas.mkdir(&args.paths[0]).await.map(|_| json!({})),
        "rename" => nas
            .rename(&args.paths[0], &args.paths[1], args.replace)
            .await
            .map(|_| json!({})),
        "delete" => nas
            .delete(&args.paths[0], args.directory)
            .await
            .map(|_| json!({})),
        _ => unreachable!("validated command"),
    };
    let cleanup = nas.disconnect().await;
    let data = result?;
    // A failed logoff cannot erase a verified mutation outcome or its recovery
    // receipts. Mutation handles already invalidate their connection on loss.
    if args.mutation.is_none() {
        cleanup?;
    }
    emit(json!({"type":"complete","operation_ms":operation.elapsed().as_millis(),"result":data}))
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    let raw: Vec<_> = std::env::args().skip(1).collect();
    if raw.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{USAGE}");
        return;
    }
    let parsed = if raw.iter().any(|arg| arg == "--request-stdin") {
        if raw.len() != 1 {
            Err(Error::Input("--request-stdin must be the only argument"))
        } else if std::io::stdin().is_terminal() {
            Err(Error::Input("pipe the request to stdin"))
        } else {
            request::read(std::io::stdin().lock())
        }
    } else {
        Args::parse(raw.into_iter()).and_then(|args| password().map(|password| (args, password)))
    };
    let result = match parsed {
        Ok((args, password)) => run(args, password).await,
        Err(error) => Err(error),
    };
    if let Err(error) = result {
        let _ = emit(json!({"type":"error","code":error.code(),"message":error.to_string()}));
        std::process::exit(if matches!(error, Error::Cancelled) {
            130
        } else {
            1
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_secrets_on_command_line_and_bad_scope() {
        let base = "--host nas:445 --share test --username tester --password-stdin";
        assert!(Args::parse(
            format!("{base} --password secret probe")
                .split_whitespace()
                .map(str::to_owned)
        )
        .is_err());
        assert!(Args::parse(
            format!("{base} list --pages 0")
                .split_whitespace()
                .map(str::to_owned)
        )
        .is_err());
        assert!(Args::parse(
            format!("{base} probe")
                .split_whitespace()
                .map(str::to_owned)
        )
        .is_ok());
    }

    #[test]
    fn cleanup_accepts_no_target_argument_and_requires_root() {
        let base = "--host nas:445 --share test --username tester --password-stdin";
        let args = |suffix: &str| {
            Args::parse(
                format!("{base} {suffix}")
                    .split_whitespace()
                    .map(str::to_owned),
            )
        };
        assert!(args("cleanup").is_err());
        assert!(args("--test-root .mydrive-transport-tests/run cleanup").is_ok());
        assert!(args("--test-root .mydrive-transport-tests/run cleanup other").is_err());
        assert!(USAGE.lines().any(|line| line == "  cleanup"));
    }
}
