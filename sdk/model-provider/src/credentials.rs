//! Credential handles and their scopes.
//!
//! The runtime never sees key material. A configuration names a handle
//! (`credential:…`), an authentication flow issues one, and a vault entry binds
//! that handle to exactly one provider *and* endpoint origin. Resolution is
//! therefore a scope check, not a lookup by name: two providers may use the same
//! readable handle for two different endpoints, and pointing a provider at a new
//! origin finds nothing until the user authorizes that origin ([`CredentialScope::authorizes`]).

use licoup_extension_contracts::provider::{CredentialScope, ProviderConfig};
use std::collections::BTreeMap;
use std::fmt;

/// An opaque host-issued credential handle.
///
/// The value is a handle, never a secret: the provider process owns the key
/// material and resolves this handle on its own side. `Debug` is redacted so a
/// handle cannot leak into a log line through a derived formatter.
#[derive(Clone, PartialEq, Eq)]
pub struct CredentialHandle(String);

impl CredentialHandle {
    pub fn new(token: impl Into<String>) -> Self {
        Self(token.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Whether the handle has the published `credential:` shape.
    pub fn is_handle_shaped(&self) -> bool {
        licoup_extension_contracts::provider::credential_ref_is_handle(&self.0)
    }
}

impl fmt::Debug for CredentialHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CredentialHandle(<redacted>)")
    }
}

/// What resolution found for one configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CredentialResolution {
    /// A handle that authorizes this provider and this origin.
    Resolved {
        scope: CredentialScope,
        handle: CredentialHandle,
    },
    /// No handle is configured, or none was issued for this reference yet.
    NotConfigured,
    /// A handle with this reference exists, but it was issued for another
    /// provider or another origin. The new endpoint does not inherit it.
    ScopeMismatch { configured: CredentialScope },
}

impl CredentialResolution {
    pub fn handle(&self) -> Option<&CredentialHandle> {
        match self {
            Self::Resolved { handle, .. } => Some(handle),
            Self::NotConfigured | Self::ScopeMismatch { .. } => None,
        }
    }

    pub fn scope(&self) -> Option<&CredentialScope> {
        match self {
            Self::Resolved { scope, .. } => Some(scope),
            Self::NotConfigured | Self::ScopeMismatch { .. } => None,
        }
    }

    pub fn is_resolved(&self) -> bool {
        matches!(self, Self::Resolved { .. })
    }
}

/// The host's credential scopes, keyed by provider, origin and handle reference.
#[derive(Debug, Default)]
pub struct CredentialVault {
    entries: BTreeMap<(String, String, String), (CredentialScope, CredentialHandle)>,
}

impl CredentialVault {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a handle for the scope an authentication flow authorized.
    pub fn insert(&mut self, scope: CredentialScope, handle: CredentialHandle) {
        self.entries.insert(
            (
                scope.provider_id.clone(),
                scope.origin.clone(),
                scope.reference.clone(),
            ),
            (scope, handle),
        );
    }

    /// Resolve the handle a configuration names, for the origin it names.
    ///
    /// A reference configured but not found for this origin is reported as a
    /// mismatch when it exists for some other origin, and as unconfigured when
    /// it does not exist at all. Neither case falls back to another origin's
    /// handle.
    pub fn resolve(&self, config: &ProviderConfig) -> CredentialResolution {
        let Some(reference) = config.credential_ref.as_deref() else {
            return CredentialResolution::NotConfigured;
        };
        let Some(origin) = config.origin() else {
            return CredentialResolution::NotConfigured;
        };
        let key = (config.id.clone(), origin, reference.to_owned());
        if let Some((scope, handle)) = self.entries.get(&key)
            && scope.authorizes(config)
        {
            return CredentialResolution::Resolved {
                scope: scope.clone(),
                handle: handle.clone(),
            };
        }
        let configured = self
            .entries
            .values()
            .find(|(scope, _)| scope.reference == reference)
            .map(|(scope, _)| scope.clone());
        match configured {
            Some(configured) => CredentialResolution::ScopeMismatch { configured },
            None => CredentialResolution::NotConfigured,
        }
    }

    /// Remove one exact scope. Returns whether it existed.
    pub fn revoke(&mut self, scope: &CredentialScope) -> bool {
        self.entries
            .remove(&(
                scope.provider_id.clone(),
                scope.origin.clone(),
                scope.reference.clone(),
            ))
            .is_some()
    }

    /// Remove every scope that carries this handle reference, across providers
    /// and origins, the way `auth.revoke` withdraws one issued handle.
    pub fn revoke_reference(&mut self, reference: &str) -> usize {
        let before = self.entries.len();
        self.entries
            .retain(|_, (scope, _)| scope.reference != reference);
        before - self.entries.len()
    }

    pub fn scopes(&self) -> impl Iterator<Item = &CredentialScope> {
        self.entries.values().map(|(scope, _)| scope)
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_extension_contracts::provider::{CatalogSource, ProviderConfig};

    fn config(base_url: &str) -> ProviderConfig {
        ProviderConfig {
            schema: licoup_extension_contracts::wire::PROVIDER.to_owned(),
            id: "synthetic.example.a".to_owned(),
            display_name: "Synthetic".to_owned(),
            base_url: base_url.to_owned(),
            api_dialect: "openai-chat-compatible".to_owned(),
            credential_ref: Some("credential:synthetic".to_owned()),
            config_revision: 1,
            catalog_source: CatalogSource::Static,
            models: Vec::new(),
            compat: BTreeMap::new(),
            stream_adapter: None,
        }
    }

    fn scope(origin: &str) -> CredentialScope {
        CredentialScope {
            reference: "credential:synthetic".to_owned(),
            provider_id: "synthetic.example.a".to_owned(),
            origin: origin.to_owned(),
        }
    }

    #[test]
    fn a_new_origin_does_not_inherit_the_old_endpoints_handle() {
        let mut vault = CredentialVault::new();
        vault.insert(
            scope("http://127.0.0.1:8098"),
            CredentialHandle::new("credential:synthetic"),
        );
        assert!(
            vault
                .resolve(&config("http://127.0.0.1:8098/v1"))
                .is_resolved()
        );

        let moved = config("http://127.0.0.1:8099/v1");
        match vault.resolve(&moved) {
            CredentialResolution::ScopeMismatch { configured } => {
                assert_eq!(configured.origin, "http://127.0.0.1:8098");
            }
            other => panic!("expected a scope mismatch, got {other:?}"),
        }
    }

    #[test]
    fn an_unknown_reference_is_unconfigured_not_a_mismatch() {
        let vault = CredentialVault::new();
        assert_eq!(
            vault.resolve(&config("http://127.0.0.1:8098/v1")),
            CredentialResolution::NotConfigured
        );
    }

    #[test]
    fn revocation_removes_every_scope_of_one_handle() {
        let mut vault = CredentialVault::new();
        vault.insert(
            scope("http://127.0.0.1:8098"),
            CredentialHandle::new("credential:synthetic"),
        );
        vault.insert(
            scope("http://127.0.0.1:8099"),
            CredentialHandle::new("credential:synthetic"),
        );
        assert_eq!(vault.revoke_reference("credential:synthetic"), 2);
        assert!(vault.is_empty());
    }

    #[test]
    fn a_handle_is_redacted_in_diagnostics() {
        let handle = CredentialHandle::new("credential:synthetic-secret-name");
        assert!(!format!("{handle:?}").contains("synthetic-secret-name"));
        assert!(handle.is_handle_shaped());
    }
}
