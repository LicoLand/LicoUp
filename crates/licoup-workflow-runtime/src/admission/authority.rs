//! The authority an effect is admitted under, and the fields a caller may not
//! supply.
//!
//! Two halves, deliberately unequal:
//!
//! * [`AdmissionAuthority`] is the authority a caller *acts under*. It has
//!   private fields, no `Serialize`/`Deserialize`, and exactly one mint path:
//!   resolution through [`crate::ports::AuthorityPort`], which K0 already places
//!   in the trusted session domain. There is no public constructor that takes
//!   digests, so a payload, a tool argument, or a free-form extension attribute
//!   has no channel to supply one. This is the same separation E0 made for
//!   `licoup-application`'s invocation authority (`AuthorityHandle` /
//!   `AuthoritySource`): authority is proved by a surface, never carried as
//!   data. The idea is reused here rather than re-invented, and the reuse is
//!   *shaped*, not shared: this crate must not depend on the application crate,
//!   because the compile-time edge points `application ──► runtime`, and a
//!   dependency back would reverse it.
//! * [`AuthorityEvidence`] is the receipt side: source, principal identifier and
//!   digests, serializable because a record of what was true must be storable.
//!   Nothing converts evidence back into an authority, so a stored receipt
//!   cannot be replayed as a grant.
//!
//! The C05 rule is enforced at the same boundary: `principal`, `effectId`,
//! `authorized` and `stateRoot` belong to the host's own records. A free-form
//! attribute that names one of them is refused by name instead of being merged,
//! and the values the receipt reports are read from the typed fields — the
//! verified caller, the effect identity, the resolved grant, the request's
//! typed state root — never from the attribute map.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ports::AuthorityPort;

use super::AdmissionError;

/// The authority fields free-form attributes may never supply.
///
/// The same four names E0 reserved for extension attributes (`principal`,
/// `effectId`, `authorized`, `stateRoot`). They are the facts that decide who an
/// effect is for, which effect it is, whether it is allowed, and which state it
/// is bound to; an attribute that could set one would be writing the host's
/// authority rather than describing itself.
pub const AUTHORITY_FIELDS: [&str; 4] = ["principal", "effectId", "authorized", "stateRoot"];

/// Whether `name` is one of the authority fields, in any spelling.
///
/// Comparison ignores case and `_`, so `effectId`, `effect_id` and `EFFECTID`
/// are the same field: a spelling difference is not a different name.
pub fn is_authority_field(name: &str) -> bool {
    normalized(name).is_some_and(|normalized| {
        AUTHORITY_FIELDS
            .iter()
            .any(|field| field.eq_ignore_ascii_case(&normalized))
    })
}

/// `name` reduced to the comparable form: no `_`, lowercased.
fn normalized(name: &str) -> Option<String> {
    if name.is_empty() {
        return None;
    }
    Some(
        name.chars()
            .filter(|character| *character != '_')
            .flat_map(char::to_lowercase)
            .collect(),
    )
}

/// The first attribute that names an authority field, with the field it names.
///
/// The offending name is returned as the caller wrote it, so the refusal can
/// quote it back: "you tried to set `effect_id`" is actionable, while "an
/// attribute was rejected" is not. The fields are searched in C05's own order
/// rather than the map's, so which of several offending attributes is reported
/// does not depend on how the caller happened to order them.
pub(super) fn reserved_attribute(
    attributes: &BTreeMap<String, String>,
) -> Option<(String, String)> {
    for field in AUTHORITY_FIELDS {
        let matching = attributes.keys().find(|name| {
            normalized(name).is_some_and(|normalized| field.eq_ignore_ascii_case(&normalized))
        });
        if let Some(name) = matching {
            return Some((name.clone(), field.to_owned()));
        }
    }
    None
}

/// Where the authority for one admission came from.
///
/// The source is part of the handle rather than something a request asserts
/// about itself, so "an authenticated adapter admitted this caller" cannot be
/// claimed by the caller.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthoritySource {
    /// The in-process owner of this installation.
    LocalOwner,
    /// The trusted session domain, which resolved the grant through the
    /// authority port.
    ResolvedSession,
    /// A local interface an authenticated adapter already admitted.
    AdmittedAdapter,
}

impl AuthoritySource {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::LocalOwner => "localOwner",
            Self::ResolvedSession => "resolvedSession",
            Self::AdmittedAdapter => "admittedAdapter",
        }
    }
}

/// The identifier-only reference to the caller a trusted surface proved.
///
/// Built by the surface that performed the verification — the transport, the
/// local owner, or the adapter an authenticated peer reached — not by the
/// request the verification was about. The identifier is validated here because
/// it ends up in durable receipts, and a receipt that must be re-read cannot
/// contain a control character or an unbounded string.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedCaller {
    principal: String,
    source: AuthoritySource,
}

/// The longest principal identifier this crate accepts.
const MAX_PRINCIPAL_BYTES: usize = 160;

impl VerifiedCaller {
    /// Assemble from what a trusted surface already verified.
    pub fn from_verified_source(
        principal: impl Into<String>,
        source: AuthoritySource,
    ) -> Result<Self, AdmissionError> {
        let principal = principal.into();
        if principal.is_empty() || principal.len() > MAX_PRINCIPAL_BYTES {
            return Err(AdmissionError::malformed(
                "principal",
                "must be a non-empty identifier of at most 160 bytes",
            ));
        }
        if principal.trim() != principal || principal.chars().any(char::is_control) {
            return Err(AdmissionError::malformed(
                "principal",
                "must not carry surrounding whitespace or control characters",
            ));
        }
        Ok(Self { principal, source })
    }

    pub fn principal(&self) -> &str {
        &self.principal
    }

    pub fn source(&self) -> AuthoritySource {
        self.source
    }
}

/// The grant in force for one definition revision, as the port resolved it.
#[derive(Clone)]
pub struct GrantBinding {
    authorization_digest: String,
    semantics_digest: String,
    revision_digest: String,
}

impl GrantBinding {
    pub fn authorization_digest(&self) -> &str {
        &self.authorization_digest
    }

    pub fn semantics_digest(&self) -> &str {
        &self.semantics_digest
    }

    /// The revision the grant was resolved for.
    pub fn revision_digest(&self) -> &str {
        &self.revision_digest
    }
}

impl std::fmt::Debug for GrantBinding {
    /// Digests only: a debug form of a binding must never be a way to read a
    /// credential, and this type carries none.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("GrantBinding")
            .field("revision_digest", &self.revision_digest)
            .field("authorization_digest", &self.authorization_digest)
            .finish_non_exhaustive()
    }
}

impl Eq for GrantBinding {}

impl PartialEq for GrantBinding {
    fn eq(&self, other: &Self) -> bool {
        self.authorization_digest == other.authorization_digest
            && self.semantics_digest == other.semantics_digest
            && self.revision_digest == other.revision_digest
    }
}

/// The authority one effect is admitted under.
///
/// Deliberately neither `Serialize` nor `Deserialize`, and with no public
/// constructor: the only way to obtain one is
/// [`super::AdmissionGate::authority_for`], which asks the authority port. A
/// caller can therefore hold the authority it was given, but cannot mint the
/// authority it acts under.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmissionAuthority {
    caller: VerifiedCaller,
    binding: GrantBinding,
}

impl AdmissionAuthority {
    /// Minted only from a port resolution. Private on purpose: this is the one
    /// function that creates authority in this crate, and it is reachable only
    /// from `admission`, which only calls it with the port's answer.
    pub(super) fn resolved(caller: VerifiedCaller, binding: GrantBinding) -> Self {
        Self { caller, binding }
    }

    pub fn caller(&self) -> &VerifiedCaller {
        &self.caller
    }

    pub fn binding(&self) -> &GrantBinding {
        &self.binding
    }

    /// The storable form: what was true, without a way back to authority.
    pub fn evidence(&self) -> AuthorityEvidence {
        AuthorityEvidence {
            source: self.caller.source,
            principal: self.caller.principal.clone(),
            authorization_digest: self.binding.authorization_digest.clone(),
            semantics_digest: self.binding.semantics_digest.clone(),
            revision_digest: self.binding.revision_digest.clone(),
        }
    }
}

/// The receipt side of an authority: what was true, and no way back.
///
/// Serializable because a receipt has to be storable, and safe to serialize
/// because nothing in this crate turns one back into an [`AdmissionAuthority`].
/// A payload that *carries* this shape claims a source it did not prove; the
/// next admission does not care, because it resolves the authority again.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorityEvidence {
    pub source: AuthoritySource,
    pub principal: String,
    pub authorization_digest: String,
    pub semantics_digest: String,
    pub revision_digest: String,
}

/// Resolve the authority for one revision through the authority port.
///
/// `Ok(None)` is an answer, not an error: no grant is in force for this
/// revision, and the caller must not act. The resolution is the only mint path
/// for [`AdmissionAuthority`], which is why it lives beside the type rather than
/// in the gate.
pub(super) fn resolve(
    port: &dyn AuthorityPort,
    caller: VerifiedCaller,
    revision_digest: &str,
) -> Result<Option<AdmissionAuthority>, AdmissionError> {
    let resolved = port
        .active_authorization(revision_digest)
        .map_err(|error| AdmissionError::port("active_authorization", error))?;
    Ok(resolved.map(|reference| {
        AdmissionAuthority::resolved(
            caller,
            GrantBinding {
                authorization_digest: reference.authorization_digest,
                semantics_digest: reference.semantics_digest,
                revision_digest: revision_digest.to_owned(),
            },
        )
    }))
}
