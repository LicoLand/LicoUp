//! Authority-backed Membership Profile snapshots.
//!
//! Persistent Profile intent lives in the conversation store. Everything that
//! changes over time (model price, intelligence score, Skill availability,
//! runtime environment and readiness) is derived per request from its
//! existing owner and cached only inside that request. The projection
//! allowlists opaque ids, enums, numbers and booleans; it never carries a
//! prompt, credential, absolute path, machine identity or runtime endpoint.

pub use super::{Membership, MembershipProfileSnapshot, ProfileIntent};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};

/// Bounded, privacy-safe target facts read from the Agent target owner.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetFacts {
    pub status: Option<String>,
    pub model: Option<String>,
    pub environment: Option<String>,
    pub capabilities: Vec<String>,
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

/// Hard constraints applied before any ordering. Every required fact must be
/// present and equal/contained; a missing membership binding is a hard
/// failure, never a silent drop.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CandidateFilters {
    #[serde(default)]
    pub required_authority: Vec<String>,
    #[serde(default)]
    pub required_skills: Vec<String>,
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_readiness: Option<String>,
    #[serde(default)]
    pub membership_ids: Vec<String>,
    #[serde(default)]
    pub pinned_membership_ids: Vec<String>,
    #[serde(default)]
    pub preferred_skills: Vec<String>,
    #[serde(default)]
    pub preferred_capabilities: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
}

/// Apply hard filters, then order by the stable lexicographic tuple frozen by
/// Decision 0004: explicit pin, preference match, verified reliability,
/// coding score, known expected price, observed latency and Membership id.
/// Unknown optional facts remain unknown and sort after known facts.
pub fn rank_candidates(
    snapshots: Vec<MembershipProfileSnapshot>,
    filters: &CandidateFilters,
) -> Result<Vec<MembershipProfileSnapshot>, String> {
    let required_ids = filters.membership_ids.iter().collect::<BTreeSet<_>>();
    let available = snapshots
        .iter()
        .map(|snapshot| &snapshot.membership_id)
        .collect::<BTreeSet<_>>();
    if !required_ids.is_subset(&available) {
        return Err("profile_candidate_rejected".to_owned());
    }
    let mut eligible = snapshots
        .into_iter()
        .filter(|snapshot| {
            (required_ids.is_empty() || required_ids.contains(&snapshot.membership_id))
                && candidate_eligible(snapshot, filters)
        })
        .collect::<Vec<_>>();
    let remaining = eligible
        .iter()
        .map(|snapshot| &snapshot.membership_id)
        .collect::<BTreeSet<_>>();
    if !required_ids.is_subset(&remaining) {
        return Err("profile_candidate_rejected".to_owned());
    }
    let pin_order = filters
        .pinned_membership_ids
        .iter()
        .chain(filters.membership_ids.iter())
        .enumerate()
        .fold(BTreeMap::new(), |mut result, (ordinal, membership_id)| {
            result.entry(membership_id.as_str()).or_insert(ordinal);
            result
        });
    eligible.sort_by(|left, right| {
        pin_order
            .get(left.membership_id.as_str())
            .copied()
            .unwrap_or(usize::MAX)
            .cmp(
                &pin_order
                    .get(right.membership_id.as_str())
                    .copied()
                    .unwrap_or(usize::MAX),
            )
            .then_with(|| preference_misses(left, filters).cmp(&preference_misses(right, filters)))
            .then_with(|| reliability_rank(left).cmp(&reliability_rank(right)))
            .then_with(|| optional_desc(left.intelligence_score, right.intelligence_score))
            .then_with(|| optional_price(left).cmp(&optional_price(right)))
            .then_with(|| optional_asc(left.latency_class, right.latency_class))
            .then_with(|| left.membership_id.cmp(&right.membership_id))
    });
    Ok(eligible)
}

fn candidate_eligible(snapshot: &MembershipProfileSnapshot, filters: &CandidateFilters) -> bool {
    snapshot
        .required_capabilities
        .iter()
        .all(|required| snapshot.capabilities.iter().any(|value| value == required))
        && snapshot
            .skill_references
            .iter()
            .all(|required| snapshot.skills.iter().any(|value| value == required))
        && filters
            .required_authority
            .iter()
            .all(|required| snapshot.authority.iter().any(|value| value == required))
        && filters
            .required_skills
            .iter()
            .all(|required| snapshot.skills.iter().any(|value| value == required))
        && filters
            .required_capabilities
            .iter()
            .all(|required| snapshot.capabilities.iter().any(|value| value == required))
        && filters
            .required_model
            .as_deref()
            .map(|required| snapshot.model.as_deref() == Some(required))
            .unwrap_or(true)
        && filters
            .required_environment
            .as_deref()
            .map(|required| snapshot.environment.as_deref() == Some(required))
            .unwrap_or(true)
        && filters
            .required_readiness
            .as_deref()
            .map(|required| snapshot.readiness.as_deref() == Some(required))
            .unwrap_or(true)
}

fn preference_misses(snapshot: &MembershipProfileSnapshot, filters: &CandidateFilters) -> usize {
    let model = filters
        .preferred_model
        .as_deref()
        .or(snapshot.preferred_model.as_deref());
    let environment = filters
        .preferred_environment
        .as_deref()
        .or(snapshot.preferred_environment.as_deref());
    usize::from(model.is_some_and(|value| snapshot.model.as_deref() != Some(value)))
        + usize::from(
            environment.is_some_and(|value| snapshot.environment.as_deref() != Some(value)),
        )
        + filters
            .preferred_skills
            .iter()
            .filter(|value| !snapshot.skills.contains(value))
            .count()
        + filters
            .preferred_capabilities
            .iter()
            .chain(snapshot.preferred_capabilities.iter())
            .filter(|value| !snapshot.capabilities.contains(value))
            .count()
}

fn reliability_rank(snapshot: &MembershipProfileSnapshot) -> (bool, u8) {
    let Some(value) = snapshot.reliability_class.as_deref() else {
        return (true, u8::MAX);
    };
    let rank = match value {
        "verified" | "high" | "ready" => 0,
        "standard" | "partial" => 1,
        "low" | "unverified" => 2,
        _ => 3,
    };
    (false, rank)
}

fn optional_desc(left: Option<i64>, right: Option<i64>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => right.cmp(&left),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn optional_asc<T: Ord>(left: Option<T>, right: Option<T>) -> Ordering {
    match (left, right) {
        (Some(left), Some(right)) => left.cmp(&right),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

fn optional_price(snapshot: &MembershipProfileSnapshot) -> (bool, u64) {
    let Some(input) = snapshot.price_input_usd_per_million_tokens else {
        return (true, u64::MAX);
    };
    let Some(output) = snapshot.price_output_usd_per_million_tokens else {
        return (true, u64::MAX);
    };
    if !input.is_finite() || !output.is_finite() || input < 0.0 || output < 0.0 {
        return (true, u64::MAX);
    }
    (false, ((input + output) * 1_000_000.0).round() as u64)
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
    let mut capabilities = target
        .as_ref()
        .map(|facts| facts.capabilities.clone())
        .unwrap_or_default();
    capabilities.sort();
    capabilities.dedup();
    let mut skills = authority.skills(&agent_id);
    if is_assistant
        && !super::ASSISTANT_WORKFLOW_AUTHORING_SKILL_SOURCE
            .trim()
            .is_empty()
        && intent
            .skill_references
            .iter()
            .any(|skill| skill == super::ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID)
    {
        let bundled = super::ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID.to_owned();
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
    Arc::new(Mutex::new(Box::new(ProductionSnapshotAuthority)))
}

struct ProductionSnapshotAuthority;

impl ProfileSnapshotAuthority for ProductionSnapshotAuthority {
    fn target_facts(&mut self, agent_id: &str) -> Option<TargetFacts> {
        let inspected = crate::domain::targets::inspect_target_read_only(agent_id).ok()?;
        let target = inspected.get("target")?;
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
        let mut capabilities = ["conversationDriver", "conversationReadiness"]
            .into_iter()
            .filter_map(|pointer| {
                target
                    .pointer(&format!("/adapterCapabilities/{pointer}"))
                    .and_then(serde_json::Value::as_str)
                    .filter(|value| *value == "supported" || *value == "ready")
                    .map(|value| format!("{pointer}:{value}"))
            })
            .collect::<Vec<_>>();
        capabilities
            .extend(crate::platform::runtime_adapters::native_capabilities_for_agent(agent_id));
        capabilities.sort();
        capabilities.dedup();
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
        crate::domain::agent_intelligence_catalog::agent_model_max_intelligence(agent_id, model)
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
        ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID, MembershipAccess, MembershipStatus, Principal,
        PrincipalKind, ProfileResponsibility, assistant_workflow_authoring_prompt,
    };
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
                ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID.to_owned(),
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
                .contains(&"caller-asserted-capability".to_owned())
        );
        assert_eq!(
            snapshot.capabilities,
            vec!["conversationDriver:supported".to_owned()]
        );
        assert!(snapshot.skills.contains(&"skill-a".to_owned()));
        assert!(
            !snapshot
                .skills
                .contains(&"caller-asserted-skill".to_owned())
        );
        assert!(
            snapshot
                .skills
                .contains(&ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID.to_owned())
        );
        let assistant_prompt = assistant_workflow_authoring_prompt();
        assert!(assistant_prompt.len() <= 256);
        assert!(assistant_prompt.contains("Understand and complete the user's request."));
        assert!(assistant_prompt.contains("use tools freely"));
        assert!(!assistant_prompt.contains("must not"));
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

    #[test]
    fn hard_filters_precede_the_stable_lexicographic_order() {
        let mut first = snapshot("membership:b");
        first.reliability_class = Some("verified".to_owned());
        first.intelligence_score = Some(8);
        first.price_input_usd_per_million_tokens = Some(4.0);
        first.price_output_usd_per_million_tokens = Some(8.0);
        first.latency_class = Some(2);
        let mut pinned = snapshot("membership:c");
        pinned.reliability_class = None;
        pinned.intelligence_score = None;
        let mut cheap = snapshot("membership:a");
        cheap.reliability_class = Some("verified".to_owned());
        cheap.intelligence_score = Some(8);
        cheap.price_input_usd_per_million_tokens = Some(1.0);
        cheap.price_output_usd_per_million_tokens = Some(2.0);
        cheap.latency_class = Some(1);
        let ranked = rank_candidates(
            vec![first, pinned, cheap],
            &CandidateFilters {
                required_capabilities: vec!["conversationDriver:supported".to_owned()],
                pinned_membership_ids: vec!["membership:c".to_owned()],
                ..CandidateFilters::default()
            },
        )
        .unwrap();
        assert_eq!(
            ranked
                .iter()
                .map(|candidate| candidate.membership_id.as_str())
                .collect::<Vec<_>>(),
            vec!["membership:c", "membership:a", "membership:b"]
        );
        let rejected = rank_candidates(
            ranked,
            &CandidateFilters {
                membership_ids: vec!["membership:c".to_owned()],
                required_skills: vec!["missing".to_owned()],
                ..CandidateFilters::default()
            },
        );
        assert_eq!(rejected.unwrap_err(), "profile_candidate_rejected");
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

    fn snapshot(id: &str) -> MembershipProfileSnapshot {
        MembershipProfileSnapshot {
            conversation_id: "conversation:g".to_owned(),
            membership_id: id.to_owned(),
            agent_id: "agent:one".to_owned(),
            intent_revision: 1,
            responsibility: ProfileResponsibility::Member,
            required_capabilities: Vec::new(),
            preferred_capabilities: Vec::new(),
            skill_references: Vec::new(),
            preferred_model: None,
            preferred_reasoning_effort: None,
            preferred_environment: None,
            model: Some("model-a".to_owned()),
            capabilities: vec!["conversationDriver:supported".to_owned()],
            skills: vec!["skill-a".to_owned()],
            environment: Some("local".to_owned()),
            readiness: Some("ready".to_owned()),
            price_input_usd_per_million_tokens: None,
            price_output_usd_per_million_tokens: None,
            intelligence_score: None,
            reliability_class: None,
            latency_class: None,
            authority: vec!["conversation.act".to_owned()],
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
                capabilities: vec!["conversationDriver:supported".to_owned()],
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
}
