//! Verified-target fixtures.
//!
//! Every label here is synthetic: the subject, the source device and the new
//! endpoint identity are made-up strings. No fixture reads a real device
//! identity, a protected key or any provider value, and none of them performs a
//! retirement or an erase.

use licoup_endpoint_collaboration_transfer::{
    RequiredOwner, RetirementEligibility, RetirementRefusal, TargetBinding,
    VerifiedTargetEvidence,
};

fn binding() -> TargetBinding {
    TargetBinding {
        subject: "synthetic-subject".to_string(),
        source_device: "synthetic-source-device".to_string(),
        target_identity: "synthetic-new-endpoint".to_string(),
    }
}

#[test]
fn evidence_exists_only_when_every_required_owner_settled() {
    // Nothing settled produces nothing.
    assert!(VerifiedTargetEvidence::from_settled_owners(binding(), Vec::new()).is_none());

    // Neither does every maximal partial subset — each owner but one — so a
    // caller cannot round a nearly-finished target up to "good enough".
    for missing in RequiredOwner::ALL {
        let settled = RequiredOwner::ALL
            .into_iter()
            .filter(|owner| *owner != missing)
            .collect::<Vec<_>>();
        assert_eq!(settled.len(), RequiredOwner::ALL.len() - 1);
        assert!(
            VerifiedTargetEvidence::from_settled_owners(binding(), settled.clone()).is_none(),
            "settled owners {settled:?} must produce no evidence"
        );
    }

    let evidence = VerifiedTargetEvidence::from_settled_owners(binding(), RequiredOwner::ALL)
        .expect("every required owner settled");
    assert_eq!(evidence.verified_owners().count(), RequiredOwner::ALL.len());
}

#[test]
fn the_target_report_names_its_binding_and_verified_owners_and_decides_nothing() {
    let evidence =
        VerifiedTargetEvidence::from_settled_owners(binding(), RequiredOwner::ALL).unwrap();

    // What crosses the client bridge is a report: which subject, which source
    // device, which new identity, and which owners verified. It carries no
    // decision, so showing it to a person grants nothing.
    let report = serde_json::to_value(&evidence).unwrap();
    assert_eq!(report["binding"]["subject"], "synthetic-subject");
    assert_eq!(report["binding"]["sourceDevice"], "synthetic-source-device");
    assert_eq!(report["binding"]["targetIdentity"], "synthetic-new-endpoint");
    let verified = report["verified"].as_array().unwrap();
    assert_eq!(verified.len(), RequiredOwner::ALL.len());
    // Each settled owner is reported once, in the owner order the verification
    // itself follows.
    assert_eq!(
        verified,
        &[
            serde_json::json!("filesystem-payload"),
            serde_json::json!("database-stores"),
            serde_json::json!("platform-credentials"),
        ]
    );

    let mut fields = report
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    fields.sort_unstable();
    assert_eq!(
        fields,
        ["binding", "verified"],
        "the report has no admitted/eligible field a client could set"
    );
}

#[test]
fn retirement_is_decided_for_a_named_source_and_refuses_everything_else() {
    // No evidence at all: the ordinary outcome of a failed or abandoned transfer.
    assert_eq!(
        RetirementEligibility::decide_for(None, "synthetic-subject", "synthetic-source-device"),
        RetirementEligibility::Refused(RetirementRefusal::NoVerifiedTarget)
    );

    // Evidence that verified every owner, but not for the source being retired.
    let mismatch = RetirementEligibility::decide_for(
        VerifiedTargetEvidence::from_settled_owners(binding(), RequiredOwner::ALL),
        "synthetic-subject",
        "synthetic-other-device",
    );
    assert_eq!(
        mismatch,
        RetirementEligibility::Refused(RetirementRefusal::BindingMismatch)
    );
    assert!(!mismatch.is_eligible());
    assert!(mismatch.evidence().is_none());

    // The source the evidence names.
    let eligible = RetirementEligibility::decide_for(
        VerifiedTargetEvidence::from_settled_owners(binding(), RequiredOwner::ALL),
        "synthetic-subject",
        "synthetic-source-device",
    );
    assert!(eligible.is_eligible());
    assert!(eligible.evidence().is_some());
    assert!(eligible.evidence().unwrap().admits_source_retirement());
}

#[test]
fn every_refusal_explains_that_the_source_is_preserved() {
    for refusal in [
        RetirementRefusal::NoVerifiedTarget,
        RetirementRefusal::BindingMismatch,
    ] {
        assert!(refusal.reason().starts_with("the source is preserved: "));
    }
}
