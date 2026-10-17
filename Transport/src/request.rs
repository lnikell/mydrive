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
    List { path: String },
    Read { path: String, destination: String },
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
        let (command, paths) = match self.operation {
            Operation::Probe {} => ("probe", vec![]),
            Operation::List { path } if !path.contains('\0') => ("list", vec![path]),
            Operation::Read { path, destination }
                if valid_text(&path) && valid_text(&destination) =>
            {
                ("read", vec![path, destination])
            }
            _ => return Err(Error::Input(INVALID)),
        };
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
    fn accepts_only_read_only_typed_operations() {
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
