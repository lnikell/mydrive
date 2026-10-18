use super::*;
use serde_json::json;

#[test]
fn content_evidence_has_one_closed_validated_shape() {
    for kind in ["smb_acknowledged", "remote_sha256"] {
        let value = json!({"kind":kind,"bytes":3,"sha256":"a".repeat(64)});
        let decoded: ContentEvidence = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(decoded).unwrap(), value);
        for field in ["trusted", "flushed", "verified"] {
            let mut extra = value.clone();
            extra[field] = json!(true);
            assert!(serde_json::from_value::<ContentEvidence>(extra).is_err());
        }
    }
    for value in [
        json!({"kind":"unknown","bytes":3,"sha256":"a".repeat(64)}),
        json!({"kind":"smb_acknowledged","bytes":-1,"sha256":"a".repeat(64)}),
        json!({"kind":"smb_acknowledged","bytes":9223372036854775808u64,"sha256":"a".repeat(64)}),
        json!({"kind":"smb_acknowledged","bytes":3,"sha256":"A".repeat(64)}),
        json!({"kind":"smb_acknowledged","bytes":3,"sha256":"a".repeat(63)}),
    ] {
        assert!(serde_json::from_value::<ContentEvidence>(value).is_err());
    }
    assert!(serde_json::from_str::<SaveContract>("\"unknown\"").is_err());
}

#[test]
fn legacy_missing_contract_is_not_reinterpreted_or_encoded_as_v2() {
    let original = json!({"operation_id":"11111111-2222-4333-8444-555555555555","kind":"create_file",
        "path":"folder/file","parent":{"index_number":5,"created_filetime":6},
        "payload":{"source":"/tmp/unused","bytes":3,"sha256":"a".repeat(64)},"receipt":{}});
    let legacy: MutationRequest = serde_json::from_value(original.clone()).unwrap();
    legacy.validate().unwrap();
    assert_eq!(legacy.save_contract, None);
    assert_eq!(serde_json::to_value(legacy).unwrap(), original);
}

#[test]
fn request_and_allocated_binding_include_nil_and_archives_never_inherit() {
    let root = json!({"operation_id":"11111111-2222-4333-8444-555555555555","kind":"create_file",
        "path":"folder/file","parent":{"index_number":5,"created_filetime":6},
        "payload":{"source":"/tmp/unused","bytes":3,"sha256":"a".repeat(64)},
        "receipt":{"staged":{"path":"folder/.mydrive-11111111-2222-4333-8444-555555555555.stage","phase":"allocated","cleanup_safe":true,
        "security_sha256":"b".repeat(64),"entry":{"name":"stage","bytes":0,"directory":false,"index_number":10,
        "created_filetime":11,"modified_filetime":12,"changed_filetime":13,"attributes":34}}}});
    let mut v2 = root.clone();
    v2["save_contract"] = json!("acknowledged_smb_v2");
    assert!(serde_json::from_value::<MutationRequest>(v2.clone())
        .unwrap()
        .validate()
        .is_err());
    v2["receipt"]["staged"]["save_contract"] = json!("acknowledged_smb_v2");
    serde_json::from_value::<MutationRequest>(v2.clone())
        .unwrap()
        .validate()
        .unwrap();
    let mut reverse = v2.clone();
    reverse.as_object_mut().unwrap().remove("save_contract");
    assert!(serde_json::from_value::<MutationRequest>(reverse)
        .unwrap()
        .validate()
        .is_err());
    v2["receipt"]["staged"]["phase"] = json!("prepared");
    assert!(serde_json::from_value::<MutationRequest>(v2)
        .unwrap()
        .validate()
        .is_err());
    let mut malformed = root;
    malformed["save_contract"] = json!("new_default");
    assert!(serde_json::from_value::<MutationRequest>(malformed).is_err());
}
