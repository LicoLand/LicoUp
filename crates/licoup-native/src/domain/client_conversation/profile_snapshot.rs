//! Authority-backed Membership Profile snapshots.
//!
//! Persistent Profile intent lives in the conversation store. Everything that
//! changes over time (model price, intelligence score, Skill availability,
//! runtime environment and readiness) is derived per request from its
//! existing owner and cached only inside that request. The projection
//! allowlists opaque ids, enums, numbers and booleans; it never carries a
//! prompt, credential, absolute path, machine identity or runtime endpoint.

pub use super::{CapabilityFact, CapabilityFactState, Membership, MembershipProfileSnapshot, ProfileIntent};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// Bounded, privacy-safe target facts read from the Agent target owner.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetFacts {
    pub status: Option<String>,
    pub model: Option<String>,
    pub environment: Option<String>,
    /// Projected capability facts with their state and owner. A fact whose
    /// owner could not be read stays `unknown` here and is never dropped.
    pub capabilities: Vec<CapabilityFact>,
    pub readiness: Option<String>,
    pub reliability_class: Option<String>,
    pub latency_class: Option<u8>,
}

/// Allowlisted model price facts projected from the pricing owner. Input and
/// output prices are kept separate so the projection never invents a blended
/// single number that the owner does not expose.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PriceFacts {
    pub input: f64,
    pub output: f64,
}

/// One read of one existing owner. Implementations must project allowlisted
/// facts only and are expected to be request-scoped (the caller reads each
/// owner at most once per request/revision).
pub trait ProfileSnapshotAuthority: Send {
    fn target_facts(&mut self, agent_id: &str) -> Option<TargetFacts>;
    fn model_price_usd_per_million_tokens(&mut self, model: &str) -> Option<PriceFacts>;
    fn coding_score(&mut self, agent_id: &str, model: &str) -> Option<i64>;
    fn skill_names(&mut self, agent_id: &str) -> Vec<String>;
}

pub type SharedSnapshotAuthority = Arc<Mutex<Box<dyn ProfileSnapshotAuthority>>>;

/// Request-scoped wrapper that reads each owner at most once per key. The
/// cache lives only for the duration of one projection call.
struct RequestScopedAuthority<'a> {
    inner: &'a mut dyn ProfileSnapshotAuthority,
    targets: BTreeMap<String, Option<TargetFacts>>,
    prices: BTreeMap<String, Option<PriceFacts>>,
    scores: BTreeMap<(String, String), Option<i64>>,
    skills: BTreeMap<String, Vec<String>>,
}

impl<'a> RequestScopedAuthority<'a> {
    fn new(inner: &'a mut dyn ProfileSnapshotAuthority) -> Self {
        Self {
            inner,
            targets: BTreeMap::new(),
            prices: BTreeMap::new(),
            scores: BTreeMap::new(),
            skills: BTreeMap::new(),
        }
    }

    fn target_facts(&mut self, agent_id: &str) -> Option<TargetFacts> {
        if let Some(cached) = self.targets.get(agent_id) {
            return cached.clone();
        }
        let read = self.inner.target_facts(agent_id);
        self.targets.insert(agent_id.to_owned(), read.clone());
        read
    }

    fn model_price(&mut self, model: &str) -> Option<PriceFacts> {
        if let Some(cached) = self.prices.get(model) {
            return *cached;
        }
        let read = self.inner.model_price_usd_per_million_tokens(model);
        self.prices.insert(model.to_owned(), read);
        read
    }

    fn score(&mut self, agent_id: &str, model: &str) -> Option<i64> {
        let key = (agent_id.to_owned(), model.to_owned());
        if let Some(cached) = self.scores.get(&key) {
            return *cached;
        }
        let read = self.inner.coding_score(agent_id, model);
        self.scores.insert(key, read);
        read
    }

    fn skills(&mut self, agent_id: &str) -> Vec<String> {
        if let Some(cached) = self.skills.get(agent_id) {
            return cached.clone();
        }
        let read = self.inner.skill_names(agent_id);
        self.skills.insert(agent_id.to_owned(), read.clone());
        read
    }
}

/// Derive one Membership Profile snapshot from persistent intent plus the
/// existing owners. `authority` is locked for one projection and each owner is
/// read at most once per request through the request-scoped cache.
pub fn project_profile_snapshot(
    conversation_id: &str,
    membership: &Membership,
    intent: &ProfileIntent,
    is_assistant: bool,
    authority: &SharedSnapshotAuthority,
) -> MembershipProfileSnapshot {
    let mut guard = authority
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let mut scoped = RequestScopedAuthority::new(guard.as_mut());
    project_with(
        &mut scoped,
        conversation_id,
        membership,
        intent,
        is_assistant,
    )
}

/// Project one or more Membership Profiles in one request while sharing one
/// request-scoped authority cache, so each owner is read at most once per
/// request/revision regardless of how many Memberships are projected.
pub fn project_profile_snapshots(
    conversation_id: &str,
    members: &[(Membership, ProfileIntent, bool)],
    authority: &SharedSnapshotAuthority,
) -> Vec<MembershipProfileSnapshot> {
    let mut guard = authority
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    let mut scoped = RequestScopedAuthority::new(guard.as_mut());
    members
        .iter()
        .map(|(membership, intent, is_assistant)| {
            project_with(
                &mut scoped,
                conversation_id,
                membership,
                intent,
                *is_assistant,
            )
        })
        .collect()
}

fn project_with(
    authority: &mut RequestScopedAuthority<'_>,
    conversation_id: &str,
    membership: &Membership,
    intent: &ProfileIntent,
    is_assistant: bool,
) -> MembershipProfileSnapshot {
    let agent_id = membership
        .principal
        .agent_id
        .clone()
        .unwrap_or_else(|| membership.principal.id.clone());
    let target = authority.target_facts(&agent_id);
    let model = target.as_ref().and_then(|facts| facts.model.clone());
    let price = model
        .as_deref()
        .and_then(|model| authority.model_price(model));
    let score = model
        .as_deref()
        .and_then(|model| authority.score(&agent_id, model));
    // The projected facts keep their state, so a participant whose owner could
    // not be read stays unknown instead of losing the fact entirely.
    let mut capabilities = target
        .as_ref()
        .map(|facts| facts.capabilities.clone())
        .unwrap_or_default();
    capabilities.sort_by(|left, right| left.name.cmp(&right.name));
    capabilities.dedup_by(|left, right| left.name == right.name);
    let mut skills = authority.skills(&agent_id);
    if is_assistant
        && !licoup_mcp::guide_skill::LICOUP_GUIDE_SKILL_SOURCE.trim().is_empty()
        && intent
            .skill_references
            .iter()
            .any(|skill| skill == licoup_mcp::guide_skill::LICOUP_GUIDE_SKILL_ID)
    {
        let bundled = licoup_mcp::guide_skill::LICOUP_GUIDE_SKILL_ID.to_owned();
        if !skills.contains(&bundled) {
            skills.push(bundled);
        }
    }
    skills.sort();
    skills.dedup();
    let authority = match membership.access {
        super::MembershipAccess::Owner => vec![
            "conversation.act".to_owned(),
            "conversation.manage".to_owned(),
            "conversation.read".to_owned(),
        ],
        super::MembershipAccess::Member => vec![
            "conversation.act".to_owned(),
            "conversation.read".to_owned(),
        ],
    };
    let task_tags = model
        .as_deref()
        .map(crate::domain::agent_intelligence_catalog::task_tags_for_model)
        .unwrap_or_default();
    MembershipProfileSnapshot {
        conversation_id: conversation_id.to_owned(),
        membership_id: membership.id.clone(),
        agent_id,
        intent_revision: intent.revision,
        responsibility: intent.responsibility,
        required_capabilities: intent.required_capabilities.clone(),
        preferred_capabilities: intent.preferred_capabilities.clone(),
        skill_references: intent.skill_references.clone(),
        preferred_model: intent.preferred_model.clone(),
        preferred_reasoning_effort: intent.preferred_reasoning_effort.clone(),
        preferred_environment: intent.preferred_environment.clone(),
        model,
        capabilities,
        skills,
        environment: target.as_ref().and_then(|facts| facts.environment.clone()),
        readiness: target.as_ref().and_then(|facts| facts.readiness.clone()),
        price_input_usd_per_million_tokens: price.map(|price| price.input),
        price_output_usd_per_million_tokens: price.map(|price| price.output),
        intelligence_score: score,
        task_tags,
        reliability_class: target
            .as_ref()
            .and_then(|facts| facts.reliability_class.clone()),
        latency_class: target.as_ref().and_then(|facts| facts.latency_class),
        authority,
    }
}

/// Production authority backed by the existing named owners. Every read is
/// projected to allowlisted facts; raw paths and runtime values never leave
/// this boundary.
pub fn production_snapshot_authority() -> SharedSnapshotAuthority {
    Arc::new(Mutex::new(Box::new(ProductionSnapshotAuthority {
        port: crate::domain::target_port::agent_target_port(),
    })))
}

struct ProductionSnapshotAuthority {
    port: crate::port::AgentTargetPort,
}

impl ProfileSnapshotAuthority for ProductionSnapshotAuthority {
    fn target_facts(&mut self, agent_id: &str) -> Option<TargetFacts> {
        // Capability facts are read from their own owners and stay readable
        // even when the Agent's target record is not: an unreadable target must
        // not collapse an unknown ability into an absent one.
        let capabilities = crate::platform::runtime_adapters::native_capabilities_for_agent(agent_id)
            .into_iter()
            .map(|fact| {
                CapabilityFact::new(
                    fact.name,
                    CapabilityFactState::from_wire(fact.state.wire_name())
                        .unwrap_or(CapabilityFactState::Unknown),
                    fact.source,
                )
            })
            .collect::<Vec<_>>();
        let inspected = crate::domain::targets::inspect_target_read_only(&self.port, agent_id).ok();
        let target = inspected
            .as_ref()
            .and_then(|inspected| inspected.get("target"));
        let Some(target) = target else {
            return Some(TargetFacts {
                capabilities,
                ..TargetFacts::default()
            });
        };
        let status = target
            .get("status")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let model = target
            .get("model")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .or_else(|| {
                target
                    .pointer("/modelCatalog/defaultModel")
                    .and_then(serde_json::Value::as_str)
                    .filter(|value| !value.is_empty())
                    .map(str::to_owned)
            });
        let environment = target
            .get("location")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let readiness = target
            .pointer("/adapterCapabilities/conversationReadiness")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_owned);
        let reliability_class = target
            .pointer("/adapterCapabilities/conversationConsecutivePasses")
            .and_then(serde_json::Value::as_u64)
            .filter(|passes| *passes > 0)
            .map(|_| "verified".to_owned());
        Some(TargetFacts {
            status,
            model,
            environment,
            capabilities,
            readiness,
            reliability_class,
            latency_class: None,
        })
    }

    fn model_price_usd_per_million_tokens(&mut self, model: &str) -> Option<PriceFacts> {
        crate::domain::provider_model_pricing::model_price(model).map(|price| PriceFacts {
            input: price.input,
            output: price.output,
        })
    }

    fn coding_score(&mut self, agent_id: &str, model: &str) -> Option<i64> {
        crate::domain::agent_intelligence_catalog::merged_agent_model_score(agent_id, model)
            .or_else(|| {
                crate::domain::agent_intelligence_catalog::agent_model_max_intelligence(
                    agent_id, model,
                )
            })
    }

    fn skill_names(&mut self, agent_id: &str) -> Vec<String> {
        crate::domain::skill_hub::skill_list(&serde_json::json!({ "agent": agent_id }))
            .ok()
            .and_then(|value| {
                value
                    .get("skills")
                    .and_then(serde_json::Value::as_array)
                    .cloned()
            })
            .map(|skills| {
                skills
                    .iter()
                    .filter_map(|skill| skill.get("skillId"))
                    .filter_map(serde_json::Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::super::{
        MembershipAccess, MembershipStatus, Principal, PrincipalKind, ProfileResponsibility,
    };
    use licoup_mcp::guide_skill::LICOUP_GUIDE_SKILL_ID;
    use super::*;

    #[test]
    fn request_scoped_authority_reads_each_owner_once() {
        let calls = Arc::new(Mutex::new(BTreeMap::<&'static str, usize>::new()));
        let mut inner = CountingAuthority {
            calls: Arc::clone(&calls),
        };
        let mut scoped = RequestScopedAuthority::new(&mut inner);
        for _ in 0..3 {
            assert_eq!(
                scoped.target_facts("agent:one").unwrap().status.as_deref(),
                Some("ready")
            );
            assert_eq!(
                scoped.model_price("model-a"),
                Some(PriceFacts {
                    input: 1.0,
                    output: 2.0
                })
            );
            assert_eq!(scoped.score("agent:one", "model-a"), Some(2));
            assert_eq!(scoped.skills("agent:one"), vec!["skill-a".to_owned()]);
        }
        let recorded = calls.lock().unwrap();
        assert_eq!(
            recorded.clone(),
            BTreeMap::from([
                ("target_facts", 1),
                ("model_price", 1),
                ("score", 1),
                ("skills", 1),
            ])
        );
    }

    #[test]
    fn intent_cannot_assert_derived_truth_or_authority() {
        let calls = Arc::new(Mutex::new(BTreeMap::<&'static str, usize>::new()));
        let authority: SharedSnapshotAuthority =
            Arc::new(Mutex::new(Box::new(CountingAuthority {
                calls: Arc::clone(&calls),
            })));
        let membership = membership("membership:one", MembershipAccess::Member);
        let intent = ProfileIntent {
            revision: 3,
            required_capabilities: vec!["caller-asserted-capability".to_owned()],
            preferred_capabilities: vec!["caller-preference".to_owned()],
            skill_references: vec![
                "caller-asserted-skill".to_owned(),
                LICOUP_GUIDE_SKILL_ID.to_owned(),
            ],
            preferred_model: Some("caller-model".to_owned()),
            preferred_reasoning_effort: Some("high".to_owned()),
            preferred_environment: Some("caller-environment".to_owned()),
            responsibility: ProfileResponsibility::Assistant,
            updated_at_unix_ms: 9,
        };
        let snapshot =
            project_profile_snapshot("conversation:g", &membership, &intent, true, &authority);
        assert_eq!(snapshot.membership_id, "membership:one");
        assert_eq!(snapshot.intent_revision, 3);
        assert_eq!(snapshot.model.as_deref(), Some("target-model"));
        assert_eq!(snapshot.price_input_usd_per_million_tokens, Some(1.0));
        assert_eq!(snapshot.price_output_usd_per_million_tokens, Some(2.0));
        assert_eq!(snapshot.intelligence_score, Some(2));
        assert!(
            !snapshot
                .capabilities
                .iter()
                .any(|fact| fact.name == "caller-asserted-capability")
        );
        assert_eq!(
            snapshot.capabilities,
            vec![CapabilityFact::new(
                "conversationDriver:supported",
                CapabilityFactState::Declared,
                "conversation-readiness",
            )]
        );
        assert!(snapshot.skills.contains(&"skill-a".to_owned()));
        assert!(
            !snapshot
                .skills
                .contains(&"caller-asserted-skill".to_owned())
        );
        assert!(snapshot.skills.contains(&LICOUP_GUIDE_SKILL_ID.to_owned()));
        assert_eq!(snapshot.environment.as_deref(), Some("local"));
        assert_eq!(snapshot.readiness.as_deref(), Some("ready"));
        assert_eq!(
            snapshot.authority,
            vec![
                "conversation.act".to_owned(),
                "conversation.read".to_owned()
            ]
        );
        let encoded = serde_json::to_value(&snapshot).unwrap();
        assert!(encoded.get("id").is_none());
        assert!(encoded.get("displayName").is_none());
        assert!(encoded.get("updatedAtUnixMs").is_none());
    }

    fn membership(id: &str, access: MembershipAccess) -> Membership {
        Membership {
            id: id.to_owned(),
            conversation_id: "conversation:g".to_owned(),
            principal: Principal {
                id: "agent:one".to_owned(),
                kind: PrincipalKind::Agent,
                display_name: "One".to_owned(),
                agent_id: Some("agent:one".to_owned()),
                created_at_unix_ms: 1,
            },
            access,
            status: MembershipStatus::Active,
            joined_at_unix_ms: 1,
            left_at_unix_ms: None,
        }
    }

    struct CountingAuthority {
        calls: Arc<Mutex<BTreeMap<&'static str, usize>>>,
    }

    impl ProfileSnapshotAuthority for CountingAuthority {
        fn target_facts(&mut self, _agent_id: &str) -> Option<TargetFacts> {
            *self
                .calls
                .lock()
                .unwrap()
                .entry("target_facts")
                .or_insert(0) += 1;
            Some(TargetFacts {
                status: Some("ready".to_owned()),
                model: Some("target-model".to_owned()),
                environment: Some("local".to_owned()),
                capabilities: vec![CapabilityFact::new(
                    "conversationDriver:supported",
                    CapabilityFactState::Declared,
                    "conversation-readiness",
                )],
                readiness: Some("ready".to_owned()),
                reliability_class: Some("verified".to_owned()),
                latency_class: Some(1),
            })
        }

        fn model_price_usd_per_million_tokens(&mut self, _model: &str) -> Option<PriceFacts> {
            *self.calls.lock().unwrap().entry("model_price").or_insert(0) += 1;
            Some(PriceFacts {
                input: 1.0,
                output: 2.0,
            })
        }

        fn coding_score(&mut self, _agent_id: &str, _model: &str) -> Option<i64> {
            *self.calls.lock().unwrap().entry("score").or_insert(0) += 1;
            Some(2)
        }

        fn skill_names(&mut self, _agent_id: &str) -> Vec<String> {
            *self.calls.lock().unwrap().entry("skills").or_insert(0) += 1;
            vec!["skill-a".to_owned()]
        }
    }

    /// A participant whose capability owners could not be read answers with
    /// states, never with an empty list.
    #[test]
    fn an_unreadable_owner_keeps_its_facts_unknown_instead_of_empty() {
        let authority: SharedSnapshotAuthority =
            Arc::new(Mutex::new(Box::new(UnreadableCapabilityAuthority)));
        let snapshot = project_profile_snapshot(
            "conversation:g",
            &membership("membership:one", MembershipAccess::Member),
            &ProfileIntent::default(),
            false,
            &authority,
        );
        assert_eq!(snapshot.capabilities.len(), 2);
        assert!(snapshot.capabilities.iter().all(|fact| {
            fact.state == CapabilityFactState::Unknown && !fact.source.is_empty()
        }));
        assert!(
            snapshot
                .capabilities
                .iter()
                .any(|fact| fact.name == "image-input")
        );
    }

    struct UnreadableCapabilityAuthority;

    impl ProfileSnapshotAuthority for UnreadableCapabilityAuthority {
        fn target_facts(&mut self, _agent_id: &str) -> Option<TargetFacts> {
            Some(TargetFacts {
                capabilities: vec![
                    CapabilityFact::new(
                        "image-input",
                        CapabilityFactState::Unknown,
                        "driver-inventory",
                    ),
                    CapabilityFact::new(
                        "real-interface",
                        CapabilityFactState::Unknown,
                        "agent-desktop-presence",
                    ),
                ],
                ..TargetFacts::default()
            })
        }

        fn model_price_usd_per_million_tokens(&mut self, _model: &str) -> Option<PriceFacts> {
            None
        }

        fn coding_score(&mut self, _agent_id: &str, _model: &str) -> Option<i64> {
            None
        }

        fn skill_names(&mut self, _agent_id: &str) -> Vec<String> {
            Vec::new()
        }
    }
}
