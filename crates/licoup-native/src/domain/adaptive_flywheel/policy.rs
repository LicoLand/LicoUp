//! Read-only bundled authoring policies, independent of Graph execution and binding.

use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

const INSTRUCTIONS: &str =
    include_str!("../../../resources/workflow-policies/better-plan/SKILL.md");
static MODEL_PRESETS: LazyLock<ModelPresets> = LazyLock::new(|| {
    serde_json::from_str(include_str!(
        "../../../resources/workflow-policies/better-plan/model-presets.json"
    ))
    .expect("bundled Better Plan model presets are valid")
});

#[derive(Clone, Copy, Serialize)]
pub struct WorkflowPolicySummary {
    pub id: &'static str,
    pub name: &'static str,
    pub version: u32,
    pub description: &'static str,
}

const BETTER_PLAN: WorkflowPolicySummary = WorkflowPolicySummary {
    id: "better-plan",
    name: "Better Plan",
    version: 1,
    description: "Plan substantial development with a Designer, focused Workers, and an independent Reviewer; includes ordered model recommendations.",
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowPolicy {
    #[serde(flatten)]
    pub summary: WorkflowPolicySummary,
    pub instructions: &'static str,
    pub model_presets: &'static ModelPresets,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelPresets {
    pub schema_version: u32,
    pub assistant: String,
    pub candidate_use: String,
    pub roles: Vec<RolePreset>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RolePreset {
    pub role: String,
    pub candidates: Vec<ModelPreference>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelPreference {
    pub model_name: String,
    pub reasoning_effort: String,
}

/// Discovery stays small; instructions are read only when a caller selects a policy.
pub fn builtin_workflow_policies() -> [WorkflowPolicySummary; 1] {
    [BETTER_PLAN]
}

pub fn builtin_workflow_policy(id: &str) -> Option<WorkflowPolicy> {
    (id == BETTER_PLAN.id).then(|| WorkflowPolicy {
        summary: BETTER_PLAN,
        instructions: INSTRUCTIONS,
        model_presets: &MODEL_PRESETS,
    })
}
