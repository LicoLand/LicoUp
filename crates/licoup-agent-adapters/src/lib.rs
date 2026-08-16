//! Independent Agent runtime adapter registry stub.
//!
//! The registry starts empty. Later nodes register concrete adapters; this crate
//! only owns the lookup surface so composition can depend on a stable type.

/// Opaque adapter identity. Values are static catalog names, never paths.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AdapterId {
    name: &'static str,
}

impl AdapterId {
    pub const fn new(name: &'static str) -> Self {
        Self { name }
    }

    pub const fn as_str(self) -> &'static str {
        self.name
    }
}

/// Static adapter registry. Empty until a later node fills entries.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AdapterRegistry {
    adapters: Vec<AdapterId>,
}

impl AdapterRegistry {
    pub fn empty() -> Self {
        Self {
            adapters: Vec::new(),
        }
    }

    pub fn get(&self, id: AdapterId) -> Option<AdapterId> {
        self.adapters.iter().copied().find(|entry| *entry == id)
    }

    pub fn len(&self) -> usize {
        self.adapters.len()
    }

    pub fn is_empty(&self) -> bool {
        self.adapters.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::{AdapterId, AdapterRegistry};

    #[test]
    fn empty_registry_has_no_adapters() {
        let registry = AdapterRegistry::empty();
        assert!(registry.is_empty());
        assert_eq!(registry.len(), 0);
        assert_eq!(registry.get(AdapterId::new("codex")), None);
    }
}
