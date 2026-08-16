use super::{
    AUTHORIZATION_REQUIRED, AdmissionDetail, AdmissionInput, AdmissionOutcome,
    ProtocolInputAdmission, ProtocolInputCandidate, admit,
};

fn synthetic_digest() -> String {
    "ab".repeat(32)
}

fn complete_unpublished_candidate() -> ProtocolInputCandidate {
    ProtocolInputCandidate {
        artifact_version: Some("licoarc.protocol.line.unpublished".to_string()),
        digest: Some(synthetic_digest()),
        schema_set: vec!["synthetic.schema.v1".to_string()],
        hostile_corpus: vec!["synthetic.hostile.corpus.v1".to_string()],
        authority_boundary: Some("lico-arc-protocol".to_string()),
    }
}

fn assert_refused(outcome: &AdmissionOutcome, detail: AdmissionDetail, missing: &[AdmissionInput]) {
    match outcome {
        AdmissionOutcome::AuthorizationRequired {
            code,
            missing: got,
            detail: got_detail,
        } => {
            assert_eq!(*code, AUTHORIZATION_REQUIRED);
            assert_eq!(*got_detail, detail);
            assert_eq!(got.as_slice(), missing);
            assert!(!outcome.is_admitted());
            assert_eq!(outcome.authorization_code(), AUTHORIZATION_REQUIRED);
        }
    }
}

#[test]
fn empty_candidate_fails_closed() {
    let outcome = ProtocolInputAdmission::admit(&ProtocolInputCandidate::default());
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[
            AdmissionInput::ArtifactVersion,
            AdmissionInput::Digest,
            AdmissionInput::SchemaSet,
            AdmissionInput::HostileCorpus,
            AdmissionInput::AuthorityBoundary,
        ],
    );
}

#[test]
fn missing_digest_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.digest = None;
    let outcome = admit(&candidate);
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[AdmissionInput::Digest],
    );
}

#[test]
fn missing_schema_set_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.schema_set.clear();
    let outcome = admit(&candidate);
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[AdmissionInput::SchemaSet],
    );
}

#[test]
fn missing_hostile_corpus_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.hostile_corpus = vec!["   ".to_string()];
    let outcome = admit(&candidate);
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[AdmissionInput::HostileCorpus],
    );
}

#[test]
fn missing_artifact_version_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.artifact_version = Some(String::new());
    let outcome = admit(&candidate);
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[AdmissionInput::ArtifactVersion],
    );
}

#[test]
fn missing_authority_boundary_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.authority_boundary = None;
    let outcome = admit(&candidate);
    assert_refused(
        &outcome,
        AdmissionDetail::MissingInputs,
        &[AdmissionInput::AuthorityBoundary],
    );
}

#[test]
fn invalid_digest_fails_closed() {
    let mut candidate = complete_unpublished_candidate();
    candidate.digest = Some("not-a-digest".to_string());
    let outcome = admit(&candidate);
    assert_refused(&outcome, AdmissionDetail::InvalidDigest, &[]);
}

#[test]
fn complete_inputs_do_not_mint_a_protocol_line() {
    let outcome = admit(&complete_unpublished_candidate());
    assert_refused(&outcome, AdmissionDetail::UnpublishedProtocolLine, &[]);
}

#[test]
fn admission_input_names_are_stable() {
    assert_eq!(AdmissionInput::Digest.as_str(), "digest");
    assert_eq!(AdmissionInput::SchemaSet.as_str(), "schema_set");
    assert_eq!(AdmissionInput::HostileCorpus.as_str(), "hostile_corpus");
    assert_eq!(
        AdmissionDetail::UnpublishedProtocolLine.as_str(),
        "unpublished_protocol_line"
    );
}
