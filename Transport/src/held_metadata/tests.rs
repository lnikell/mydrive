use super::*;
fn entry() -> Entry {
    Entry {
        name: "file".into(),
        bytes: 3,
        directory: false,
        index_number: Some(99),
        created_filetime: 55,
        modified_filetime: 66,
        changed_filetime: 77,
        attributes: 32,
    }
}
fn record(name: &str, size: u64, allocation: u64) -> Vec<u8> {
    let mut b = vec![0; 24];
    let words: Vec<_> = name.encode_utf16().collect();
    b[4..8].copy_from_slice(&(words.len() as u32 * 2).to_le_bytes());
    b[8..16].copy_from_slice(&size.to_le_bytes());
    b[16..24].copy_from_slice(&allocation.to_le_bytes());
    for w in words {
        b.extend_from_slice(&w.to_le_bytes());
    }
    b
}
fn chain(records: Vec<Vec<u8>>) -> Vec<u8> {
    let count = records.len();
    let mut result = vec![];
    for (i, mut b) in records.into_iter().enumerate() {
        if i + 1 < count {
            let n = (b.len() + 7) & !7;
            b.resize(n, 0xa5);
            b[..4].copy_from_slice(&(n as u32).to_le_bytes());
        }
        result.extend(b);
    }
    result
}
fn snapshot(streams: Vec<Vec<u8>>) -> Snapshot {
    Snapshot {
        entry: entry(),
        links: 1,
        ea_size_bytes: 0,
        streams: streams::inventory(&chain(streams), &entry()).unwrap(),
    }
}
#[test]
fn purposes_separate_default_verification_from_exact_sync_exclusion() {
    let plain = snapshot(vec![record("::$DATA", 3, 65536)]);
    for mode in [Eligibility::StrictContent, Eligibility::SyncHydration] {
        assert!(policy::qualify(&plain, mode, || panic!(
            "default data must not query Darwin policy"
        ))
        .is_ok());
    }
    let named = snapshot(vec![
        record("::$DATA", 3, 65536),
        record(":com.apple.provenance:$DATA", 11, 11),
    ]);
    assert!(
        policy::qualify(&named, Eligibility::StrictContent, || panic!(
            "strict read must not query Darwin policy"
        ))
        .is_err()
    );
    assert!(policy::qualify(&named, Eligibility::SyncHydration, || true).is_ok());
    assert!(policy::qualify(&named, Eligibility::SyncHydration, || false).is_err());
}
#[test]
fn unknown_forks_aliases_or_other_lengths_cannot_become_hydration() {
    for (name, size, allocated) in [
        (":AFP_Resource:$DATA", 0, 0),
        (":com.apple.FinderInfo:$DATA", 32, 32),
        (":com.apple.quarantine:$DATA", 11, 11),
        (":com.apple.lastuseddate#PS:$DATA", 16, 16),
        (":com.apple.Provenance:$DATA", 11, 11),
        (":com.apple.provenance:$DATA", 12, 12),
        (":com.apple.provenance:$DATA", 11, 16),
    ] {
        let value = snapshot(vec![
            record("::$DATA", 3, 65536),
            record(name, size, allocated),
        ]);
        assert!(
            policy::qualify(&value, Eligibility::SyncHydration, || panic!(
                "ineligible metadata must short circuit"
            ))
            .is_err()
        );
    }
}
#[test]
fn default_only_purposes_keep_hidden_readonly_system_ea_and_link_parity_without_policy() {
    for attributes in [0, 1, 2, 4, 32, 33, 34, 128, 0x200, 0x800] {
        for ea in [0, 4] {
            for links in [1, 2] {
                let mut value = snapshot(vec![record("::$DATA", 3, 65536)]);
                value.entry.attributes = attributes;
                value.ea_size_bytes = ea;
                value.links = links;
                for purpose in [Eligibility::StrictContent, Eligibility::SyncHydration] {
                    assert!(
                        policy::qualify(&value, purpose, || panic!(
                            "default-only reads must never consult exclusion policy"
                        ))
                        .is_ok(),
                        "attrs={attributes}, EA={ea}, links={links}"
                    );
                }
            }
        }
    }
}
#[test]
fn named_provenance_cannot_reuse_default_only_metadata_eligibility() {
    for change in [
        "hidden",
        "readonly",
        "system",
        "EA",
        "links",
        "normal_combined",
    ] {
        let mut value = snapshot(vec![
            record("::$DATA", 3, 65536),
            record(":com.apple.provenance:$DATA", 11, 11),
        ]);
        match change {
            "hidden" => value.entry.attributes |= 2,
            "readonly" => value.entry.attributes |= 1,
            "system" => value.entry.attributes |= 4,
            "EA" => value.ea_size_bytes = 4,
            "links" => value.links = 2,
            _ => value.entry.attributes = 160,
        }
        assert!(
            policy::qualify(&value, Eligibility::StrictContent, || panic!(
                "strict never excludes"
            ))
            .is_err()
        );
        assert!(
            policy::qualify(&value, Eligibility::SyncHydration, || panic!(
                "ineligible exclusion must short circuit"
            ))
            .is_err()
        );
    }
}
#[test]
fn complete_stream_parser_rejects_bad_tail_duplicates_sizes_and_limits_before_policy() {
    let valid = chain(vec![
        record("::$DATA", 3, 65536),
        record(":unknown:$DATA", 1, 1),
    ]);
    let mut tail = valid.clone();
    tail.extend([0; 8]);
    assert!(streams::inventory(&tail, &entry()).is_err());
    for records in [
        vec![record("::$DATA", 3, 3), record("::$DATA", 3, 3)],
        vec![record("::$DATA", 4, 4)],
        vec![],
        vec![record("::$DATA", 3, 3), record(&"x".repeat(257), 0, 0)],
        vec![record("::$DATA", 3, 3); 33],
    ] {
        assert!(streams::inventory(&chain(records), &entry()).is_err());
    }
    let mut negative = record("::$DATA", 3, 3);
    negative[8..16].copy_from_slice(&u64::MAX.to_le_bytes());
    assert!(streams::inventory(&negative, &entry()).is_err());
}
#[test]
fn exact_names_and_order_are_observations_not_normalization() {
    let records = vec![
        record("::$DATA", 3, 3),
        record(":café:$DATA", 0, 0),
        record(":cafe\u{301}:$DATA", 0, 0),
    ];
    let first = streams::inventory(&chain(records.clone()), &entry()).unwrap();
    let mut reverse = records;
    reverse.reverse();
    assert_eq!(
        first,
        streams::inventory(&chain(reverse), &entry()).unwrap()
    );
    assert_eq!(first.len(), 3);
}
