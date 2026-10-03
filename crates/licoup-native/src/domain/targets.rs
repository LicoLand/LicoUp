// The Agent inventory moved to `licoup-agent-targets`, which is the single
// authority for which Agents exist on this machine and where they live: the
// target catalog and its discovery, the per-Agent model catalog, the packaged
// scan-path manifest and the scan-path rules. Every former path stays reachable
// through this re-export for the FFI command layer, the driver engines, the
// model facts, the conversation history readers and the Agent binaries, which
// are the consumers that still live in `licoup-native`. Every call into it
// takes the port `crate::target_port` composes.
pub use licoup_agent_targets::domain::targets::*;

use std::sync::OnceLock;

/// The catalogue facts for one Agent target, through the port this host
/// composes.
///
/// The probe, the declared canonical identity and the observation timestamp are
/// joined by `licoup-model-catalog`; this host owns the answers, not the
/// judgement. A consumer reads this instead of the raw observed document so a
/// declared model, an observed model and an unknown name stay distinguishable,
/// and historical usage identity keeps resolving through the same registry.
///
/// A probe that cannot answer fails the query: "could not look" is never
/// reported as "nothing there".
pub fn model_selection_facts(
    target: &str,
    params: &serde_json::Value,
) -> anyhow::Result<licoup_model_catalog::SelectionReport> {
    licoup_model_catalog::selection_report(
        licoup_model_catalog::model_catalog_port(),
        observation_cache(),
        &licoup_model_catalog::identity::refresh_cached_snapshot(),
        target,
        params,
    )
}

/// One immutable observation per target, reused only while the owner publishes
/// the same source generation.
fn observation_cache() -> &'static licoup_model_catalog::ObservedCatalogCache {
    static OBSERVATION_CACHE: OnceLock<licoup_model_catalog::ObservedCatalogCache> =
        OnceLock::new();
    OBSERVATION_CACHE.get_or_init(licoup_model_catalog::ObservedCatalogCache::default)
}

#[cfg(test)]
mod selection_tests {
    use super::*;
    use licoup_model_catalog::SelectionEvidence;
    use serde_json::json;

    #[test]
    fn a_target_the_catalogue_cannot_observe_reports_an_error_not_an_empty_catalog() {
        let error = model_selection_facts("not-a-declared-agent", &json!({}))
            .expect_err("an unobservable target is not an empty catalogue");
        assert!(
            error.to_string().contains("model_registry")
                || error.to_string().contains("model_catalog")
                || error.to_string().contains("target")
                || error.to_string().contains("_unavailable"),
            "{error}"
        );
    }

    #[test]
    fn the_declared_unknown_and_observed_states_stay_distinguishable() {
        // Nothing observed, nothing declared: unknown, and no price row or
        // intelligence score changes that.
        assert_eq!(
            licoup_model_catalog::unknown_facts("deepseek-v4-flash").evidence(),
            SelectionEvidence::Unknown
        );
        // The test build holds the synthetic registry: a declared identity is
        // declared only, and availability stays unknown until a source reports
        // the model.
        let registry = licoup_model_catalog::RegistrySnapshot::from_catalog(json!({
            "models": { "moonshotai/kimi-k3": { "name": "Kimi K3" } },
            "providers": {}
        }))
        .expect("synthetic registry");
        let declared = licoup_model_catalog::declared_facts(
            &registry,
            "moonshotai/kimi-k3",
            None,
            Some("kimi-code"),
        );
        assert_eq!(declared.evidence(), SelectionEvidence::DeclaredOnly);
        assert!(!declared.is_available());
    }
}
