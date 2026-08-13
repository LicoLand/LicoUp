//! Private, numeric-only Token accounting for one native delivery workflow.
//!
//! This module is deliberately separate from conversation history parsing.  A
//! history adapter supplies normalized counters and opaque identities; the
//! ledger owns only correlation, watermarks, allocation, and bounded report
//! retention.  It never reads a transcript and never stores a native location.

use super::persistence::client_state_store;
use crate::platform::client_state::ClientStateStore;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::fmt::{Display, Formatter};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

/// Current private ledger schema.  A different generation is discarded rather
/// than translated: this is private execution state, not a public migration
/// surface.
pub const WORKFLOW_LEDGER_SCHEMA_VERSION: i64 = 1;
pub const WORKFLOW_LEDGER_FILE_NAME: &str = "workflow-token-ledger-v1.sqlite3";
pub const WORKFLOW_LEDGER_REPORT_SCHEMA: &str = "licoup.workflow-token-report.v1";
pub const WORKFLOW_LEDGER_MAX_TERMINAL_REPORTS: usize = 20;

/// A typed, safe failure exposed by the internal scheduler seam.  The display
/// form intentionally contains no SQL, path, native exception, or transcript
/// data.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerError {
    pub code: String,
    pub stage: String,
    pub retryable: bool,
    pub recovery: String,
}

impl LedgerError {
    fn new(
        code: impl Into<String>,
        stage: impl Into<String>,
        retryable: bool,
        recovery: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            retryable,
            recovery: recovery.into(),
        }
    }

    fn storage() -> Self {
        Self::new(
            "usage_ledger_store_unavailable",
            "usage-ledger",
            true,
            "retry_after_store_recovers",
        )
    }

    fn invalid(code: &'static str, stage: &'static str) -> Self {
        Self::new(code, stage, false, "correct_request_and_retry")
    }
}

impl Display for LedgerError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.code)
    }
}

impl std::error::Error for LedgerError {}

pub type LedgerResult<T> = std::result::Result<T, LedgerError>;

/// Normalized numeric usage accepted by the ledger.  It is intentionally
/// independent of a provider's raw schema and contains no text fields.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedUsage {
    pub prompt_tokens: u64,
    pub cached_input_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub accuracy: String,
    #[serde(default)]
    pub event_id: String,
    #[serde(default)]
    pub lineage_scope: String,
    #[serde(default)]
    pub cumulative: bool,
}

impl NormalizedUsage {
    pub fn new(
        prompt_tokens: u64,
        cached_input_tokens: u64,
        completion_tokens: u64,
        model: impl Into<String>,
        accuracy: impl Into<String>,
        event_id: impl Into<String>,
        lineage_scope: impl Into<String>,
    ) -> Self {
        let mut usage = Self {
            prompt_tokens,
            cached_input_tokens,
            completion_tokens,
            total_tokens: prompt_tokens.saturating_add(completion_tokens),
            model: model.into(),
            accuracy: accuracy.into(),
            event_id: event_id.into(),
            lineage_scope: lineage_scope.into(),
            cumulative: false,
        };
        usage.normalize();
        usage
    }

    /// Parse the existing normalized usage projection, accepting its snake
    /// case provider aliases as well.  Unknown fields (including prompt/reply
    /// content) are ignored.
    pub fn from_value(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        let prompt_tokens = number_field(
            object,
            &[
                "promptTokens",
                "prompt_tokens",
                "inputTokens",
                "input_tokens",
            ],
        )?;
        let cached_input_tokens = number_field(
            object,
            &[
                "cachedInputTokens",
                "cached_input_tokens",
                "cacheReadInputTokens",
                "cache_read_input_tokens",
            ],
        )
        .unwrap_or(0);
        let completion_tokens = number_field(
            object,
            &[
                "completionTokens",
                "completion_tokens",
                "outputTokens",
                "output_tokens",
            ],
        )
        .unwrap_or(0);
        let total_tokens = number_field(object, &["totalTokens", "total_tokens"])
            .unwrap_or_else(|| prompt_tokens.saturating_add(completion_tokens));
        let mut usage = Self {
            prompt_tokens,
            cached_input_tokens,
            completion_tokens,
            total_tokens,
            model: text_field(
                object,
                &["model", "modelId", "model_id", "modelName", "model_name"],
            )
            .unwrap_or_default(),
            accuracy: text_field(object, &["accuracy", "usageAccuracy", "usage_accuracy"])
                .unwrap_or_else(|| "exact".to_owned()),
            event_id: text_field(
                object,
                &[
                    "eventId",
                    "event_id",
                    "opaqueEventId",
                    "opaque_event_id",
                    "usageEventId",
                    "usage_event_id",
                ],
            )
            .unwrap_or_default(),
            lineage_scope: text_field(object, &["lineageScope", "lineage_scope", "scope"])
                .unwrap_or_default(),
            cumulative: bool_field(object, &["cumulative", "isCumulative", "is_cumulative"])
                || text_field(object, &["source", "usageMode", "usage_mode"]).is_some_and(
                    |value| {
                        matches!(
                            value.to_ascii_lowercase().as_str(),
                            "cumulative" | "counter"
                        )
                    },
                ),
        };
        usage.normalize();
        Some(usage)
    }

    pub fn to_value(&self) -> Value {
        json!({
            "promptTokens": self.prompt_tokens,
            "cachedInputTokens": self.cached_input_tokens,
            "completionTokens": self.completion_tokens,
            "totalTokens": self.total_tokens,
            "model": public_label(&self.model),
            "accuracy": normalized_accuracy(&self.accuracy),
            "eventId": public_label(&self.event_id),
            "lineageScope": public_label(&self.lineage_scope),
        })
    }

    fn normalize(&mut self) {
        self.cached_input_tokens = self.cached_input_tokens.min(self.prompt_tokens);
        self.total_tokens = self.prompt_tokens.saturating_add(self.completion_tokens);
        self.accuracy = normalized_accuracy(&self.accuracy).to_owned();
        self.model = if self.model.trim().is_empty() {
            "Others".to_owned()
        } else {
            self.model.trim().to_owned()
        };
        self.event_id = self.event_id.trim().to_owned();
        self.lineage_scope = self.lineage_scope.trim().to_owned();
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum SourceKind {
    #[default]
    Delta,
    Cumulative,
}

impl SourceKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Delta => "delta",
            Self::Cumulative => "cumulative",
        }
    }
}

#[derive(Clone, Debug)]
struct DeliveryInput {
    workflow_id: String,
    plan_code: String,
    plan_revision: i64,
    manager_agent_id: String,
    manager_binding: String,
    now_ms: i64,
}

#[derive(Clone, Debug)]
struct NodeInput {
    workflow_id: String,
    node_id: String,
    parent_node_id: Option<String>,
    plan_code: String,
    plan_revision: i64,
    task_code: Option<String>,
    phase: Option<String>,
    dispatch_id: String,
    role: String,
    attempt: i64,
    agent_id: String,
    model: String,
    accuracy: String,
    conversation_binding: String,
    lineage_scope: String,
    session_mode: String,
    source_kind: SourceKind,
}

/// Start a delivery and create its main/root node.  Repeating this call with
/// the same workflow ID is idempotent and returns the existing current row.
pub fn begin_delivery(params: &Value) -> LedgerResult<Value> {
    let input = parse_delivery_input(params)?;
    let ledger = open_ledger(params)?;
    let mut connection = ledger.connection;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    transaction
        .execute(
            "INSERT INTO deliveries(
               workflow_id,plan_code,plan_revision,manager_agent_id,manager_binding,
               state,created_at_ms,updated_at_ms,terminal_at_ms,terminal_correlation
             ) VALUES(?1,?2,?3,?4,?5,'active',?6,?6,NULL,NULL)
             ON CONFLICT(workflow_id) DO NOTHING",
            params![
                input.workflow_id,
                input.plan_code,
                input.plan_revision,
                input.manager_agent_id,
                input.manager_binding,
                input.now_ms
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    let persisted =
        load_delivery(&transaction, &input.workflow_id)?.ok_or_else(LedgerError::storage)?;
    if persisted.2 != input.plan_code || persisted.3 != input.plan_revision {
        return Err(LedgerError::invalid(
            "usage_ledger_delivery_identity_mismatch",
            "usage-ledger-begin",
        ));
    }
    let root_node_id = format!("{}:root", input.workflow_id);
    transaction
        .execute(
            "INSERT INTO workflow_nodes(
               node_id,workflow_id,parent_node_id,plan_code,plan_revision,task_code,phase,
               dispatch_id,role,attempt,agent_id,model,accuracy,conversation_binding,
               lineage_scope,session_mode,source_kind,state,usage_settlement,epoch,
               baseline_bound,baseline_prompt,baseline_cached,baseline_completion,baseline_total,
               watermark_prompt,watermark_cached,watermark_completion,watermark_total,
               prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,
               terminal_correlation,created_at_ms,updated_at_ms
             ) VALUES(
               ?1,?2,NULL,?3,?4,NULL,'main',?5,'main',0,?6,'Others','exact',?7,?7,
               'resume','delta','active','pending',0,0,0,0,0,0,0,0,0,0,0,0,0,0,NULL,?8,?8
             ) ON CONFLICT(node_id) DO NOTHING",
            params![
                root_node_id,
                input.workflow_id,
                input.plan_code,
                input.plan_revision,
                input.workflow_id,
                input.manager_agent_id,
                input.manager_binding,
                input.now_ms
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "ok": true,
        "ledgerSchemaVersion": WORKFLOW_LEDGER_SCHEMA_VERSION,
        "workflowId": input.workflow_id,
        "planCode": public_label(&input.plan_code),
        "planRevision": input.plan_revision,
        "rootNodeId": root_node_id,
        "state": "active"
    }))
}

/// Bind an opaque native conversation to a workflow node and capture the
/// numeric baseline before dispatch.  A missing baseline is a typed preflight
/// failure; no dispatch should proceed after this function returns an error.
pub fn bind_conversation_baseline(params: &Value) -> LedgerResult<Value> {
    let workflow_id = required_text(
        params,
        &["workflowId", "deliveryId"],
        "workflow_id",
        "usage-ledger-baseline",
    )?;
    let mut connection = open_ledger(params)?.connection;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let delivery = load_delivery(&transaction, &workflow_id)?.ok_or_else(|| {
        LedgerError::invalid("usage_ledger_delivery_not_found", "usage-ledger-baseline")
    })?;
    if delivery.1 != "active" {
        return Err(LedgerError::invalid(
            "usage_ledger_delivery_terminal",
            "usage-ledger-baseline",
        ));
    }
    let baseline_value = params
        .get("baseline")
        .or_else(|| params.get("currentUsage"))
        .or_else(|| params.get("current_usage"));
    let Some(baseline_value) = baseline_value else {
        return Err(LedgerError::new(
            "usage_ledger_baseline_unavailable",
            "usage-ledger-baseline",
            true,
            "reconcile_native_conversation_before_dispatch",
        ));
    };
    let Some(mut baseline) = NormalizedUsage::from_value(baseline_value) else {
        return Err(LedgerError::new(
            "usage_ledger_baseline_unavailable",
            "usage-ledger-baseline",
            true,
            "reconcile_native_conversation_before_dispatch",
        ));
    };
    baseline.normalize();
    let node = parse_node_input(params, &delivery.0, &delivery.2, &delivery.3)?;
    if let Some(parent_id) = node.parent_node_id.as_deref() {
        validate_parent(&transaction, &node.workflow_id, &node.node_id, parent_id)?;
    }
    let now_ms = now_ms(params);
    let existing = load_node(&transaction, &node.node_id)?;
    if let Some(existing) = existing {
        if existing.baseline_bound {
            transaction.commit().map_err(|_| LedgerError::storage())?;
            return Ok(json!({
                "ok": true,
                "workflowId": workflow_id,
                "nodeId": existing.node_id,
                "baselineEpoch": existing.epoch,
                "baseline": usage_json(existing.baseline_prompt, existing.baseline_cached, existing.baseline_completion, existing.baseline_total),
                "idempotent": true
            }));
        }
        transaction
            .execute(
                "UPDATE workflow_nodes SET
                   plan_code=?2,plan_revision=?3,task_code=?4,phase=?5,dispatch_id=?6,
                   role=?7,attempt=?8,agent_id=?9,model=?10,accuracy=?11,
                   conversation_binding=?12,lineage_scope=?13,session_mode=?14,source_kind=?15,
                   baseline_bound=1,baseline_prompt=?16,baseline_cached=?17,
                   baseline_completion=?18,baseline_total=?19,watermark_prompt=?16,
                   watermark_cached=?17,watermark_completion=?18,watermark_total=?19,
                   usage_settlement='ready',updated_at_ms=?20
                 WHERE node_id=?1",
                params![
                    node.node_id,
                    node.plan_code,
                    node.plan_revision,
                    node.task_code,
                    node.phase,
                    node.dispatch_id,
                    node.role,
                    node.attempt,
                    node.agent_id,
                    node.model,
                    node.accuracy,
                    node.conversation_binding,
                    node.lineage_scope,
                    node.session_mode,
                    node.source_kind.as_str(),
                    i64_value(baseline.prompt_tokens),
                    i64_value(baseline.cached_input_tokens),
                    i64_value(baseline.completion_tokens),
                    i64_value(baseline.total_tokens),
                    now_ms
                ],
            )
            .map_err(|_| LedgerError::storage())?;
    } else {
        transaction
            .execute(
                "INSERT INTO workflow_nodes(
                   node_id,workflow_id,parent_node_id,plan_code,plan_revision,task_code,phase,
                   dispatch_id,role,attempt,agent_id,model,accuracy,conversation_binding,
                   lineage_scope,session_mode,source_kind,state,usage_settlement,epoch,
                   baseline_bound,baseline_prompt,baseline_cached,baseline_completion,baseline_total,
                   watermark_prompt,watermark_cached,watermark_completion,watermark_total,
                   prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,
                   terminal_correlation,created_at_ms,updated_at_ms
                 ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,
                   ?17,'active','ready',0,1,?18,?19,?20,?21,?18,?19,?20,?21,0,0,0,0,NULL,?22,?22)",
                params![
                    node.node_id,
                    node.workflow_id,
                    node.parent_node_id,
                    node.plan_code,
                    node.plan_revision,
                    node.task_code,
                    node.phase,
                    node.dispatch_id,
                    node.role,
                    node.attempt,
                    node.agent_id,
                    node.model,
                    node.accuracy,
                    node.conversation_binding,
                    node.lineage_scope,
                    node.session_mode,
                    node.source_kind.as_str(),
                    i64_value(baseline.prompt_tokens),
                    i64_value(baseline.cached_input_tokens),
                    i64_value(baseline.completion_tokens),
                    i64_value(baseline.total_tokens),
                    now_ms
                ],
            )
            .map_err(|_| LedgerError::storage())?;
    }
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "ok": true,
        "workflowId": workflow_id,
        "nodeId": node.node_id,
        "baselineEpoch": 0,
        "baseline": usage_json(i64_value(baseline.prompt_tokens), i64_value(baseline.cached_input_tokens), i64_value(baseline.completion_tokens), i64_value(baseline.total_tokens)),
        "idempotent": false
    }))
}

/// Settle one normalized usage observation or an array of observations.  Exact
/// events are allocated by opaque event identity; cumulative observations use
/// only positive post-watermark deltas and start a new epoch on reset.
pub fn settle_turn(params: &Value) -> LedgerResult<Value> {
    let workflow_id = required_text(
        params,
        &["workflowId", "deliveryId"],
        "workflow_id",
        "usage-ledger-settlement",
    )?;
    let mut connection = open_ledger(params)?.connection;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let delivery = load_delivery(&transaction, &workflow_id)?.ok_or_else(|| {
        LedgerError::invalid("usage_ledger_delivery_not_found", "usage-ledger-settlement")
    })?;
    let node_id = node_id_from_params(params, &workflow_id);
    let node = load_node(&transaction, &node_id)?.ok_or_else(|| {
        LedgerError::invalid("usage_ledger_node_not_found", "usage-ledger-settlement")
    })?;
    if node.workflow_id != workflow_id {
        return Err(LedgerError::invalid(
            "usage_ledger_node_workflow_mismatch",
            "usage-ledger-settlement",
        ));
    }
    if !node.baseline_bound {
        return Err(LedgerError::new(
            "usage_ledger_baseline_unavailable",
            "usage-ledger-settlement",
            true,
            "bind_native_conversation_baseline_before_dispatch",
        ));
    }
    if node.usage_settlement == "in_doubt" {
        let reconcile = params
            .get("reconcile")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !reconcile {
            return Err(LedgerError::new(
                "usage_ledger_settlement_in_doubt",
                "usage-ledger-settlement",
                true,
                "reconcile_same_native_conversation_before_retry",
            ));
        }
        let Some(binding) = text_param(
            params,
            &[
                "conversationBinding",
                "conversation_binding",
                "conversationId",
                "conversation_id",
            ],
        ) else {
            return Err(LedgerError::new(
                "usage_ledger_reconciliation_binding_missing",
                "usage-ledger-settlement",
                false,
                "provide_same_native_conversation_binding",
            ));
        };
        if opaque_binding(&binding) != node.conversation_binding {
            return Err(LedgerError::new(
                "usage_ledger_reconciliation_binding_mismatch",
                "usage-ledger-settlement",
                false,
                "reconcile_the_original_native_conversation",
            ));
        }
    }
    if bool_param(
        params,
        &[
            "forceSettlementFailure",
            "simulateSettlementFailure",
            "simulate_settlement_failure",
        ],
    ) {
        mark_node_in_doubt(&transaction, &node.node_id, now_ms(params))?;
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Err(LedgerError::new(
            "usage_ledger_settlement_in_doubt",
            "usage-ledger-settlement",
            true,
            "reconcile_same_native_conversation_before_retry",
        ));
    }
    let observations = observation_values(params);
    if observations.is_empty() {
        mark_node_in_doubt(&transaction, &node.node_id, now_ms(params))?;
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Err(LedgerError::invalid(
            "usage_ledger_usage_missing",
            "usage-ledger-settlement",
        ));
    }
    let mut watermark = Watermark {
        prompt: node.watermark_prompt,
        cached: node.watermark_cached,
        completion: node.watermark_completion,
        total: node.watermark_total,
    };
    let mut epoch = node.epoch;
    let mut added = UsageTotals::default();
    let mut allocated_events = 0_u64;
    let mut duplicate_events = 0_u64;
    let mut reset_count = 0_u64;
    let requested_source = text_param(params, &["source", "usageMode", "usage_mode"])
        .map(|value| value.to_ascii_lowercase());
    let default_source = if bool_param(params, &["cumulative", "isCumulative", "is_cumulative"])
        || requested_source
            .as_deref()
            .is_some_and(|value| matches!(value, "cumulative" | "counter"))
        || node.source_kind == SourceKind::Cumulative
    {
        SourceKind::Cumulative
    } else {
        SourceKind::Delta
    };
    for (index, raw) in observations.into_iter().enumerate() {
        let Some(mut usage) = NormalizedUsage::from_value(raw) else {
            mark_node_in_doubt(&transaction, &node.node_id, now_ms(params))?;
            transaction.commit().map_err(|_| LedgerError::storage())?;
            return Err(LedgerError::invalid(
                "usage_ledger_usage_invalid",
                "usage-ledger-settlement",
            ));
        };
        let source_kind = if usage.cumulative {
            SourceKind::Cumulative
        } else {
            default_source
        };
        usage.cumulative = source_kind == SourceKind::Cumulative;
        let lineage_scope = if usage.lineage_scope.is_empty() {
            if node.lineage_scope.is_empty() {
                node.conversation_binding.clone()
            } else {
                node.lineage_scope.clone()
            }
        } else {
            usage.lineage_scope.clone()
        };
        if !is_opaque_identifier(&lineage_scope) {
            return Err(LedgerError::invalid(
                "usage_ledger_lineage_scope_invalid",
                "usage-ledger-settlement",
            ));
        }
        let mut event_identity = usage.event_id.clone();
        if event_identity.is_empty() {
            event_identity =
                text_field_from_value(raw, &["turnId", "turn_id", "eventIndex", "event_index"])
                    .unwrap_or_else(|| {
                        format!("dispatch:{}:observation:{index}", node.dispatch_id)
                    });
        }
        if !is_opaque_identifier(&event_identity) {
            return Err(LedgerError::invalid(
                "usage_ledger_event_identity_invalid",
                "usage-ledger-settlement",
            ));
        }
        let totals = if source_kind == SourceKind::Cumulative {
            let current = Watermark::from_usage(&usage);
            if current.is_reset_of(watermark) {
                watermark = current;
                epoch = epoch.saturating_add(1);
                reset_count = reset_count.saturating_add(1);
                continue;
            }
            let delta = current.delta(watermark);
            watermark = current;
            if delta.is_zero() {
                continue;
            }
            event_identity = format!(
                "cumulative:{event_identity}:{}:{}:{}:{}",
                epoch, current.prompt, current.cached, current.completion
            );
            delta
        } else {
            UsageTotals::from_usage(&usage)
        };
        if totals.is_zero() {
            continue;
        }
        // Include the plan revision and lineage scope in the actual unique
        // allocation key.  An identical event in an independent conversation
        // has a different lineage scope and remains distinct; copied/forked
        // prefixes supply the same scope and collapse here.
        let inserted = match transaction.execute(
            "INSERT INTO workflow_events(
                   workflow_id,node_id,plan_code,plan_revision,event_identity,lineage_scope,
                   epoch,prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,
                   model,accuracy,source_kind,created_at_ms
                 ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
                 ON CONFLICT(plan_code,plan_revision,event_identity,lineage_scope) DO NOTHING",
            params![
                workflow_id,
                node.node_id,
                delivery.2,
                delivery.3,
                event_identity,
                lineage_scope,
                epoch,
                totals.prompt,
                totals.cached,
                totals.completion,
                totals.total,
                usage.model,
                normalized_accuracy(&usage.accuracy),
                source_kind.as_str(),
                now_ms(params)
            ],
        ) {
            Ok(inserted) => inserted,
            Err(_) => {
                mark_node_in_doubt(&transaction, &node.node_id, now_ms(params))?;
                transaction.commit().map_err(|_| LedgerError::storage())?;
                return Err(LedgerError::new(
                    "usage_ledger_settlement_in_doubt",
                    "usage-ledger-settlement",
                    true,
                    "reconcile_same_native_conversation_before_retry",
                ));
            }
        };
        if inserted == 0 {
            duplicate_events = duplicate_events.saturating_add(1);
            continue;
        }
        allocated_events = allocated_events.saturating_add(1);
        added.add(totals);
        if transaction
            .execute(
                "UPDATE workflow_nodes SET
                   prompt_tokens=prompt_tokens+?2,cached_input_tokens=cached_input_tokens+?3,
                   completion_tokens=completion_tokens+?4,total_tokens=total_tokens+?5,
                   model=?6,accuracy=?7,usage_settlement='settled',updated_at_ms=?8,
                   watermark_prompt=?9,watermark_cached=?10,watermark_completion=?11,
                   watermark_total=?12,epoch=?13
                 WHERE node_id=?1",
                params![
                    node.node_id,
                    totals.prompt,
                    totals.cached,
                    totals.completion,
                    totals.total,
                    usage.model,
                    normalized_accuracy(&usage.accuracy),
                    now_ms(params),
                    watermark.prompt,
                    watermark.cached,
                    watermark.completion,
                    watermark.total,
                    epoch
                ],
            )
            .is_err()
        {
            mark_node_in_doubt(&transaction, &node.node_id, now_ms(params))?;
            transaction.commit().map_err(|_| LedgerError::storage())?;
            return Err(LedgerError::new(
                "usage_ledger_settlement_in_doubt",
                "usage-ledger-settlement",
                true,
                "reconcile_same_native_conversation_before_retry",
            ));
        }
    }
    transaction
        .execute(
            "UPDATE workflow_nodes SET
               watermark_prompt=?2,watermark_cached=?3,watermark_completion=?4,
               watermark_total=?5,epoch=?6,usage_settlement='settled',updated_at_ms=?7
             WHERE node_id=?1",
            params![
                node.node_id,
                watermark.prompt,
                watermark.cached,
                watermark.completion,
                watermark.total,
                epoch,
                now_ms(params)
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    // The event table is the allocation authority. Rebuilding the bounded
    // node rollup here also repairs an earlier in-doubt attempt in which the
    // unique event row committed before its cached node counters were updated.
    transaction
        .execute(
            "UPDATE workflow_nodes SET
               prompt_tokens=COALESCE((SELECT SUM(prompt_tokens) FROM workflow_events WHERE node_id=?1),0),
               cached_input_tokens=COALESCE((SELECT SUM(cached_input_tokens) FROM workflow_events WHERE node_id=?1),0),
               completion_tokens=COALESCE((SELECT SUM(completion_tokens) FROM workflow_events WHERE node_id=?1),0),
               total_tokens=COALESCE((SELECT SUM(total_tokens) FROM workflow_events WHERE node_id=?1),0),
               usage_settlement='settled',updated_at_ms=?2
             WHERE node_id=?1 AND workflow_id=?3",
            params![node.node_id, now_ms(params), workflow_id],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "ok": true,
        "workflowId": workflow_id,
        "nodeId": node.node_id,
        "allocatedEvents": allocated_events,
        "duplicateEvents": duplicate_events,
        "resetCount": reset_count,
        "usage": added.to_value(),
        "settlementState": "settled"
    }))
}

/// Mark a node or complete workflow terminal.  A terminal snapshot is stored
/// as a numeric rollup before older event detail is compacted.
pub fn mark_terminal(params: &Value) -> LedgerResult<Value> {
    let workflow_id = required_text(
        params,
        &["workflowId", "deliveryId"],
        "workflow_id",
        "usage-ledger-terminal",
    )?;
    let state = text_param(params, &["state", "terminalState", "terminal_state"])
        .unwrap_or_else(|| "completed".to_owned());
    let state = match state.to_ascii_lowercase().as_str() {
        "completed" | "complete" | "succeeded" | "success" => "completed",
        "failed" | "error" => "failed",
        "cancelled" | "canceled" | "cancel-requested" => "cancelled",
        _ => {
            return Err(LedgerError::invalid(
                "usage_ledger_terminal_state_invalid",
                "usage-ledger-terminal",
            ));
        }
    };
    let correlation = text_param(
        params,
        &["terminalCorrelation", "terminal_correlation", "correlation"],
    )
    .unwrap_or_else(|| format!("terminal:{workflow_id}"));
    let mut connection = open_ledger(params)?.connection;
    let transaction = connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let delivery = load_delivery(&transaction, &workflow_id)?.ok_or_else(|| {
        LedgerError::invalid("usage_ledger_delivery_not_found", "usage-ledger-terminal")
    })?;
    let now = now_ms(params);
    let node_filter = params.get("nodeId").and_then(Value::as_str);
    if let Some(node_id) = node_filter {
        let node = load_node(&transaction, node_id)?.ok_or_else(|| {
            LedgerError::invalid("usage_ledger_node_not_found", "usage-ledger-terminal")
        })?;
        if node.workflow_id != workflow_id {
            return Err(LedgerError::invalid(
                "usage_ledger_node_workflow_mismatch",
                "usage-ledger-terminal",
            ));
        }
        transaction
            .execute(
                "UPDATE workflow_nodes SET state=?2,terminal_correlation=?3,updated_at_ms=?4 WHERE node_id=?1 AND workflow_id=?5",
                params![node_id, state, public_label(&correlation), now, workflow_id],
            )
            .map_err(|_| LedgerError::storage())?;
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(json!({
            "ok": true,
            "workflowId": workflow_id,
            "nodeId": public_label(node_id),
            "state": state,
            "terminalCorrelation": public_label(&correlation)
        }));
    }
    if delivery.1 != "active" {
        transaction.commit().map_err(|_| LedgerError::storage())?;
        return Ok(json!({
            "ok": true,
            "workflowId": workflow_id,
            "state": delivery.1,
            "terminalCorrelation": public_label(&correlation),
            "retainedTerminalReports": terminal_report_count(params)?,
            "idempotent": true
        }));
    }
    transaction
        .execute(
            "UPDATE deliveries SET state=?2,updated_at_ms=?3,terminal_at_ms=?3,terminal_correlation=?4 WHERE workflow_id=?1",
            params![workflow_id, state, now, public_label(&correlation)],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction
        .execute(
            "UPDATE workflow_nodes SET state=?2,terminal_correlation=?3,updated_at_ms=?4 WHERE workflow_id=?1",
            params![workflow_id, state, public_label(&correlation), now],
        )
        .map_err(|_| LedgerError::storage())?;
    let final_report = build_active_report(
        &transaction,
        &workflow_id,
        &delivery.2,
        delivery.3,
        state,
        Some(&public_label(&correlation)),
    )?;
    let report_json = serde_json::to_string(&final_report).map_err(|_| LedgerError::storage())?;
    transaction
        .execute(
            "INSERT INTO workflow_rollups(workflow_id,plan_code,plan_revision,terminal_at_ms,report_json)
             VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(workflow_id) DO UPDATE SET terminal_at_ms=excluded.terminal_at_ms,report_json=excluded.report_json",
            params![workflow_id, delivery.2, delivery.3, now, report_json],
        )
        .map_err(|_| LedgerError::storage())?;

    // Terminal state, immutable rollup, detail removal, and retention advance
    // together. A crash cannot leave a terminal delivery without its report.
    transaction
        .execute(
            "DELETE FROM workflow_events WHERE workflow_id IN(SELECT workflow_id FROM workflow_rollups)",
            [],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction
        .execute(
            "DELETE FROM workflow_nodes WHERE workflow_id IN(SELECT workflow_id FROM workflow_rollups)",
            [],
        )
        .map_err(|_| LedgerError::storage())?;
    let mut stale = Vec::<String>::new();
    {
        let mut statement = transaction
            .prepare(
                "SELECT workflow_id FROM workflow_rollups
                 ORDER BY terminal_at_ms DESC,workflow_id DESC LIMIT -1 OFFSET ?1",
            )
            .map_err(|_| LedgerError::storage())?;
        let rows = statement
            .query_map([WORKFLOW_LEDGER_MAX_TERMINAL_REPORTS as i64], |row| {
                row.get::<_, String>(0)
            })
            .map_err(|_| LedgerError::storage())?;
        for row in rows {
            stale.push(row.map_err(|_| LedgerError::storage())?);
        }
    }
    for stale_workflow_id in stale {
        transaction
            .execute(
                "DELETE FROM workflow_rollups WHERE workflow_id=?1",
                [&stale_workflow_id],
            )
            .map_err(|_| LedgerError::storage())?;
        transaction
            .execute(
                "DELETE FROM deliveries WHERE workflow_id=?1",
                [&stale_workflow_id],
            )
            .map_err(|_| LedgerError::storage())?;
    }
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "ok": true,
        "workflowId": workflow_id,
        "state": state,
        "terminalCorrelation": public_label(&correlation),
        "retainedTerminalReports": terminal_report_count(params)?
    }))
}

/// Return active workflows plus the newest twenty terminal numeric reports.
/// The projection is intentionally path-free and contains no event-detail
/// payloads after terminal compaction.
pub fn workflow_report(params: &Value) -> LedgerResult<Value> {
    let ledger = open_ledger(params)?;
    let connection = ledger.connection;
    let mut workflows = Vec::<Value>::new();
    let requested_workflow_id =
        text_param(params, &["workflowId", "deliveryId"]).unwrap_or_default();
    let mut statement = connection
        .prepare(
            "SELECT workflow_id,plan_code,plan_revision,state,terminal_correlation
             FROM deliveries
             WHERE state='active'
                OR workflow_id IN(
                  SELECT workflow_id FROM workflow_rollups
                  ORDER BY terminal_at_ms DESC LIMIT ?1
                )
                OR workflow_id=?2
             ORDER BY CASE WHEN state='active' THEN 0 ELSE 1 END,updated_at_ms DESC",
        )
        .map_err(|_| LedgerError::storage())?;
    let rows = statement
        .query_map(
            params![
                WORKFLOW_LEDGER_MAX_TERMINAL_REPORTS as i64,
                requested_workflow_id
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .map_err(|_| LedgerError::storage())?;
    for row in rows {
        let (workflow_id, plan_code, plan_revision, state, terminal_correlation) =
            row.map_err(|_| LedgerError::storage())?;
        if state != "active"
            && let Some(rollup) = connection
                .query_row(
                    "SELECT report_json FROM workflow_rollups WHERE workflow_id=?1",
                    [&workflow_id],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|_| LedgerError::storage())?
        {
            if let Ok(value) = serde_json::from_str::<Value>(&rollup) {
                workflows.push(value);
                continue;
            }
        }
        workflows.push(build_active_report(
            &connection,
            &workflow_id,
            &plan_code,
            plan_revision,
            &state,
            terminal_correlation.as_deref(),
        )?);
    }
    let summary = workflows
        .iter()
        .fold(UsageTotals::default(), |mut totals, workflow| {
            if let Some(usage) = workflow.get("totals").and_then(UsageTotals::from_value) {
                totals.add(usage);
            }
            totals
        });
    Ok(json!({
        "ok": true,
        "schemaVersion": WORKFLOW_LEDGER_REPORT_SCHEMA,
        "ledgerSchemaVersion": WORKFLOW_LEDGER_SCHEMA_VERSION,
        "resultKind": "workflow-token-usage",
        "summary": summary.to_value(),
        "workflows": workflows
    }))
}

/// Expose the ledger path for local tests and the native scheduler.  The path
/// itself is never emitted by a report.
pub fn ledger_path(params: &Value) -> LedgerResult<PathBuf> {
    Ok(open_ledger(params)?.path)
}

struct OpenLedger {
    connection: Connection,
    path: PathBuf,
}

fn open_ledger(params: &Value) -> LedgerResult<OpenLedger> {
    let store = client_state_store(params).map_err(|_| LedgerError::storage())?;
    open_ledger_at(store)
}

fn open_ledger_at(store: ClientStateStore) -> LedgerResult<OpenLedger> {
    let path = store.root().join(WORKFLOW_LEDGER_FILE_NAME);
    let mut connection = Connection::open(&path).map_err(|_| LedgerError::storage())?;
    connection
        .busy_timeout(Duration::from_secs(2))
        .map_err(|_| LedgerError::storage())?;
    connection
        .pragma_update(None, "foreign_keys", "ON")
        .map_err(|_| LedgerError::storage())?;
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .map_err(|_| LedgerError::storage())?;
    connection
        .pragma_update(None, "synchronous", "NORMAL")
        .map_err(|_| LedgerError::storage())?;
    let version = connection
        .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
        .map_err(|_| LedgerError::storage())?;
    if version != WORKFLOW_LEDGER_SCHEMA_VERSION {
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|_| LedgerError::storage())?;
        transaction
            .execute_batch(
                "DROP TABLE IF EXISTS workflow_events;
                 DROP TABLE IF EXISTS workflow_nodes;
                 DROP TABLE IF EXISTS workflow_rollups;
                 DROP TABLE IF EXISTS deliveries;
                 CREATE TABLE deliveries(
                   workflow_id TEXT PRIMARY KEY,
                   plan_code TEXT NOT NULL,
                   plan_revision INTEGER NOT NULL,
                   manager_agent_id TEXT NOT NULL,
                   manager_binding TEXT NOT NULL,
                   state TEXT NOT NULL,
                   created_at_ms INTEGER NOT NULL,
                   updated_at_ms INTEGER NOT NULL,
                   terminal_at_ms INTEGER,
                   terminal_correlation TEXT
                 );
                 CREATE INDEX deliveries_state_time
                   ON deliveries(state,terminal_at_ms,updated_at_ms);
                 CREATE TABLE workflow_nodes(
                   node_id TEXT PRIMARY KEY,
                   workflow_id TEXT NOT NULL,
                   parent_node_id TEXT,
                   plan_code TEXT NOT NULL,
                   plan_revision INTEGER NOT NULL,
                   task_code TEXT,
                   phase TEXT,
                   dispatch_id TEXT NOT NULL,
                   role TEXT NOT NULL,
                   attempt INTEGER NOT NULL,
                   agent_id TEXT NOT NULL,
                   model TEXT NOT NULL,
                   accuracy TEXT NOT NULL,
                   conversation_binding TEXT NOT NULL,
                   lineage_scope TEXT NOT NULL,
                   session_mode TEXT NOT NULL,
                   source_kind TEXT NOT NULL,
                   state TEXT NOT NULL,
                   usage_settlement TEXT NOT NULL,
                   epoch INTEGER NOT NULL,
                   baseline_bound INTEGER NOT NULL,
                   baseline_prompt INTEGER NOT NULL,
                   baseline_cached INTEGER NOT NULL,
                   baseline_completion INTEGER NOT NULL,
                   baseline_total INTEGER NOT NULL,
                   watermark_prompt INTEGER NOT NULL,
                   watermark_cached INTEGER NOT NULL,
                   watermark_completion INTEGER NOT NULL,
                   watermark_total INTEGER NOT NULL,
                   prompt_tokens INTEGER NOT NULL,
                   cached_input_tokens INTEGER NOT NULL,
                   completion_tokens INTEGER NOT NULL,
                   total_tokens INTEGER NOT NULL,
                   terminal_correlation TEXT,
                   created_at_ms INTEGER NOT NULL,
                   updated_at_ms INTEGER NOT NULL,
                   FOREIGN KEY(workflow_id) REFERENCES deliveries(workflow_id)
                 );
                 CREATE INDEX workflow_nodes_workflow
                   ON workflow_nodes(workflow_id,parent_node_id);
                 CREATE INDEX workflow_nodes_dispatch
                   ON workflow_nodes(workflow_id,dispatch_id,attempt);
                 CREATE TABLE workflow_events(
                   event_row_id INTEGER PRIMARY KEY,
                   workflow_id TEXT NOT NULL,
                   node_id TEXT NOT NULL,
                   plan_code TEXT NOT NULL,
                   plan_revision INTEGER NOT NULL,
                   event_identity TEXT NOT NULL,
                   lineage_scope TEXT NOT NULL,
                   epoch INTEGER NOT NULL,
                   prompt_tokens INTEGER NOT NULL,
                   cached_input_tokens INTEGER NOT NULL,
                   completion_tokens INTEGER NOT NULL,
                   total_tokens INTEGER NOT NULL,
                   model TEXT NOT NULL,
                   accuracy TEXT NOT NULL,
                   source_kind TEXT NOT NULL,
                   created_at_ms INTEGER NOT NULL,
                   UNIQUE(plan_code,plan_revision,event_identity,lineage_scope),
                   FOREIGN KEY(workflow_id) REFERENCES deliveries(workflow_id),
                   FOREIGN KEY(node_id) REFERENCES workflow_nodes(node_id)
                 );
                 CREATE INDEX workflow_events_workflow_node
                   ON workflow_events(workflow_id,node_id);
                 CREATE INDEX workflow_events_plan_task
                   ON workflow_events(plan_code,plan_revision,lineage_scope);
                 CREATE TABLE workflow_rollups(
                   workflow_id TEXT PRIMARY KEY,
                   plan_code TEXT NOT NULL,
                   plan_revision INTEGER NOT NULL,
                   terminal_at_ms INTEGER NOT NULL,
                   report_json TEXT NOT NULL,
                   FOREIGN KEY(workflow_id) REFERENCES deliveries(workflow_id)
                 );
                 PRAGMA user_version=1;",
            )
            .map_err(|_| LedgerError::storage())?;
        transaction.commit().map_err(|_| LedgerError::storage())?;
    }
    harden_sqlite_file(&path)?;
    Ok(OpenLedger { connection, path })
}

fn harden_sqlite_file(path: &Path) -> LedgerResult<()> {
    #[cfg(unix)]
    {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|_| LedgerError::storage())?;
        for suffix in ["-wal", "-shm"] {
            let sidecar = PathBuf::from(format!("{}{}", path.display(), suffix));
            if sidecar.exists() {
                fs::set_permissions(sidecar, fs::Permissions::from_mode(0o600))
                    .map_err(|_| LedgerError::storage())?;
            }
        }
    }
    Ok(())
}

fn parse_delivery_input(params: &Value) -> LedgerResult<DeliveryInput> {
    let workflow_id = required_text(
        params,
        &["workflowId", "deliveryId", "id"],
        "workflow_id",
        "usage-ledger-begin",
    )?;
    let plan_code = required_text(
        params,
        &["planCode", "plan", "plan_id"],
        "plan_code",
        "usage-ledger-begin",
    )?;
    let plan_revision = number_param(params, &["planRevision", "revision"]).ok_or_else(|| {
        LedgerError::invalid("usage_ledger_plan_revision_missing", "usage-ledger-begin")
    })?;
    let manager_agent_id = text_param(
        params,
        &["managerAgentId", "manager_agent_id", "agentId", "agent_id"],
    )
    .unwrap_or_else(|| "main".to_owned());
    let manager_binding = text_param(
        params,
        &[
            "managerConversationBinding",
            "manager_binding",
            "conversationBinding",
            "conversation_binding",
        ],
    )
    .unwrap_or_else(|| format!("manager:{workflow_id}"));
    let workflow_id = require_opaque_identifier(
        &workflow_id,
        "usage_ledger_workflow_id_invalid",
        "usage-ledger-begin",
    )?;
    let plan_code = require_opaque_identifier(
        &plan_code,
        "usage_ledger_plan_code_invalid",
        "usage-ledger-begin",
    )?;
    let manager_agent_id = require_opaque_identifier(
        &manager_agent_id,
        "usage_ledger_agent_id_invalid",
        "usage-ledger-begin",
    )?;
    let manager_binding = require_opaque_identifier(
        &manager_binding,
        "usage_ledger_conversation_binding_invalid",
        "usage-ledger-begin",
    )?;
    Ok(DeliveryInput {
        workflow_id,
        plan_code,
        plan_revision,
        manager_agent_id,
        manager_binding,
        now_ms: now_ms(params),
    })
}

fn parse_node_input(
    params: &Value,
    workflow_id: &str,
    plan_code: &str,
    plan_revision: &i64,
) -> LedgerResult<NodeInput> {
    let conversation_binding = text_param(
        params,
        &[
            "conversationBinding",
            "conversation_binding",
            "conversationId",
            "conversation_id",
        ],
    )
    .ok_or_else(|| {
        LedgerError::new(
            "usage_ledger_conversation_binding_missing",
            "usage-ledger-baseline",
            false,
            "bind_opaque_native_conversation_and_retry",
        )
    })?;
    let node_id = text_param(params, &["nodeId", "node_id"])
        .unwrap_or_else(|| format!("{}:conversation:{}", workflow_id, conversation_binding));
    let lineage_scope = text_param(params, &["lineageScope", "lineage_scope", "scope"])
        .unwrap_or_else(|| conversation_binding.clone());
    let node_id = require_opaque_identifier(
        &node_id,
        "usage_ledger_node_id_invalid",
        "usage-ledger-baseline",
    )?;
    let conversation_binding = require_opaque_identifier(
        &conversation_binding,
        "usage_ledger_conversation_binding_invalid",
        "usage-ledger-baseline",
    )?;
    let lineage_scope = require_opaque_identifier(
        &lineage_scope,
        "usage_ledger_lineage_scope_invalid",
        "usage-ledger-baseline",
    )?;
    let dispatch_id = public_label(
        &text_param(params, &["dispatchId", "dispatch_id"])
            .unwrap_or_else(|| format!("dispatch:{node_id}")),
    );
    Ok(NodeInput {
        workflow_id: workflow_id.to_owned(),
        node_id,
        parent_node_id: text_param(params, &["parentNodeId", "parent_node_id", "parent"])
            .map(|value| {
                require_opaque_identifier(
                    &value,
                    "usage_ledger_parent_node_id_invalid",
                    "usage-ledger-baseline",
                )
            })
            .transpose()?,
        plan_code: public_label(plan_code),
        plan_revision: *plan_revision,
        task_code: text_param(
            params,
            &["taskCode", "task_code", "taskOrPhase", "task_or_phase"],
        )
        .map(|value| public_label(&value)),
        phase: text_param(params, &["phase", "phaseCode", "phase_code"])
            .map(|value| public_label(&value)),
        dispatch_id,
        role: public_label(&text_param(params, &["role"]).unwrap_or_else(|| "worker".to_owned())),
        attempt: number_param(params, &["attempt", "attemptNumber", "attempt_number"]).unwrap_or(1),
        agent_id: public_label(
            &text_param(params, &["agentId", "agent_id"]).unwrap_or_else(|| "unknown".to_owned()),
        ),
        model: public_label(
            &text_param(params, &["model", "modelId", "model_id"])
                .unwrap_or_else(|| "Others".to_owned()),
        ),
        accuracy: normalized_accuracy(
            &text_param(params, &["accuracy", "usageAccuracy", "usage_accuracy"])
                .unwrap_or_else(|| "exact".to_owned()),
        )
        .to_owned(),
        conversation_binding,
        lineage_scope,
        session_mode: text_param(params, &["sessionMode", "session_mode"])
            .map(|value| public_label(&value))
            .unwrap_or_else(|| "new".to_owned()),
        source_kind: if bool_param(params, &["cumulative", "isCumulative", "is_cumulative"]) {
            SourceKind::Cumulative
        } else {
            match text_param(params, &["source", "usageMode", "usage_mode"])
                .as_deref()
                .map(str::to_ascii_lowercase)
                .as_deref()
            {
                Some("cumulative") | Some("counter") => SourceKind::Cumulative,
                _ => SourceKind::Delta,
            }
        },
    })
}

#[allow(dead_code)]
#[derive(Clone, Debug, Default)]
struct ExistingNode {
    node_id: String,
    workflow_id: String,
    parent_node_id: Option<String>,
    plan_code: String,
    plan_revision: i64,
    task_code: Option<String>,
    phase: Option<String>,
    dispatch_id: String,
    role: String,
    attempt: i64,
    agent_id: String,
    model: String,
    accuracy: String,
    conversation_binding: String,
    lineage_scope: String,
    session_mode: String,
    source_kind: SourceKind,
    state: String,
    usage_settlement: String,
    epoch: i64,
    baseline_bound: bool,
    baseline_prompt: i64,
    baseline_cached: i64,
    baseline_completion: i64,
    baseline_total: i64,
    watermark_prompt: i64,
    watermark_cached: i64,
    watermark_completion: i64,
    watermark_total: i64,
    prompt_tokens: i64,
    cached_input_tokens: i64,
    completion_tokens: i64,
    total_tokens: i64,
    terminal_correlation: Option<String>,
}

fn load_delivery(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: &str,
) -> LedgerResult<Option<(String, String, String, i64)>> {
    transaction
        .query_row(
            "SELECT workflow_id,state,plan_code,plan_revision FROM deliveries WHERE workflow_id=?1",
            [workflow_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|_| LedgerError::storage())
}

fn load_node(
    transaction: &rusqlite::Transaction<'_>,
    node_id: &str,
) -> LedgerResult<Option<ExistingNode>> {
    transaction
        .query_row(
            "SELECT node_id,workflow_id,parent_node_id,plan_code,plan_revision,task_code,phase,
                    dispatch_id,role,attempt,agent_id,model,accuracy,conversation_binding,
                    lineage_scope,session_mode,source_kind,state,usage_settlement,epoch,
                    baseline_bound,baseline_prompt,baseline_cached,baseline_completion,baseline_total,
                    watermark_prompt,watermark_cached,watermark_completion,watermark_total,
                    prompt_tokens,cached_input_tokens,completion_tokens,total_tokens,terminal_correlation
             FROM workflow_nodes WHERE node_id=?1",
            [node_id],
            |row| {
                let source: String = row.get(16)?;
                Ok(ExistingNode {
                    node_id: row.get(0)?,
                    workflow_id: row.get(1)?,
                    parent_node_id: row.get(2)?,
                    plan_code: row.get(3)?,
                    plan_revision: row.get(4)?,
                    task_code: row.get(5)?,
                    phase: row.get(6)?,
                    dispatch_id: row.get(7)?,
                    role: row.get(8)?,
                    attempt: row.get(9)?,
                    agent_id: row.get(10)?,
                    model: row.get(11)?,
                    accuracy: row.get(12)?,
                    conversation_binding: row.get(13)?,
                    lineage_scope: row.get(14)?,
                    session_mode: row.get(15)?,
                    source_kind: if source == "cumulative" { SourceKind::Cumulative } else { SourceKind::Delta },
                    state: row.get(17)?,
                    usage_settlement: row.get(18)?,
                    epoch: row.get(19)?,
                    baseline_bound: row.get::<_, i64>(20)? != 0,
                    baseline_prompt: row.get(21)?,
                    baseline_cached: row.get(22)?,
                    baseline_completion: row.get(23)?,
                    baseline_total: row.get(24)?,
                    watermark_prompt: row.get(25)?,
                    watermark_cached: row.get(26)?,
                    watermark_completion: row.get(27)?,
                    watermark_total: row.get(28)?,
                    prompt_tokens: row.get(29)?,
                    cached_input_tokens: row.get(30)?,
                    completion_tokens: row.get(31)?,
                    total_tokens: row.get(32)?,
                    terminal_correlation: row.get(33)?,
                })
            },
        )
        .optional()
        .map_err(|_| LedgerError::storage())
}

fn mark_node_in_doubt(
    transaction: &rusqlite::Transaction<'_>,
    node_id: &str,
    now_ms: i64,
) -> LedgerResult<()> {
    transaction
        .execute(
            "UPDATE workflow_nodes SET usage_settlement='in_doubt',updated_at_ms=?2 WHERE node_id=?1",
            params![node_id, now_ms],
        )
        .map(|_| ())
        .map_err(|_| LedgerError::storage())
}

fn build_active_report(
    connection: &Connection,
    workflow_id: &str,
    plan_code: &str,
    plan_revision: i64,
    state: &str,
    terminal_correlation: Option<&str>,
) -> LedgerResult<Value> {
    let mut nodes = Vec::<NodeReport>::new();
    let mut statement = connection
        .prepare(
            "SELECT node_id,parent_node_id,plan_code,plan_revision,task_code,phase,dispatch_id,role,attempt,agent_id,
                    model,accuracy,session_mode,state,usage_settlement,prompt_tokens,
                    cached_input_tokens,completion_tokens,total_tokens,terminal_correlation
             FROM workflow_nodes WHERE workflow_id=?1 ORDER BY CASE WHEN parent_node_id IS NULL THEN 0 ELSE 1 END,node_id",
        )
        .map_err(|_| LedgerError::storage())?;
    let rows = statement
        .query_map([workflow_id], |row| {
            Ok(NodeReport {
                node_id: row.get(0)?,
                parent_node_id: row.get(1)?,
                plan_code: row.get(2)?,
                plan_revision: row.get(3)?,
                task_code: row.get(4)?,
                phase: row.get(5)?,
                dispatch_id: row.get(6)?,
                role: row.get(7)?,
                attempt: row.get(8)?,
                agent_id: row.get(9)?,
                model: row.get(10)?,
                accuracy: row.get(11)?,
                session_mode: row.get(12)?,
                state: row.get(13)?,
                usage_settlement: row.get(14)?,
                usage: UsageTotals {
                    prompt: row.get(15)?,
                    cached: row.get(16)?,
                    completion: row.get(17)?,
                    total: row.get(18)?,
                },
                terminal_correlation: row.get(19)?,
            })
        })
        .map_err(|_| LedgerError::storage())?;
    for row in rows {
        nodes.push(row.map_err(|_| LedgerError::storage())?);
    }
    // Every workflow node contributes once; parent/child usage is not nested
    // into the parent's counters.
    let totals =
        nodes
            .iter()
            .skip_while(|_| false)
            .fold(UsageTotals::default(), |mut totals, node| {
                totals.add(node.usage);
                totals
            });
    let roots = nodes
        .iter()
        .filter(|node| node.parent_node_id.is_none())
        .map(|node| node.to_value(&nodes))
        .collect::<Vec<_>>();
    Ok(json!({
        "workflowId": public_label(workflow_id),
        "planCode": public_label(plan_code),
        "planRevision": plan_revision,
        "state": state,
        "terminalCorrelation": terminal_correlation.map(public_label),
        "totals": totals.to_value(),
        "roots": roots,
        "nodes": nodes.iter().map(|node| node.to_value(&nodes)).collect::<Vec<_>>()
    }))
}

#[derive(Clone, Debug)]
struct NodeReport {
    node_id: String,
    parent_node_id: Option<String>,
    plan_code: String,
    plan_revision: i64,
    task_code: Option<String>,
    phase: Option<String>,
    dispatch_id: String,
    role: String,
    attempt: i64,
    agent_id: String,
    model: String,
    accuracy: String,
    session_mode: String,
    state: String,
    usage_settlement: String,
    usage: UsageTotals,
    terminal_correlation: Option<String>,
}

impl NodeReport {
    fn to_value(&self, all: &[NodeReport]) -> Value {
        let children = all
            .iter()
            .filter(|child| child.parent_node_id.as_deref() == Some(self.node_id.as_str()))
            .map(|child| child.to_value(all))
            .collect::<Vec<_>>();
        json!({
            "nodeId": public_label(&self.node_id),
            "parentNodeId": self.parent_node_id.as_deref().map(public_label),
            "planCode": public_label(&self.plan_code),
            "planRevision": self.plan_revision,
            "taskCode": self.task_code.as_deref().map(public_label),
            "phase": self.phase.as_deref().map(public_label),
            "dispatchId": public_label(&self.dispatch_id),
            "role": public_label(&self.role),
            "attempt": self.attempt,
            "agentId": public_label(&self.agent_id),
            "model": public_label(&self.model),
            "accuracy": normalized_accuracy(&self.accuracy),
            "sessionMode": public_label(&self.session_mode),
            "state": public_label(&self.state),
            "usageSettlement": public_label(&self.usage_settlement),
            "usage": self.usage.to_value(),
            "terminalCorrelation": self.terminal_correlation.as_deref().map(public_label),
            "children": children
        })
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct UsageTotals {
    prompt: i64,
    cached: i64,
    completion: i64,
    total: i64,
}

impl UsageTotals {
    fn from_usage(usage: &NormalizedUsage) -> Self {
        Self {
            prompt: i64_value(usage.prompt_tokens),
            cached: i64_value(usage.cached_input_tokens.min(usage.prompt_tokens)),
            completion: i64_value(usage.completion_tokens),
            total: i64_value(usage.total_tokens),
        }
    }

    fn from_value(value: &Value) -> Option<Self> {
        Some(Self {
            prompt: number_field(value.as_object()?, &["promptTokens", "prompt_tokens"])? as i64,
            cached: number_field(
                value.as_object()?,
                &["cachedInputTokens", "cached_input_tokens"],
            )
            .unwrap_or(0) as i64,
            completion: number_field(
                value.as_object()?,
                &["completionTokens", "completion_tokens"],
            )
            .unwrap_or(0) as i64,
            total: number_field(value.as_object()?, &["totalTokens", "total_tokens"]).unwrap_or(0)
                as i64,
        })
    }

    fn add(&mut self, other: Self) {
        self.prompt = self.prompt.saturating_add(other.prompt);
        self.cached = self.cached.saturating_add(other.cached).min(self.prompt);
        self.completion = self.completion.saturating_add(other.completion);
        self.total = self.prompt.saturating_add(self.completion);
    }

    fn is_zero(self) -> bool {
        self.prompt == 0 && self.cached == 0 && self.completion == 0
    }

    fn to_value(self) -> Value {
        json!({
            "promptTokens": self.prompt.max(0),
            "cachedInputTokens": self.cached.max(0).min(self.prompt.max(0)),
            "completionTokens": self.completion.max(0),
            "totalTokens": self.prompt.max(0).saturating_add(self.completion.max(0)),
        })
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Watermark {
    prompt: i64,
    cached: i64,
    completion: i64,
    total: i64,
}

impl Watermark {
    fn from_usage(usage: &NormalizedUsage) -> Self {
        let totals = UsageTotals::from_usage(usage);
        Self {
            prompt: totals.prompt,
            cached: totals.cached,
            completion: totals.completion,
            total: totals.total,
        }
    }

    fn is_reset_of(self, previous: Self) -> bool {
        self.prompt < previous.prompt
            || self.cached < previous.cached
            || self.completion < previous.completion
            || self.total < previous.total
    }

    fn delta(self, previous: Self) -> UsageTotals {
        UsageTotals {
            prompt: self.prompt.saturating_sub(previous.prompt),
            cached: self.cached.saturating_sub(previous.cached),
            completion: self.completion.saturating_sub(previous.completion),
            total: self.total.saturating_sub(previous.total),
        }
    }
}

fn observation_values(params: &Value) -> Vec<&Value> {
    if let Some(values) = params.get("events").and_then(Value::as_array) {
        return values.iter().collect();
    }
    for key in ["usage", "observation", "currentUsage", "current_usage"] {
        if let Some(value) = params.get(key) {
            return vec![value];
        }
    }
    if params.get("promptTokens").is_some() || params.get("prompt_tokens").is_some() {
        return vec![params];
    }
    Vec::new()
}

fn terminal_report_count(params: &Value) -> LedgerResult<u64> {
    let connection = open_ledger(params)?.connection;
    connection
        .query_row("SELECT COUNT(*) FROM workflow_rollups", [], |row| {
            row.get::<_, i64>(0)
        })
        .map(|count| count.max(0) as u64)
        .map_err(|_| LedgerError::storage())
}

fn required_text(
    value: &Value,
    keys: &[&str],
    code_name: &'static str,
    stage: &'static str,
) -> LedgerResult<String> {
    text_param(value, keys).ok_or_else(|| {
        LedgerError::invalid(
            match code_name {
                "workflow_id" => "usage_ledger_workflow_id_missing",
                "plan_code" => "usage_ledger_plan_code_missing",
                _ => "usage_ledger_parameter_missing",
            },
            stage,
        )
    })
}

fn text_param(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn text_field(value: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn text_field_from_value(value: &Value, keys: &[&str]) -> Option<String> {
    value
        .as_object()
        .and_then(|object| text_field(object, keys))
}

fn number_param(value: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(number_value))
}

fn number_field(value: &Map<String, Value>, keys: &[&str]) -> Option<u64> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(number_value))
        .map(|value| value as u64)
}

fn number_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .filter(|value| *value >= 0)
        .or_else(|| value.as_u64().and_then(|value| i64::try_from(value).ok()))
        .or_else(|| {
            value
                .as_str()?
                .trim()
                .parse::<i64>()
                .ok()
                .filter(|value| *value >= 0)
        })
}

fn bool_param(value: &Value, keys: &[&str]) -> bool {
    keys.iter()
        .find_map(|key| value.get(*key))
        .is_some_and(|value| {
            value
                .as_bool()
                .or_else(|| {
                    value.as_str().and_then(|text| {
                        match text.trim().to_ascii_lowercase().as_str() {
                            "1" | "true" | "yes" | "on" => Some(true),
                            _ => Some(false),
                        }
                    })
                })
                .unwrap_or(false)
        })
}

fn bool_field(value: &Map<String, Value>, keys: &[&str]) -> bool {
    keys.iter()
        .find_map(|key| value.get(*key))
        .is_some_and(|value| {
            value
                .as_bool()
                .or_else(|| {
                    value.as_str().and_then(|text| {
                        match text.trim().to_ascii_lowercase().as_str() {
                            "1" | "true" | "yes" | "on" => Some(true),
                            _ => Some(false),
                        }
                    })
                })
                .unwrap_or(false)
        })
}

fn normalized_accuracy(value: &str) -> &str {
    match value.trim().to_ascii_lowercase().as_str() {
        "estimated" | "estimate" | "low" | "medium" => "estimated",
        _ => "exact",
    }
}

fn public_label(value: &str) -> String {
    let value = value.trim();
    if is_path_like(value) {
        return "redacted".to_owned();
    }
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(256)
        .collect()
}

fn opaque_binding(value: &str) -> String {
    // Bindings are private opaque handles.  Keep their identity stable, but
    // do not derive one from or include a native path.  Callers that pass a
    // path must provide the already-admitted opaque binding instead.
    public_label(value)
}

fn require_opaque_identifier(
    value: &str,
    code: &'static str,
    stage: &'static str,
) -> LedgerResult<String> {
    if !is_opaque_identifier(value) {
        return Err(LedgerError::invalid(code, stage));
    }
    Ok(value.trim().to_owned())
}

fn is_opaque_identifier(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && !is_path_like(value)
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':' | b'@' | b'+')
        })
}

fn is_path_like(value: &str) -> bool {
    Path::new(value).is_absolute()
        || value.contains('\\')
        || value.starts_with("~/")
        || value.starts_with("file:")
        || value
            .split('/')
            .any(|segment| segment == ".." || segment == ".")
}

fn validate_parent(
    transaction: &rusqlite::Transaction<'_>,
    workflow_id: &str,
    node_id: &str,
    parent_id: &str,
) -> LedgerResult<()> {
    if node_id == parent_id {
        return Err(LedgerError::invalid(
            "usage_ledger_parent_cycle",
            "usage-ledger-baseline",
        ));
    }
    let mut current = parent_id.to_owned();
    let mut seen = std::collections::BTreeSet::new();
    for _ in 0..=256 {
        if !seen.insert(current.clone()) || current == node_id {
            return Err(LedgerError::invalid(
                "usage_ledger_parent_cycle",
                "usage-ledger-baseline",
            ));
        }
        let parent = load_node(transaction, &current)?.ok_or_else(|| {
            LedgerError::invalid("usage_ledger_parent_not_found", "usage-ledger-baseline")
        })?;
        if parent.workflow_id != workflow_id {
            return Err(LedgerError::invalid(
                "usage_ledger_parent_workflow_mismatch",
                "usage-ledger-baseline",
            ));
        }
        let Some(next) = parent.parent_node_id else {
            return Ok(());
        };
        current = next;
    }
    Err(LedgerError::invalid(
        "usage_ledger_parent_cycle",
        "usage-ledger-baseline",
    ))
}

fn node_id_from_params(params: &Value, workflow_id: &str) -> String {
    text_param(params, &["nodeId", "node_id"])
        .map(|value| opaque_binding(&value))
        .or_else(|| {
            text_param(
                params,
                &[
                    "conversationBinding",
                    "conversation_binding",
                    "conversationId",
                    "conversation_id",
                ],
            )
            .map(|value| format!("{workflow_id}:conversation:{value}"))
        })
        .unwrap_or_else(|| format!("{workflow_id}:root"))
}

fn now_ms(params: &Value) -> i64 {
    if let Some(value) = number_param(params, &["nowUnixMs", "now_unix_ms"]) {
        return value;
    }
    if let Some(value) = text_param(params, &["now"]) {
        if let Ok(parsed) = OffsetDateTime::parse(&value, &Rfc3339) {
            return parsed.unix_timestamp_nanos().saturating_div(1_000_000) as i64;
        }
    }
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn i64_value(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn usage_json(prompt: i64, cached: i64, completion: i64, total: i64) -> Value {
    UsageTotals {
        prompt,
        cached,
        completion,
        total,
    }
    .to_value()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn state(label: &str) -> (PathBuf, Value) {
        let root =
            std::env::temp_dir().join(format!("lico-ledger-{label}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let params = json!({"stateRoot": root.to_string_lossy(), "nowUnixMs": 10_000});
        (root, params)
    }

    #[test]
    fn cumulative_and_exact_allocations_are_idempotent_and_bounded() {
        let (root, params) = state("numeric");
        let mut begin = params.clone();
        begin["workflowId"] = json!("delivery-1");
        begin["planCode"] = json!("PLAN-1");
        begin["planRevision"] = json!(1);
        begin_delivery(&begin).unwrap();
        let mut bind = begin.clone();
        bind["nodeId"] = json!("main-node");
        bind["conversationBinding"] = json!("main-conversation");
        bind["baseline"] =
            json!({"promptTokens": 10, "cachedInputTokens": 2, "completionTokens": 3});
        bind_conversation_baseline(&bind).unwrap();
        let mut settle = bind.clone();
        settle["usageMode"] = json!("cumulative");
        settle["usage"] = json!({"promptTokens": 14, "cachedInputTokens": 4, "completionTokens": 6, "eventId":"counter"});
        assert_eq!(settle_turn(&settle).unwrap()["usage"]["totalTokens"], 7);
        assert_eq!(settle_turn(&settle).unwrap()["usage"]["totalTokens"], 0);

        settle["usage"] = json!({"promptTokens": 2, "cachedInputTokens": 1, "completionTokens": 1, "eventId":"counter"});
        assert_eq!(settle_turn(&settle).unwrap()["usage"]["totalTokens"], 0);
        settle["usage"] = json!({"promptTokens": 5, "cachedInputTokens": 2, "completionTokens": 3, "eventId":"counter"});
        assert_eq!(settle_turn(&settle).unwrap()["usage"]["totalTokens"], 5);

        let mut independent = bind.clone();
        independent["nodeId"] = json!("independent-node");
        independent["conversationBinding"] = json!("independent-conversation");
        bind_conversation_baseline(&independent).unwrap();
        independent["usageMode"] = json!("cumulative");
        independent["usage"] = json!({"promptTokens": 14, "cachedInputTokens": 4, "completionTokens": 6, "eventId":"counter"});
        assert_eq!(
            settle_turn(&independent).unwrap()["usage"]["totalTokens"],
            7
        );
        let report = workflow_report(&params).unwrap();
        assert_eq!(report["summary"]["totalTokens"], 19);
        assert!(
            serde_json::to_string(&report)
                .unwrap()
                .find("conversation")
                .is_none()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn baseline_failure_is_typed_and_pre_dispatch() {
        let (root, params) = state("baseline-failure");
        let mut begin = params.clone();
        begin["workflowId"] = json!("delivery-2");
        begin["planCode"] = json!("PLAN-2");
        begin["planRevision"] = json!(1);
        begin_delivery(&begin).unwrap();
        let mut bind = begin.clone();
        bind["conversationBinding"] = json!("opaque");
        let error = bind_conversation_baseline(&bind).unwrap_err();
        assert_eq!(error.code, "usage_ledger_baseline_unavailable");
        assert_eq!(error.stage, "usage-ledger-baseline");
        assert!(error.retryable);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bindings_and_nodes_fail_closed_across_paths_and_workflows() {
        let (root, params) = state("binding-boundary");
        let mut first = params.clone();
        first["workflowId"] = json!("delivery-a");
        first["planCode"] = json!("PLAN-A");
        first["planRevision"] = json!(1);
        begin_delivery(&first).unwrap();

        let mut path_binding = first.clone();
        path_binding["nodeId"] = json!("node-a");
        path_binding["conversationBinding"] = json!("../private-path-canary");
        path_binding["baseline"] = json!({"promptTokens": 0});
        assert_eq!(
            bind_conversation_baseline(&path_binding).unwrap_err().code,
            "usage_ledger_conversation_binding_invalid"
        );

        let mut bind = first.clone();
        bind["nodeId"] = json!("shared-node");
        bind["conversationBinding"] = json!("opaque-a");
        bind["baseline"] = json!({"promptTokens": 0});
        bind_conversation_baseline(&bind).unwrap();

        let mut second = params.clone();
        second["workflowId"] = json!("delivery-b");
        second["planCode"] = json!("PLAN-B");
        second["planRevision"] = json!(1);
        begin_delivery(&second).unwrap();
        second["nodeId"] = json!("shared-node");
        second["usage"] = json!({"promptTokens": 1, "eventId": "event-b"});
        assert_eq!(
            settle_turn(&second).unwrap_err().code,
            "usage_ledger_node_workflow_mismatch"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn synthetic_delivery_tree_keeps_one_root_three_children_and_rollup_totals() {
        let (root, params) = state("tree");
        let mut begin = params.clone();
        begin["workflowId"] = json!("delivery-tree");
        begin["planCode"] = json!("PLAN-TREE");
        begin["planRevision"] = json!(2);
        begin["managerAgentId"] = json!("main-agent");
        begin_delivery(&begin).unwrap();

        let mut bind_root = begin.clone();
        bind_root["nodeId"] = json!("delivery-tree:root");
        bind_root["conversationBinding"] = json!("main-binding");
        bind_root["phase"] = json!("main");
        bind_root["role"] = json!("main");
        bind_root["agentId"] = json!("main-agent");
        bind_root["baseline"] =
            json!({"promptTokens": 0, "cachedInputTokens": 0, "completionTokens": 0});
        bind_conversation_baseline(&bind_root).unwrap();
        let mut root_turn = bind_root.clone();
        root_turn["usage"] = json!({"promptTokens": 10, "cachedInputTokens": 2, "completionTokens": 3, "eventId": "root-turn", "model": "main-model"});
        settle_turn(&root_turn).unwrap();

        let child_specs = [
            (
                "designer",
                "designer",
                "designer-binding",
                "designer-dispatch",
                "DESIGN",
                "model-designer",
            ),
            (
                "worker",
                "worker",
                "worker-binding",
                "worker-dispatch",
                "WORK",
                "model-worker",
            ),
            (
                "reviewer",
                "reviewer",
                "reviewer-binding",
                "reviewer-dispatch",
                "REVIEW",
                "model-reviewer",
            ),
        ];
        for (node, role, binding, dispatch, task, model) in child_specs {
            let mut bind = begin.clone();
            bind["nodeId"] = json!(node);
            bind["parentNodeId"] = json!("delivery-tree:root");
            bind["conversationBinding"] = json!(binding);
            bind["lineageScope"] = json!(if node == "reviewer" || node == "designer" {
                "designer-lineage"
            } else {
                binding
            });
            bind["dispatchId"] = json!(dispatch);
            bind["taskCode"] = json!(task);
            bind["phase"] = json!(role);
            bind["role"] = json!(role);
            bind["agentId"] = json!(format!("agent-{role}"));
            bind["model"] = json!(model);
            bind["baseline"] = if node == "worker" {
                json!({"promptTokens": 100, "cachedInputTokens": 20, "completionTokens": 10})
            } else {
                json!({"promptTokens": 0, "cachedInputTokens": 0, "completionTokens": 0})
            };
            bind_conversation_baseline(&bind).unwrap();
            let mut settle = bind.clone();
            if node == "worker" {
                settle["usageMode"] = json!("cumulative");
                settle["usage"] = json!({"promptTokens": 106, "cachedInputTokens": 22, "completionTokens": 14, "eventId": "worker-counter"});
            } else if node == "designer" {
                settle["usage"] = json!({"promptTokens": 10, "cachedInputTokens": 2, "completionTokens": 2, "eventId": "designer-prefix", "model": "model-designer"});
            } else {
                settle["usage"] = json!({"promptTokens": 15, "cachedInputTokens": 2, "completionTokens": 2, "eventId": "reviewer-new", "model": "model-reviewer"});
                settle["events"] = json!([
                    {"promptTokens": 10, "cachedInputTokens": 2, "completionTokens": 2, "eventId": "designer-prefix", "lineageScope": "designer-lineage"},
                    {"promptTokens": 15, "cachedInputTokens": 2, "completionTokens": 2, "eventId": "reviewer-new", "lineageScope": "designer-lineage"}
                ]);
                settle.as_object_mut().unwrap().remove("usage");
            }
            settle_turn(&settle).unwrap();
            if node == "reviewer" {
                settle["events"].as_array_mut().unwrap().reverse();
            }
            assert_eq!(settle_turn(&settle).unwrap()["usage"]["totalTokens"], 0);
        }
        let mut terminal = begin.clone();
        terminal["state"] = json!("completed");
        terminal["terminalCorrelation"] = json!("terminal-tree");
        mark_terminal(&terminal).unwrap();
        let report = workflow_report(&params).unwrap();
        assert_eq!(report["summary"]["promptTokens"], 41);
        assert_eq!(report["summary"]["cachedInputTokens"], 8);
        assert_eq!(report["summary"]["completionTokens"], 11);
        assert_eq!(report["summary"]["totalTokens"], 52);
        let workflow = &report["workflows"][0];
        assert_eq!(workflow["nodes"].as_array().unwrap().len(), 4);
        assert_eq!(workflow["roots"].as_array().unwrap().len(), 1);
        assert_eq!(
            workflow["roots"][0]["children"].as_array().unwrap().len(),
            3
        );
        for node in workflow["nodes"].as_array().unwrap() {
            for key in [
                "nodeId",
                "planCode",
                "planRevision",
                "dispatchId",
                "role",
                "attempt",
                "agentId",
                "model",
                "accuracy",
                "state",
                "terminalCorrelation",
            ] {
                assert!(!node.get(key).is_none_or(Value::is_null), "missing {key}");
            }
            assert!(
                !node.get("taskCode").is_none_or(Value::is_null)
                    || !node.get("phase").is_none_or(Value::is_null)
            );
        }
        let serialized = serde_json::to_string(&report).unwrap();
        assert!(!serialized.contains("main-binding"));
        assert!(!serialized.contains("prompt-canary"));
        let connection = Connection::open(root.join(WORKFLOW_LEDGER_FILE_NAME)).unwrap();
        let event_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM workflow_events", [], |row| row.get(0))
            .unwrap();
        let node_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM workflow_nodes", [], |row| row.get(0))
            .unwrap();
        assert_eq!(event_count, 0);
        assert_eq!(node_count, 0);
        fs::remove_dir_all(root).unwrap();
    }
}
