//! Native requests are protocol data: macOS Process argv can normalize Unicode.
//! Keep credentials and byte-sensitive NAS names together in bounded stdin.
use super::Args;
use nas_transport::Error;
use serde::Deserialize;
use std::io::Read;
use zeroize::Zeroizing;

const MAX_BYTES: usize = 65_536;
const INVALID: &str = "invalid versioned transport request";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u8,
    host: String,
    share: String,
    username: String,
    password: Zeroizing<String>,
    operation: Operation,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
enum Operation {
    Probe {},
    List {
        path: String,
        #[serde(default)]
        delete_scope: Option<nas_transport::mutation::DeleteScope>,
        #[serde(default)]
        tree_scope: Option<nas_transport::mutation::TreeScope>,
    },
    Read {
        path: String,
        destination: String,
        #[serde(default)]
        tree_scope: Option<nas_transport::mutation::TreeScope>,
    },
    Stat {
        path: String,
        #[serde(default)]
        delete_scope: Option<nas_transport::mutation::DeleteScope>,
        #[serde(default)]
        tree_scope: Option<nas_transport::mutation::TreeScope>,
    },
    Mutate {
        request: nas_transport::mutation::MutationRequest,
    },
    Reconcile {
        request: nas_transport::mutation::MutationRequest,
    },
}

pub(super) fn read(input: impl Read) -> Result<(Args, Zeroizing<String>), Error> {
    let mut bytes = Zeroizing::new(Vec::new());
    input.take((MAX_BYTES + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > MAX_BYTES {
        return Err(Error::Input("transport request exceeds 65536 bytes"));
    }
    // Parse diagnostics may contain field values. Do not expose them in JSONL.
    let request: Request = serde_json::from_slice(&bytes).map_err(|_| Error::Input(INVALID))?;
    request.into_arguments()
}

impl Request {
    fn into_arguments(self) -> Result<(Args, Zeroizing<String>), Error> {
        let valid_text = |value: &str| !value.is_empty() && !value.contains('\0');
        if self.version != 1
            || !valid_text(&self.host)
            || !self.host.contains(':')
            || self.host.contains(['/', '\\', '@'])
            || !valid_text(&self.share)
            || !valid_text(&self.username)
            || !(1..=4096).contains(&self.password.len())
            || self.password.contains('\0')
        {
            return Err(Error::Input(INVALID));
        }
        let (command, paths, mutation, delete_scope, tree_scope) = match self.operation {
            Operation::Probe {} => ("probe", vec![], None, None, None),
            Operation::List {
                path,
                delete_scope,
                tree_scope,
            } if !path.contains('\0') => ("list", vec![path], None, delete_scope, tree_scope),
            Operation::Read {
                path,
                destination,
                tree_scope,
            } if valid_text(&path) && valid_text(&destination) => {
                ("read", vec![path, destination], None, None, tree_scope)
            }
            Operation::Stat {
                path,
                delete_scope,
                tree_scope,
            } if !path.contains('\0') => ("stat", vec![path], None, delete_scope, tree_scope),
            Operation::Mutate { request } => {
                request.validate()?;
                ("mutate", vec![], Some(request), None, None)
            }
            Operation::Reconcile { request } => {
                request.validate()?;
                ("reconcile", vec![], Some(request), None, None)
            }
            _ => return Err(Error::Input(INVALID)),
        };
        if let Some(scope) = &delete_scope {
            scope.validate_path(&paths[0])?;
        }
        if delete_scope.is_some() && tree_scope.is_some() {
            return Err(Error::Input(INVALID));
        }
        if let Some(scope) = &tree_scope {
            if command == "read" {
                scope.validate_payload_path(&paths[0])?;
            } else {
                scope.validate_path(&paths[0])?;
            }
        }
        Ok((
            Args {
                host: self.host,
                share: self.share,
                user: self.username,
                root: None,
                encrypted: false,
                command: command.to_owned(),
                paths,
                pages: None,
                offset: 0,
                length: None,
                replace: false,
                directory: false,
                mutation,
                delete_scope,
                tree_scope,
            },
            self.password,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn request(operation: Value) -> Value {
        json!({"version":1,"host":"nas:445","share":"café","username":"é",
               "password":"secret\n", "operation":operation})
    }

    fn parse(value: Value) -> Result<(Args, Zeroizing<String>), Error> {
        read(serde_json::to_vec(&value).unwrap().as_slice())
    }

    #[test]
    fn preserves_remote_unicode_forms_and_secret_newline() {
        for path in ["Unicode — café.txt", "Unicode — cafe\u{301}.txt", "--read"] {
            let (args, password) = parse(request(json!({"type":"read","path":path,
                "destination":"/tmp/décomposé"})))
            .unwrap();
            assert_eq!(args.paths[0].as_bytes(), path.as_bytes());
            assert_eq!(args.paths[1], "/tmp/décomposé");
            assert_eq!(args.share.as_bytes(), "café".as_bytes());
            assert_eq!(args.user.as_bytes(), "é".as_bytes());
            assert_eq!(password.as_bytes(), b"secret\n");
            assert!(args.root.is_none());
        }
    }

    #[test]
    fn accepts_typed_read_operations_and_refuses_legacy_mutation_shapes() {
        let (args, _) = parse(request(json!({"type":"list","path":""}))).unwrap();
        assert_eq!(args.paths, [""]);
        assert!(parse(request(json!({"type":"probe"}))).is_ok());
        for operation in [
            json!({"type":"delete","path":"a"}),
            json!({"type":"probe","path":""}),
            json!({"type":"list"}),
            json!({"type":"read","path":"","destination":"/tmp/a"}),
            json!({"type":"read","path":"a","destination":""}),
        ] {
            assert!(parse(request(operation)).is_err());
        }
    }

    #[test]
    fn scoped_list_and_stat_keep_exact_selection_bytes_and_reject_scope_expansion() {
        let scope = json!({"root_path":"cafe\u{301}",
            "root":{"index_number":2,"created_filetime":3},
            "parent":{"index_number":4,"created_filetime":5}});
        for kind in ["list", "stat"] {
            let (args, _) = parse(request(
                json!({"type":kind,"path":"cafe\u{301}/file","delete_scope":scope}),
            ))
            .unwrap();
            assert_eq!(
                args.delete_scope.unwrap().root_path.as_bytes(),
                "cafe\u{301}".as_bytes()
            );
            for path in ["café/file", "cafe\u{301}-sibling/file", ""] {
                assert!(parse(request(
                    json!({"type":kind,"path":path,"delete_scope":scope})
                ))
                .is_err());
            }
        }
        assert!(parse(request(json!({"type":"probe","delete_scope":scope}))).is_err());
        assert!(parse(request(json!({"type":"read","path":"cafe\u{301}/file", "destination":"/tmp/file", "delete_scope":scope}))).is_err());
    }

    #[test]
    fn tree_reads_and_mutations_have_one_exclusive_exact_scope_shape() {
        let scope = json!({"layout_version":2,"arena_path":"cafe\u{301}",
            "arena":{"index_number":2,"created_filetime":3},
            "parent":{"index_number":4,"created_filetime":5}});
        for kind in ["list", "stat"] {
            let (args, _) = parse(request(json!({"type":kind,"path":"cafe\u{301}/payload",
                "tree_scope":scope})))
            .unwrap();
            assert_eq!(
                args.tree_scope.unwrap().arena_path.as_bytes(),
                "cafe\u{301}".as_bytes()
            );
            for path in ["café/payload", "cafe\u{301}-sibling/payload", ""] {
                assert!(
                    parse(request(json!({"type":kind,"path":path,"tree_scope":scope}))).is_err()
                );
            }
            assert!(
                parse(request(json!({"type":kind,"path":"cafe\u{301}/payload",
                "tree_scope":scope,"delete_scope":{"root_path":"cafe\u{301}",
                    "root":{"index_number":2,"created_filetime":3},
                    "parent":{"index_number":4,"created_filetime":5}}})))
                .is_err()
            );
        }
        for kind in ["mutate", "reconcile"] {
            let intent = json!({"kind":"create_directory","operation_id":"11111111-2222-4333-8444-555555555555",
                "path":"cafe\u{301}/.mydrive-11111111-2222-4333-8444-555555555555.node",
                "parent":{"index_number":2,"created_filetime":3},"tree_scope":scope});
            let (args, _) = parse(request(json!({"type":kind,"request":intent}))).unwrap();
            assert!(args.mutation.unwrap().tree_scope.is_some());
        }
        assert!(parse(request(json!({"type":"probe","tree_scope":scope}))).is_err());
        let (args, _) = parse(request(
            json!({"type":"read","path":"cafe\u{301}/payload/file",
            "destination":"/tmp/file","tree_scope":scope}),
        ))
        .unwrap();
        assert!(args.tree_scope.is_some());
        for path in ["cafe\u{301}", "outside/file"] {
            assert!(parse(request(json!({"type":"read","path":path,
                "destination":"/tmp/file","tree_scope":scope})))
            .is_err());
        }
        for version in [None, Some(1), Some(3)] {
            let mut old = scope.clone();
            if let Some(value) = version {
                old["layout_version"] = json!(value);
            } else {
                old.as_object_mut().unwrap().remove("layout_version");
            }
            for kind in ["stat", "list"] {
                assert!(parse(request(
                    json!({"type":kind,"path":"cafe\u{301}","tree_scope":old})
                ))
                .is_err());
            }
            assert!(
                parse(request(json!({"type":"read","path":"cafe\u{301}/file",
                "destination":"/tmp/file","tree_scope":old})))
                .is_err()
            );
            for kind in ["mutate", "reconcile"] {
                assert!(parse(request(json!({"type":kind,"request":{
                    "kind":"create_directory","operation_id":"11111111-2222-4333-8444-555555555555",
                    "path":"cafe\u{301}/.mydrive-11111111-2222-4333-8444-555555555555.node",
                    "parent":{"index_number":2,"created_filetime":3},"tree_scope":old}})))
                .is_err());
            }
        }
    }

    #[test]
    fn native_mutations_have_one_strict_versioned_and_redacted_shape() {
        let intent = json!({"kind":"create_file","operation_id":"11111111-2222-4333-8444-555555555555",
            "path":"cafe\u{301}/file","parent":{"index_number":9,"created_filetime":1},
            "payload":{"source":"/tmp/payload","bytes":3,"sha256":"a".repeat(64)}});
        for kind in ["mutate", "reconcile"] {
            let (args, _) = parse(request(json!({"type":kind,"request":intent}))).unwrap();
            assert_eq!(args.command, kind);
            assert!(args.mutation.is_some());
        }
        assert!(parse(request(json!({"type":"stat","path":"café"}))).is_ok());
        assert!(parse(request(json!({"type":"stat","path":""}))).is_ok());
        let mut bad = intent.clone();
        bad["receipt"] = json!({"arbitrary":"synthetic-sensitive-value"});
        assert_eq!(
            parse(request(json!({"type":"mutate","request":bad})))
                .err()
                .unwrap()
                .to_string(),
            Error::Input(INVALID).to_string()
        );
        for (field, value) in [
            ("operation_id", json!("../escape")),
            ("kind", json!("overwrite")),
            ("destination", json!("unexpected")),
        ] {
            let mut bad = intent.clone();
            bad[field] = value;
            assert!(parse(request(json!({"type":"mutate","request":bad}))).is_err());
        }
    }

    #[test]
    fn validates_version_fields_limits_and_redacts_invalid_data() {
        let good = request(json!({"type":"probe"}));
        for (field, value) in [
            ("version", json!(2)),
            ("extra", json!("secret")),
            ("host", json!("user@nas:445")),
            ("share", json!("")),
            ("username", json!("\u{0}")),
            ("password", json!("")),
            ("password", json!("x".repeat(4097))),
        ] {
            let mut bad = good.clone();
            bad[field] = value;
            let error = parse(bad).err().unwrap();
            assert_eq!(error.to_string(), Error::Input(INVALID).to_string());
        }
        let mut maximum = good.clone();
        maximum["password"] = json!("x".repeat(4096));
        assert!(parse(maximum).is_ok());
        assert!(read(&b"{invalid secret"[..]).is_err());
        assert!(read(&vec![b' '; MAX_BYTES + 1][..]).is_err());
        let bytes = serde_json::to_vec(&good).unwrap();
        let mut exact = bytes.clone();
        exact.resize(MAX_BYTES, b' ');
        assert!(read(exact.as_slice()).is_ok());
        exact.push(b' ');
        assert!(read(exact.as_slice()).is_err());
    }
}
