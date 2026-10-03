//! Unit tests for the declared-identity rules.
//!
//! The store's own behaviour is exercised next to the crate in
//! `tests/project_identity_registration.rs`; these cases are the parsers, which
//! decide what an identity may be before any durable owner sees it.

use super::*;

#[test]
fn a_declared_identifier_refuses_a_location_or_an_empty_value() {
    assert!(ProjectId::declare("lico-up").is_ok());
    assert!(ProjectId::declare("project:alpha").is_ok());
    for refused in [
        "",
        "   ",
        "../etc",
        "a/b",
        "a\\b",
        "C:\\src",
        ".hidden-ok-but-empty-first",
        "with space",
        "with\0nul",
    ] {
        let failure = ProjectId::declare(refused).expect_err("must be refused");
        assert_eq!(failure.code(), "project_identity_required");
        assert_eq!(failure.stage(), IDENTITY_STAGE);
    }
    assert!(ProjectId::declare("x".repeat(MAX_PROJECT_ID_BYTES + 1)).is_err());
    assert!(WorkspaceId::declare("").is_err());
    assert!(PlanId::declare("").is_err());
}

#[test]
fn a_declared_root_must_be_an_absolute_location() {
    assert!(AuthorizedRoot::declare("/synthetic/authorized/root").is_ok());
    for refused in ["", "  ", "relative/root", "./root", "\0"] {
        let failure = AuthorizedRoot::declare(refused).expect_err("must be refused");
        assert_eq!(failure.code(), "project_authorized_root_required");
    }
    assert!(AuthorizedRoot::declare("x".repeat(MAX_AUTHORIZED_ROOT_BYTES + 1)).is_err());
}

#[test]
fn an_authority_reference_is_bounded_and_typed() {
    let reference = AuthorityReference::membership("membership:owner").expect("a membership");
    assert_eq!(reference.kind(), AuthorityKind::Membership);
    assert_eq!(reference.reference(), "membership:owner");
    assert_eq!(reference.to_string(), "membership membership:owner");
    assert_eq!(AuthorityKind::parse("grant"), Some(AuthorityKind::Grant));
    assert_eq!(AuthorityKind::parse("owner"), None);
    for refused in ["", "   ", "\0"] {
        assert!(
            AuthorityReference::declare(AuthorityKind::Role, refused).is_err(),
            "{refused} must be refused"
        );
    }
    assert!(
        AuthorityReference::declare(
            AuthorityKind::Role,
            "r".repeat(MAX_AUTHORITY_REFERENCE_BYTES + 1)
        )
        .is_err()
    );
}

/// A deserialized identity is validated on the same path as a constructed one,
/// so a wire payload cannot smuggle an unusable identity past the parser.
#[test]
fn deserializing_an_identity_applies_the_declaration_rule() {
    let decoded: Result<AuthorityReference, _> = serde_json::from_value(serde_json::json!({
        "kind": "membership",
        "reference": "membership:owner",
    }));
    assert!(decoded.is_ok());
    let refused: Result<AuthorityReference, _> = serde_json::from_value(serde_json::json!({
        "kind": "membership",
        "reference": "",
    }));
    assert!(refused.is_err());
    let unknown_kind: Result<AuthorityReference, _> = serde_json::from_value(serde_json::json!({
        "kind": "owner",
        "reference": "membership:owner",
    }));
    assert!(unknown_kind.is_err());
    let refused_id: Result<ProjectId, _> = serde_json::from_value(serde_json::json!("../etc"));
    assert!(refused_id.is_err());
}
