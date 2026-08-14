//! Fail-closed Protocol Line admission at the native composition root.

pub use licoup_protocol_bindings::{
    AUTHORIZATION_REQUIRED, AdmissionDetail, AdmissionInput, AdmissionOutcome,
    ProtocolInputAdmission, ProtocolInputCandidate, admit,
};

#[cfg(test)]
mod tests {
    use super::{
        AUTHORIZATION_REQUIRED, AdmissionDetail, AdmissionOutcome, ProtocolInputAdmission,
        ProtocolInputCandidate, admit,
    };

    #[test]
    fn native_admission_fails_closed_without_protocol_line_inputs() {
        let outcome = ProtocolInputAdmission::admit(&ProtocolInputCandidate::default());
        match &outcome {
            AdmissionOutcome::AuthorizationRequired {
                code,
                missing,
                detail,
            } => {
                assert_eq!(*code, AUTHORIZATION_REQUIRED);
                assert_eq!(*detail, AdmissionDetail::MissingInputs);
                assert!(!missing.is_empty());
                assert!(!outcome.is_admitted());
            }
        }
    }

    #[test]
    fn native_admission_does_not_invent_a_protocol_line() {
        let candidate = ProtocolInputCandidate {
            artifact_version: Some("licoarc.protocol.line.unpublished".to_string()),
            digest: Some("ab".repeat(32)),
            schema_set: vec!["synthetic.schema.v1".to_string()],
            hostile_corpus: vec!["synthetic.hostile.corpus.v1".to_string()],
            authority_boundary: Some("lico-arc-protocol".to_string()),
        };
        let outcome = admit(&candidate);
        match &outcome {
            AdmissionOutcome::AuthorizationRequired { code, detail, .. } => {
                assert_eq!(*code, AUTHORIZATION_REQUIRED);
                assert_eq!(*detail, AdmissionDetail::UnpublishedProtocolLine);
                assert!(!outcome.is_admitted());
            }
        }
    }
}
