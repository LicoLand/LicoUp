#[test]
fn state_limits_and_collection_authority_are_explicit() {
    assert_eq!(
        super::super::policy::MAX_ACTIVITY_FILE_BYTES,
        64 * 1024 * 1024
    );
    assert_eq!(
        super::super::policy::MAX_ACTIVITY_EVENT_BYTES,
        4 * 1024 * 1024
    );
    assert_eq!(super::super::policy::MAX_ACTIVITY_EVENTS, 10_000);
    assert_eq!(super::super::policy::MAX_REDACTION_DEPTH, 64);
    assert_eq!(super::super::policy::MAX_REDACTION_PATHS, 4_096);
    assert_eq!(super::super::policy::COLLECTIONS.len(), 15);
    assert!(super::super::policy::COLLECTIONS.contains(&"settings"));
    assert!(super::super::policy::COLLECTIONS.contains(&"conversation-archive-profiles"));
    assert!(super::super::policy::COLLECTIONS.contains(&"target-discovery-cache"));
    assert!(super::super::policy::COLLECTIONS.contains(&"local-server-assemblies"));
    assert!(super::super::policy::COLLECTIONS.contains(&"local-server-assembly-cleanup"));
    assert!(super::super::policy::COLLECTIONS.contains(&"local-server-assembly-transaction"));
    assert!(super::super::policy::COLLECTIONS.contains(&"mcp-install-transactions"));
}
