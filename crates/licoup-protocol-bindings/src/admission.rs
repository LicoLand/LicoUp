//! Fail-closed admission for exact versioned Protocol Line inputs.
//!
//! No published Lico Arc Protocol Line is registered here. Completeness of a
//! candidate is not admission: this crate refuses to mint a client-owned line.

const SHA256_HEX_LEN: usize = 64;

/// Stable failure code returned for every refused Protocol Line candidate.
pub const AUTHORIZATION_REQUIRED: &str = "authorization_required";

/// One required Protocol Line admission input.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum AdmissionInput {
    ArtifactVersion,
    Digest,
    SchemaSet,
    HostileCorpus,
    AuthorityBoundary,
}

impl AdmissionInput {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ArtifactVersion => "artifact_version",
            Self::Digest => "digest",
            Self::SchemaSet => "schema_set",
            Self::HostileCorpus => "hostile_corpus",
            Self::AuthorityBoundary => "authority_boundary",
        }
    }
}

/// Why admission refused a candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmissionDetail {
    MissingInputs,
    InvalidDigest,
    UnpublishedProtocolLine,
}

impl AdmissionDetail {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::MissingInputs => "missing_inputs",
            Self::InvalidDigest => "invalid_digest",
            Self::UnpublishedProtocolLine => "unpublished_protocol_line",
        }
    }
}

/// Candidate presented for Protocol Line admission.
///
/// Empty or whitespace-only fields are treated as missing. This type does not
/// carry Protocol Line semantics.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProtocolInputCandidate {
    pub artifact_version: Option<String>,
    pub digest: Option<String>,
    pub schema_set: Vec<String>,
    pub hostile_corpus: Vec<String>,
    pub authority_boundary: Option<String>,
}

/// Fail-closed Protocol Line admission evaluator.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProtocolInputAdmission;

/// Refused admission. Never constructs a Protocol Line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionOutcome {
    AuthorizationRequired {
        code: &'static str,
        missing: Vec<AdmissionInput>,
        detail: AdmissionDetail,
    },
}

impl AdmissionOutcome {
    pub fn is_admitted(&self) -> bool {
        false
    }

    pub fn authorization_code(&self) -> &'static str {
        match self {
            Self::AuthorizationRequired { code, .. } => code,
        }
    }
}

/// Published Protocol Line pins. Empty until an exact Lico Arc line exists.
const PUBLISHED_PROTOCOL_LINES: &[PublishedProtocolLinePin] = &[];

struct PublishedProtocolLinePin {
    artifact_version: &'static str,
    digest: &'static str,
}

impl ProtocolInputAdmission {
    /// Admit a candidate, or refuse with `authorization_required`.
    ///
    /// Refuses before any write or egress. Never synthesizes a Protocol Line.
    #[must_use]
    pub fn admit(candidate: &ProtocolInputCandidate) -> AdmissionOutcome {
        admit(candidate)
    }
}

/// Admit a candidate, or refuse with `authorization_required`.
#[must_use]
pub fn admit(candidate: &ProtocolInputCandidate) -> AdmissionOutcome {
    let mut missing = Vec::new();
    let version = present_text(candidate.artifact_version.as_deref());
    let digest = present_text(candidate.digest.as_deref());
    let schemas = present_tokens(&candidate.schema_set);
    let corpus = present_tokens(&candidate.hostile_corpus);
    let boundary = present_text(candidate.authority_boundary.as_deref());

    if version.is_none() {
        missing.push(AdmissionInput::ArtifactVersion);
    }
    if digest.is_none() {
        missing.push(AdmissionInput::Digest);
    } else if digest.is_some_and(|value| !is_sha256_hex(value)) {
        return refuse(Vec::new(), AdmissionDetail::InvalidDigest);
    }
    if schemas.is_empty() {
        missing.push(AdmissionInput::SchemaSet);
    }
    if corpus.is_empty() {
        missing.push(AdmissionInput::HostileCorpus);
    }
    if boundary.is_none() {
        missing.push(AdmissionInput::AuthorityBoundary);
    }

    if !missing.is_empty() {
        missing.sort();
        missing.dedup();
        return refuse(missing, AdmissionDetail::MissingInputs);
    }

    let version = version.expect("artifact_version present");
    let digest = digest.expect("digest present");
    let _matched_published_pin = PUBLISHED_PROTOCOL_LINES
        .iter()
        .any(|pin| pin.artifact_version == version && pin.digest == digest);
    // Completeness and even a future pin match do not mint a client-owned
    // Protocol Line. Bindings generation stays with a later exact-input node.
    refuse(Vec::new(), AdmissionDetail::UnpublishedProtocolLine)
}

fn refuse(missing: Vec<AdmissionInput>, detail: AdmissionDetail) -> AdmissionOutcome {
    AdmissionOutcome::AuthorizationRequired {
        code: AUTHORIZATION_REQUIRED,
        missing,
        detail,
    }
}

fn present_text(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn present_tokens(values: &[String]) -> Vec<&str> {
    values
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .collect()
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == SHA256_HEX_LEN
        && value
            .chars()
            .all(|ch| ch.is_ascii_hexdigit() && !ch.is_ascii_uppercase())
}
