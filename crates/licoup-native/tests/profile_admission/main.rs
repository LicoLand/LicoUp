//! Profile admission through the public conversation actions.
//!
//! One Profile plus the projected capability facts yields either one resolved
//! participant with the model and reasoning its Profile intent carries, or a
//! typed refusal that names the requirement no declared fact satisfied. The
//! capability view itself is readable from the same action, an unreadable owner
//! stays `unknown` instead of becoming an absence, and the conversation store
//! keeps its schema version and its responsibility constraint.

use licoup_conversation::store::CURRENT_SCHEMA_VERSION;
use licoup_native::domain::client_conversation::ConversationService;
use serde_json::{Value, json};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// An Agent id no packaged capability owner knows, so every fact answered for
/// it is unknown rather than absent.
const UNLISTED_AGENT: &str = "unlisted-agent";
const DECLARING_AGENT: &str = "codex";

struct ProfileFixture {
    root: PathBuf,
    service: ConversationService,
}

impl ProfileFixture {
    fn new() -> Self {
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let suffix = format!(
            "{}-{sequence}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        );
        let root = std::env::temp_dir().join(format!("lico-profile-admission-{suffix}"));
        fs::create_dir_all(&root).unwrap();
        let service = ConversationService::open(&root).unwrap();
        Self { root, service }
    }

    /// One conversation with an owner and one agent member per Agent id.
    fn create_group(&self, agent_ids: &[&str]) -> (String, String, Vec<String>) {
        let members = agent_ids
            .iter()
            .map(|agent_id| {
                json!({
                    "principal": {
                        "id": format!("agent:{agent_id}"),
                        "kind": "agent",
                        "displayName": agent_id,
                        "agentId": agent_id,
                    },
                    "access": "member",
                })
            })
            .collect::<Vec<_>>();
        let conversation = self
            .service
            .execute(json!({
                "action": "conversation.create",
                "title": "Admission",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": members,
            }))
            .unwrap();
        let memberships = conversation["memberships"].as_array().unwrap();
        let owner = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "human")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let agents = agent_ids
            .iter()
            .map(|agent_id| {
                memberships
                    .iter()
                    .find(|membership| {
                        membership["principal"]["agentId"].as_str() == Some(*agent_id)
                    })
                    .unwrap()["id"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect();
        (
            conversation["id"].as_str().unwrap().to_owned(),
            owner,
            agents,
        )
    }

    fn profile_revision(&self, membership_id: &str) -> i64 {
        self.service
            .store()
            .membership_profile(membership_id)
            .unwrap()
            .unwrap()
            .revision
    }

    fn update_intent(
        &self,
        conversation_id: &str,
        owner: &str,
        membership_id: &str,
        intent: Value,
    ) -> Value {
        let revision = self.profile_revision(membership_id);
        self.service
            .execute(json!({
                "action": "conversation.profile.update",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "ownerMembershipId": owner,
                "expectedRevision": revision,
                "intent": intent,
            }))
            .unwrap()
    }

    fn candidates(&self, conversation_id: &str, filters: Value) -> Value {
        self.service
            .execute(json!({
                "action": "conversation.profile.candidates",
                "conversationId": conversation_id,
                "filters": filters,
            }))
            .unwrap()
    }

    fn event_count(&self, conversation_id: &str) -> i64 {
        self.service
            .execute(json!({
                "action": "conversation.get",
                "conversationId": conversation_id,
            }))
            .unwrap()["eventCount"]
            .as_i64()
            .unwrap()
    }
}

impl Drop for ProfileFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn candidate<'a>(candidates: &'a Value, membership_id: &str) -> &'a Value {
    candidates
        .as_array()
        .unwrap()
        .iter()
        .find(|candidate| candidate["membershipId"] == membership_id)
        .unwrap_or_else(|| panic!("candidate {membership_id} must be reported"))
}

fn fact<'a>(candidate: &'a Value, name: &str) -> &'a Value {
    candidate["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .find(|fact| fact["name"] == name)
        .unwrap_or_else(|| panic!("the capability view must report {name}"))
}

/// Arrange two participants and a Profile that requires image input.
fn arrange(fixture: &ProfileFixture) -> (String, String, String) {
    let (conversation_id, owner, agents) = fixture.create_group(&[DECLARING_AGENT, UNLISTED_AGENT]);
    let declaring = agents[0].clone();
    let unlisted = agents[1].clone();
    fixture.update_intent(
        &conversation_id,
        &owner,
        &declaring,
        json!({
            "preferredModel": "intent-model-declaring",
            "preferredReasoningEffort": "high",
            "preferredCapabilities": ["image-input"],
        }),
    );
    fixture.update_intent(
        &conversation_id,
        &owner,
        &unlisted,
        json!({
            "preferredModel": "intent-model-unlisted",
            "preferredReasoningEffort": "low",
        }),
    );
    (conversation_id, declaring, unlisted)
}

#[test]
fn the_capability_view_reports_each_state_with_its_owner() {
    let fixture = ProfileFixture::new();
    let (conversation_id, declaring, unlisted) = arrange(&fixture);
    let response = fixture.candidates(&conversation_id, json!({}));
    let candidates = &response["candidates"];

    let declared = fact(candidate(candidates, &declaring), "image-input");
    assert_eq!(declared["state"], json!("declared"));
    assert_eq!(declared["source"], json!("driver-inventory"));

    // A participant no packaged owner knows answers with states: unknown, not
    // an absent fact and never an empty list.
    let unknown = fact(candidate(candidates, &unlisted), "image-input");
    assert_eq!(unknown["state"], json!("unknown"));
    assert_eq!(unknown["source"], json!("driver-inventory"));
    for fact in candidate(candidates, &unlisted)["capabilities"]
        .as_array()
        .unwrap()
    {
        assert_eq!(
            fact["state"],
            json!("unknown"),
            "no participant declares a capability its owner did not affirm"
        );
    }
}

#[test]
fn admission_resolves_the_declaring_participant_and_keeps_the_unknown_one_unknown() {
    let fixture = ProfileFixture::new();
    let (conversation_id, declaring, unlisted) = arrange(&fixture);
    let response = fixture.candidates(
        &conversation_id,
        json!({"requiredCapabilities": ["image-input"]}),
    );
    let receipt = &response["routeReceipt"];

    let resolved = &receipt["resolved"];
    assert_eq!(resolved["membershipId"], json!(declaring));
    assert_eq!(resolved["agentId"], json!(DECLARING_AGENT));
    // The model and the reasoning come from the resolved Profile intent.
    assert_eq!(resolved["model"], json!("intent-model-declaring"));
    assert_eq!(resolved["reasoningEffort"], json!("high"));
    assert!(resolved["reason"].as_str().is_some_and(|value| !value.is_empty()));
    assert!(resolved["origin"].as_str().is_some_and(|value| !value.is_empty()));
    assert!(receipt["refusal"].is_null());

    // The participant the owner could not answer for is named as unknown, not
    // as incapable.
    let requirement = &receipt["requirements"][0];
    assert_eq!(requirement["requirement"], json!("image-input"));
    assert_eq!(requirement["outcome"], json!("satisfied"));
    assert_eq!(
        requirement["unknownMembershipIds"],
        json!([unlisted.clone()])
    );
}

#[test]
fn an_unsatisfied_requirement_refuses_and_starts_nothing() {
    let fixture = ProfileFixture::new();
    let (conversation_id, declaring, unlisted) = arrange(&fixture);
    let events_before = fixture.event_count(&conversation_id);

    let response = fixture.candidates(
        &conversation_id,
        json!({"requiredCapabilities": ["web-server"]}),
    );
    let receipt = &response["routeReceipt"];
    assert!(receipt["resolved"].is_null());
    let refusal = &receipt["refusal"];
    assert_eq!(refusal["requirement"], json!("web-server"));
    assert_eq!(refusal["reason"], json!("profile_requirement_unsatisfied"));
    // No participant answers for a channel name its packaged declaration does
    // not list, so the refusal reports the unreadable answer rather than
    // inventing either a declaration or a definite absence.
    assert_eq!(receipt["requirements"][0]["outcome"], json!("unknown"));
    assert!(
        refusal["unknownMembershipIds"]
            .as_array()
            .unwrap()
            .contains(&json!(unlisted)),
        "the participant whose answer is unknown must be named"
    );
    assert!(
        response["candidates"].as_array().unwrap().is_empty(),
        "no participant satisfies the requirement"
    );

    // Admission selects; it never dispatches or records a turn.
    assert_eq!(fixture.event_count(&conversation_id), events_before);
    for membership_id in [&declaring, &unlisted] {
        assert!(
            fixture
                .service
                .store()
                .latest_send_dispatch(&conversation_id, membership_id)
                .unwrap()
                .is_none(),
            "admission must not start a dispatch"
        );
    }
}

#[test]
fn a_missing_fact_is_not_reported_as_an_unreadable_owner() {
    let fixture = ProfileFixture::new();
    // Two packaged participants whose owners were read. Neither ships a desktop
    // surface, so the requirement is a genuinely incapable set: missing, with
    // no participant named as unreadable.
    let (conversation_id, owner, agents) = fixture.create_group(&["claude-code", "opencode"]);
    for membership_id in &agents {
        fixture.update_intent(
            &conversation_id,
            &owner,
            membership_id,
            json!({"preferredModel": "intent-model"}),
        );
    }
    let response = fixture.candidates(
        &conversation_id,
        json!({"requiredCapabilities": ["real-interface"]}),
    );
    let requirement = &response["routeReceipt"]["requirements"][0];
    assert_eq!(requirement["requirement"], json!("real-interface"));
    assert_eq!(requirement["outcome"], json!("missing"));
    assert_eq!(requirement["unknownMembershipIds"], json!([]));
    assert_eq!(
        response["routeReceipt"]["refusal"]["outcome"],
        json!("missing")
    );
}

#[test]
fn profile_intent_survives_the_update_and_read_actions_with_its_responsibility() {
    let fixture = ProfileFixture::new();
    let (conversation_id, owner, agents) = fixture.create_group(&[DECLARING_AGENT]);
    let membership_id = agents[0].clone();
    let revision = fixture.profile_revision(&membership_id);
    let updated = fixture.update_intent(
        &conversation_id,
        &owner,
        &membership_id,
        json!({
            "requiredCapabilities": ["image-input"],
            "preferredCapabilities": ["real-interface"],
            "skillReferences": ["skill-example"],
            "preferredModel": "intent-model",
            "preferredReasoningEffort": "high",
            "preferredEnvironment": "local",
        }),
    );
    let stored = &updated["profile"];
    assert_eq!(stored["revision"], json!(revision + 1));
    assert_eq!(stored["responsibility"], json!("member"));

    let read = fixture
        .service
        .execute(json!({
            "action": "conversation.profile.get",
            "membershipId": membership_id,
        }))
        .unwrap();
    assert_eq!(read, *stored, "the stored intent must read back unchanged");
    assert_eq!(read["requiredCapabilities"], json!(["image-input"]));
    assert_eq!(read["preferredCapabilities"], json!(["real-interface"]));
    assert_eq!(read["skillReferences"], json!(["skill-example"]));
    assert_eq!(read["preferredModel"], json!("intent-model"));
    assert_eq!(read["preferredReasoningEffort"], json!("high"));
    assert_eq!(read["preferredEnvironment"], json!("local"));

    // Responsibility stays a designation of the conversation, not a value this
    // Plan widens, and the persisted schema keeps its version and constraint.
    let revision = fixture
        .service
        .store()
        .get(&conversation_id)
        .unwrap()
        .revision;
    fixture
        .service
        .execute(json!({
            "action": "conversation.assistant.set",
            "conversationId": conversation_id,
            "ownerMembershipId": owner,
            "expectedRevision": revision,
            "membershipId": membership_id,
        }))
        .unwrap();
    let read = fixture
        .service
        .execute(json!({
            "action": "conversation.profile.get",
            "membershipId": membership_id,
        }))
        .unwrap();
    assert_eq!(read["responsibility"], json!("assistant"));
    assert_eq!(read["preferredModel"], json!("intent-model"));
    // The bundled guide skill follows the responsibility designation rather
    // than the update payload, and the round-tripped intent is otherwise kept.
    assert_eq!(read["skillReferences"], json!(["licoup-guide", "skill-example"]));

    let connection = rusqlite::Connection::open(
        fixture
            .root
            .join("client-state")
            .join("conversations")
            .join("conversations.sqlite3"),
    )
    .unwrap();
    let version: String = connection
        .query_row("SELECT value FROM schema_meta WHERE key='version'", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(version, CURRENT_SCHEMA_VERSION);
    assert_eq!(CURRENT_SCHEMA_VERSION, "18");
    let schema: String = connection
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='table' AND name='membership_profiles'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        schema.contains("CHECK(responsibility IN ('assistant','member'))"),
        "the responsibility constraint must stay unchanged: {schema}"
    );
    // A widened responsibility value is not a value the store can read back.
    assert!(
        serde_json::from_value::<licoup_conversation::client_conversation::ProfileResponsibility>(
            json!("orchestrator")
        )
        .is_err()
    );
}
