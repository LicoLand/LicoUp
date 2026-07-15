use crate::domain::conversations;
use crate::domain::targets;
use crate::platform::client_state::ClientStateStore;
use anyhow::Result;
use regex::Regex;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration as StdDuration, SystemTime, UNIX_EPOCH};
use time::{Date, Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

mod agent_usage_codex;

const AGENT_USAGE_SCHEMA_VERSION: u32 = 2;
const REPORT_COLLECTION: &str = "agent-usage-reports";
const MAX_REPORTS: usize = 20;
const DEFAULT_USAGE_WINDOW_DAYS: u64 = 30;
const CODEX_DEFAULT_CHATGPT_BASE_URL: &str = "https://chatgpt.com/backend-api/";
const CODEX_OAUTH_REFRESH_URL: &str = "https://auth.openai.com/oauth/token";
const CODEX_OAUTH_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_DASHBOARD_HELPER_BINARY_NAME: &str = "lico-openai-dashboard-helper";
const ANTIGRAVITY_REMOTE_BASE_URL: &str = "https://cloudcode-pa.googleapis.com";
const ANTIGRAVITY_OAUTH_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const ANTIGRAVITY_LOCAL_QUOTA_SUMMARY_PATH: &str =
    "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
const OPENROUTER_DEFAULT_API_BASE_URL: &str = "https://openrouter.ai/api/v1";
const KILO_DEFAULT_API_BASE_URL: &str = "https://app.kilo.ai/api/trpc";
const KIMI_DEFAULT_API_BASE_URL: &str = "https://api.moonshot.ai/v1";
const UNATTRIBUTED_MODEL: &str = "Others";
const KILO_TRPC_PROCEDURES: &[&str] = &[
    "user.getCreditBlocks",
    "kiloPass.getState",
    "user.getAutoTopUpPaymentMethod",
];

#[derive(Clone, Copy)]
struct AgentDef {
    id: &'static str,
    label: &'static str,
}

const SUPPORTED_AGENTS: &[AgentDef] = &[
    AgentDef {
        id: "antigravity",
        label: "Antigravity - IDE",
    },
    AgentDef {
        id: "claude-code",
        label: "Claude Code - CLI",
    },
    AgentDef {
        id: "codex",
        label: "ChatGPT - Desktop",
    },
    AgentDef {
        id: "copilot",
        label: "GitHub Copilot - Plugin",
    },
    AgentDef {
        id: "cursor",
        label: "Cursor - IDE",
    },
    AgentDef {
        id: "hermes",
        label: "Hermes Agent - CLI",
    },
    AgentDef {
        id: "kilo-code",
        label: "Kilo Code - CLI",
    },
    AgentDef {
        id: "openclaw",
        label: "OpenClaw - CLI",
    },
    AgentDef {
        id: "opencode",
        label: "OpenCode - CLI",
    },
    AgentDef {
        id: "kimi",
        label: "Kimi - Desktop",
    },
    AgentDef {
        id: "kimi-code",
        label: "Kimi Code - CLI",
    },
    AgentDef {
        id: "pi",
        label: "Pi Agent - CLI",
    },
];

#[derive(Default)]
struct HistoryUsageSummary {
    source: Option<&'static str>,
    session_count: u64,
    message_count: u64,
    explicit_prompt_tokens: u64,
    explicit_cached_input_tokens: u64,
    explicit_completion_tokens: u64,
    explicit_total_tokens: u64,
    estimated_prompt_tokens: u64,
    estimated_completion_tokens: u64,
    estimated_total_tokens: u64,
    explicit_records: u64,
    estimated_records: u64,
    dashboard_records: u64,
    source_paths: BTreeSet<String>,
    skipped: Vec<Value>,
    daily_usage: BTreeMap<String, DailyUsageSummary>,
    dashboard_daily_usage: Vec<Value>,
    scan_cache: Option<Value>,
}

impl HistoryUsageSummary {
    fn prompt_tokens(&self) -> u64 {
        self.explicit_prompt_tokens + self.estimated_prompt_tokens
    }

    fn completion_tokens(&self) -> u64 {
        self.explicit_completion_tokens + self.estimated_completion_tokens
    }

    fn total_tokens(&self) -> u64 {
        self.explicit_total_tokens + self.estimated_total_tokens
    }

    fn confidence(&self) -> &'static str {
        if self.explicit_records > 0 && self.estimated_records == 0 {
            "high"
        } else if self.explicit_records > 0 && self.estimated_records > 0 {
            "medium"
        } else if self.estimated_records > 0 {
            "low"
        } else {
            "unavailable"
        }
    }

    fn estimated_payload_bytes(&self) -> u64 {
        let total_tokens = self.total_tokens();
        if total_tokens == 0 {
            return 0;
        }
        total_tokens.saturating_mul(4) + self.session_count.saturating_mul(1200)
    }

    fn to_json(&self) -> Value {
        json!({
            "sessionCount": self.session_count,
            "messageCount": self.message_count,
            "promptTokens": self.prompt_tokens(),
            "cachedInputTokens": self.explicit_cached_input_tokens,
            "completionTokens": self.completion_tokens(),
            "totalTokens": self.total_tokens(),
            "explicitCoverage": if self.total_tokens() > 0 {
                self.explicit_total_tokens as f64 / self.total_tokens() as f64
            } else { 0.0 },
            "tokenSourceBreakdown": {
                "explicitRecords": self.explicit_records,
                "estimatedRecords": self.estimated_records,
                "explicitPromptTokens": self.explicit_prompt_tokens,
                "explicitCachedInputTokens": self.explicit_cached_input_tokens,
                "explicitCompletionTokens": self.explicit_completion_tokens,
                "explicitTotalTokens": self.explicit_total_tokens,
                "estimatedPromptTokens": self.estimated_prompt_tokens,
                "estimatedCompletionTokens": self.estimated_completion_tokens,
                "estimatedTotalTokens": self.estimated_total_tokens,
                "dashboardRecords": self.dashboard_records
            },
            "estimatedPayloadBytes": self.estimated_payload_bytes(),
            "dailyUsage": self.daily_usage_json(),
            "source": self.source.unwrap_or("native-history-adapters"),
            "confidence": self.confidence(),
            "scanCache": self.scan_cache
        })
    }

    fn daily_usage_json(&self) -> Vec<Value> {
        if !self.dashboard_daily_usage.is_empty() {
            return self.dashboard_daily_usage.clone();
        }
        self.daily_usage
            .iter()
            .filter_map(|(date, usage)| {
                if usage.total_tokens == 0 {
                    return None;
                }
                Some(json!({
                    "date": date,
                    "promptTokens": usage.prompt_tokens,
                    "cachedInputTokens": usage.cached_input_tokens,
                    "completionTokens": usage.completion_tokens,
                    "totalTokens": usage.total_tokens,
                    "messageCount": usage.message_count,
                    "modelUsage": usage.model_usage_totals_json(),
                    "modelTokenUsage": usage.model_token_usage_json(),
                    "estimatedRecords": usage.estimated_records,
                    "explicitRecords": usage.explicit_records
                }))
            })
            .collect()
    }

    fn add(&mut self, usage: MessageUsage, date_key: Option<String>) {
        if usage.total_tokens == 0 {
            return;
        }
        if usage.explicit {
            self.explicit_prompt_tokens += usage.prompt_tokens;
            self.explicit_cached_input_tokens += usage.cached_input_tokens;
            self.explicit_completion_tokens += usage.completion_tokens;
            self.explicit_total_tokens += usage.total_tokens;
            self.explicit_records += 1;
        } else {
            self.estimated_prompt_tokens += usage.prompt_tokens;
            self.estimated_completion_tokens += usage.completion_tokens;
            self.estimated_total_tokens += usage.total_tokens;
            self.estimated_records += 1;
        }
        if let Some(date_key) = date_key.filter(|value| !value.trim().is_empty()) {
            self.daily_usage.entry(date_key).or_default().add(usage);
        }
    }
}

#[derive(Clone, Default)]
struct MessageUsage {
    prompt_tokens: u64,
    cached_input_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    model: Option<String>,
    explicit: bool,
}

#[derive(Clone, Default)]
struct DailyUsageSummary {
    prompt_tokens: u64,
    cached_input_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    message_count: u64,
    explicit_records: u64,
    estimated_records: u64,
    model_usage: BTreeMap<String, ModelTokenUsageSummary>,
}

#[derive(Clone, Copy, Default)]
struct ModelTokenUsageSummary {
    prompt_tokens: u64,
    cached_input_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
}

#[derive(Clone)]
struct UsageWindow {
    start: String,
    end: String,
    days: u64,
    timezone_offset_minutes: i64,
    timezone_transitions: Vec<TimezoneTransition>,
}

#[derive(Clone)]
struct TimezoneTransition {
    at_epoch_seconds: i64,
    offset_minutes: i64,
}

impl UsageWindow {
    fn from_params(params: &Value) -> Self {
        let days = u64_param(params, "historyDays")
            .unwrap_or(DEFAULT_USAGE_WINDOW_DAYS)
            .clamp(1, 365);
        let timezone_offset_minutes = i64_param(params, "timezoneOffsetMinutes")
            .unwrap_or(0)
            .clamp(-24 * 60, 24 * 60);
        let timezone_transitions = timezone_transitions_param(params);
        let now_utc = text_param(params, &["now"])
            .and_then(|value| OffsetDateTime::parse(&value, &Rfc3339).ok())
            .unwrap_or_else(OffsetDateTime::now_utc);
        let current_offset = timezone_offset_at(
            now_utc.unix_timestamp(),
            timezone_offset_minutes,
            &timezone_transitions,
        );
        let now = now_utc + Duration::minutes(current_offset);
        let end_date = now.date();
        let start_date = end_date - Duration::days(days.saturating_sub(1) as i64);
        Self {
            start: date_key_from_date(start_date),
            end: date_key_from_date(end_date),
            days,
            timezone_offset_minutes,
            timezone_transitions,
        }
    }

    fn contains(&self, date: &str) -> bool {
        date >= self.start.as_str() && date <= self.end.as_str()
    }

    fn date_key(&self, value: &str) -> Option<String> {
        usage_date_key(value, self)
    }

    fn cache_timezone_key(&self) -> String {
        let transitions = self
            .timezone_transitions
            .iter()
            .map(|transition| {
                format!(
                    "{}:{}",
                    transition.at_epoch_seconds, transition.offset_minutes
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!("{}|{transitions}", self.timezone_offset_minutes)
    }
}

fn timezone_transitions_param(params: &Value) -> Vec<TimezoneTransition> {
    let Some(raw) = params
        .get("timezoneTransitions")
        .or_else(|| params.get("timezoneTransitionsJson"))
    else {
        return Vec::new();
    };
    let parsed = raw
        .as_str()
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .unwrap_or_else(|| raw.clone());
    let Some(items) = parsed.as_array() else {
        return Vec::new();
    };
    let mut transitions = BTreeMap::<i64, i64>::new();
    for item in items.iter().take(64) {
        let Some(at_epoch_seconds) =
            signed_number_field(item, &["atEpochSeconds", "at_epoch_seconds", "at"])
        else {
            continue;
        };
        let Some(offset_minutes) =
            signed_number_field(item, &["offsetMinutes", "offset_minutes", "offset"])
        else {
            continue;
        };
        if !(-24 * 60..=24 * 60).contains(&offset_minutes) {
            continue;
        }
        transitions.insert(at_epoch_seconds, offset_minutes);
    }
    transitions
        .into_iter()
        .map(|(at_epoch_seconds, offset_minutes)| TimezoneTransition {
            at_epoch_seconds,
            offset_minutes,
        })
        .collect()
}

fn timezone_offset_at(
    epoch_seconds: i64,
    fallback_offset_minutes: i64,
    transitions: &[TimezoneTransition],
) -> i64 {
    let index =
        transitions.partition_point(|transition| transition.at_epoch_seconds <= epoch_seconds);
    index
        .checked_sub(1)
        .and_then(|index| transitions.get(index))
        .map(|transition| transition.offset_minutes)
        .unwrap_or(fallback_offset_minutes)
}

fn signed_number_field(value: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter().find_map(|key| {
        let value = value.get(*key)?;
        value
            .as_i64()
            .or_else(|| value.as_u64().and_then(|value| i64::try_from(value).ok()))
            .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
    })
}

impl DailyUsageSummary {
    fn add(&mut self, usage: MessageUsage) {
        self.prompt_tokens += usage.prompt_tokens;
        self.cached_input_tokens += usage.cached_input_tokens;
        self.completion_tokens += usage.completion_tokens;
        self.total_tokens += usage.total_tokens;
        self.message_count += 1;
        if usage.explicit {
            self.explicit_records += 1;
        } else {
            self.estimated_records += 1;
        }
        let model = usage
            .model
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string());
        self.add_model_usage(
            model,
            usage.prompt_tokens,
            usage.cached_input_tokens,
            usage.completion_tokens,
            usage.total_tokens,
        );
    }

    fn add_model_usage(
        &mut self,
        model: String,
        prompt_tokens: u64,
        cached_input_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
    ) {
        self.model_usage.entry(model).or_default().add(
            prompt_tokens,
            cached_input_tokens,
            completion_tokens,
            total_tokens,
        );
    }

    fn model_usage_totals_json(&self) -> BTreeMap<String, u64> {
        self.model_usage
            .iter()
            .map(|(model, usage)| (model.clone(), usage.total_tokens))
            .collect()
    }

    fn model_token_usage_json(&self) -> BTreeMap<String, Value> {
        self.model_usage
            .iter()
            .map(|(model, usage)| (model.clone(), usage.to_json()))
            .collect()
    }
}

impl ModelTokenUsageSummary {
    fn add(
        &mut self,
        prompt_tokens: u64,
        cached_input_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
    ) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(prompt_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(cached_input_tokens.min(prompt_tokens));
        self.completion_tokens = self.completion_tokens.saturating_add(completion_tokens);
        self.total_tokens = self.total_tokens.saturating_add(total_tokens);
    }

    fn merge(&mut self, other: Self) {
        self.add(
            other.prompt_tokens,
            other.cached_input_tokens,
            other.completion_tokens,
            other.total_tokens,
        );
    }

    fn to_json(self) -> Value {
        json!({
            "promptTokens": self.prompt_tokens,
            "cachedInputTokens": self.cached_input_tokens,
            "completionTokens": self.completion_tokens,
            "totalTokens": self.total_tokens,
        })
    }
}

#[derive(Clone)]
struct ProcessSample {
    agent_id: String,
    pid: u64,
    process_name: String,
    started_at: String,
    sampled_at: String,
    rx_bytes: u64,
    tx_bytes: u64,
}

#[derive(Default)]
struct ProcessMeterSummary {
    metered_rx_bytes: u64,
    metered_tx_bytes: u64,
    sample_count: usize,
    process_count: usize,
    warnings: Vec<String>,
}

impl ProcessMeterSummary {
    fn total(&self) -> u64 {
        self.metered_rx_bytes + self.metered_tx_bytes
    }

    fn confidence(&self) -> &'static str {
        if self.total() > 0 {
            "high"
        } else if self.sample_count > 0 {
            "medium"
        } else {
            "unavailable"
        }
    }
}

pub fn scan(params: &Value) -> Result<Value> {
    let generated_at = timestamp_rfc3339();
    let agent_filter = text_param(params, &["agent", "target"]);
    let allowances_only = bool_param(params, "allowancesOnly").unwrap_or(false);
    let include_allowances =
        allowances_only || bool_param(params, "includeAllowances").unwrap_or(false);
    let include_billing_history = bool_param(params, "includeBillingHistory").unwrap_or(false);
    let include_target_status = bool_param(params, "includeTargetStatus").unwrap_or(false);
    let usage_window = UsageWindow::from_params(params);
    let process_samples = if allowances_only {
        Vec::new()
    } else {
        let mut samples = process_samples_from_params(params);
        if samples.is_empty() {
            samples = collect_platform_process_samples(params);
        }
        samples
    };
    let mut warnings = Vec::<Value>::new();
    let target_status = if allowances_only || !include_target_status {
        BTreeMap::new()
    } else {
        target_status_map(params, &mut warnings)
    };
    let mut agents = Vec::<Value>::new();
    let mut summary = HistoryUsageSummary::default();
    let mut summary_metered_rx = 0u64;
    let mut summary_metered_tx = 0u64;
    let mut agents_with_metered_traffic = 0u64;

    for def in SUPPORTED_AGENTS {
        if agent_filter
            .as_ref()
            .map(|filter| normalize_agent_id(filter) != def.id)
            .unwrap_or(false)
        {
            continue;
        }
        let history = if allowances_only {
            HistoryUsageSummary::default()
        } else {
            summarize_agent_history(def, params, &usage_window, &mut warnings)
        };
        let billing_history = if def.id == "codex" && include_billing_history {
            summarize_codex_openai_dashboard_history(params, &mut warnings).map(|summary| {
                json!({
                    "source": "openai-dashboard-web",
                    "usageUnit": "credits",
                    "dailyUsage": summary.daily_usage_json()
                })
            })
        } else {
            None
        };
        let process = if allowances_only {
            ProcessMeterSummary::default()
        } else {
            summarize_process_samples(def.id, &process_samples)
        };
        for warning in &process.warnings {
            warnings.push(json!({
                "code": warning,
                "agentId": def.id
            }));
        }
        if process.total() > 0 {
            agents_with_metered_traffic += 1;
        }
        summary.session_count += history.session_count;
        summary.message_count += history.message_count;
        summary.explicit_prompt_tokens += history.explicit_prompt_tokens;
        summary.explicit_cached_input_tokens += history.explicit_cached_input_tokens;
        summary.explicit_completion_tokens += history.explicit_completion_tokens;
        summary.explicit_total_tokens += history.explicit_total_tokens;
        summary.estimated_prompt_tokens += history.estimated_prompt_tokens;
        summary.estimated_completion_tokens += history.estimated_completion_tokens;
        summary.estimated_total_tokens += history.estimated_total_tokens;
        summary.explicit_records += history.explicit_records;
        summary.estimated_records += history.estimated_records;
        summary.dashboard_records += history.dashboard_records;
        for (date, daily_usage) in &history.daily_usage {
            let entry = summary.daily_usage.entry(date.clone()).or_default();
            entry.prompt_tokens += daily_usage.prompt_tokens;
            entry.cached_input_tokens += daily_usage.cached_input_tokens;
            entry.completion_tokens += daily_usage.completion_tokens;
            entry.total_tokens += daily_usage.total_tokens;
            entry.message_count += daily_usage.message_count;
            entry.explicit_records += daily_usage.explicit_records;
            entry.estimated_records += daily_usage.estimated_records;
            for (model, model_usage) in &daily_usage.model_usage {
                entry
                    .model_usage
                    .entry(model.clone())
                    .and_modify(|value| value.merge(*model_usage))
                    .or_insert(*model_usage);
            }
        }
        summary_metered_rx += process.metered_rx_bytes;
        summary_metered_tx += process.metered_tx_bytes;
        let estimated_historical_bytes = history.estimated_payload_bytes();
        let attribution = traffic_attribution(process.total(), estimated_historical_bytes);
        let confidence = traffic_confidence(process.confidence(), history.confidence());
        agents.push(json!({
            "agentId": def.id,
            "label": def.label,
            "status": target_status.get(def.id).cloned().unwrap_or_else(|| "unknown".to_string()),
            "history": history.to_json(),
            "billingHistory": billing_history,
            "traffic": {
                "meteredRxBytes": process.metered_rx_bytes,
                "meteredTxBytes": process.metered_tx_bytes,
                "meteredTotalBytes": process.total(),
                "estimatedHistoricalBytes": estimated_historical_bytes,
                "attribution": attribution,
                "meterSource": if process.sample_count > 0 { "process-samples" } else { "platform-unavailable" },
                "sampleCount": process.sample_count,
                "processCount": process.process_count
            },
            "allowances": if include_allowances { account_allowances_for(def.id, params) } else { Vec::new() },
            "confidence": confidence,
            "sources": {
                "historyRoots": history.source_paths.into_iter().collect::<Vec<_>>(),
                "skipped": history.skipped
            }
        }));
    }

    let summary_estimated_historical_bytes = summary.estimated_payload_bytes();
    let report = json!({
        "ok": true,
        "schemaVersion": AGENT_USAGE_SCHEMA_VERSION,
        "mode": "agent-usage-metering",
        "generatedAt": generated_at,
        "window": {
            "start": usage_window.start,
            "end": usage_window.end,
            "days": usage_window.days,
            "timezoneOffsetMinutes": usage_window.timezone_offset_minutes,
            "timezoneTransitionCount": usage_window.timezone_transitions.len()
        },
        "providerMode": if allowances_only { "allowances-only" } else if process_samples.is_empty() { "contract" } else { "local-live" },
        "summary": {
            "agentCount": agents.len(),
            "sessionCount": summary.session_count,
            "messageCount": summary.message_count,
            "promptTokens": summary.prompt_tokens(),
            "completionTokens": summary.completion_tokens(),
            "totalTokens": summary.total_tokens(),
            "estimatedHistoricalBytes": summary_estimated_historical_bytes,
            "meteredRxBytes": summary_metered_rx,
            "meteredTxBytes": summary_metered_tx,
            "meteredTotalBytes": summary_metered_rx + summary_metered_tx,
            "agentsWithMeteredTraffic": agents_with_metered_traffic,
            "windowStart": usage_window.start,
            "windowEnd": usage_window.end,
            "windowDays": usage_window.days,
            "attribution": traffic_attribution(summary_metered_rx + summary_metered_tx, summary_estimated_historical_bytes),
            "confidence": traffic_confidence(
                if summary_metered_rx + summary_metered_tx > 0 { "high" } else { "unavailable" },
                summary.confidence()
            )
        },
        "agents": agents,
        "sources": {
            "history": if allowances_only { "not-scanned" } else { "native-history-adapters" },
            "traffic": if allowances_only { "not-scanned" } else if process_samples.is_empty() { "platform-unavailable" } else { "process-samples" },
            "retention": {
                "collection": REPORT_COLLECTION,
                "maxReports": MAX_REPORTS
            }
        },
        "warnings": warnings
    });
    if !allowances_only {
        persist_report(params, &report)?;
    }
    Ok(report)
}

pub fn report(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let mut collection = store.read_collection(REPORT_COLLECTION)?;
    let agent_filter =
        text_param(params, &["agent", "target"]).map(|value| normalize_agent_id(&value));
    let limit = u64_param(params, "limit").unwrap_or(10) as usize;
    let stored_items = collection
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut retained_items = stored_items
        .iter()
        .cloned()
        .into_iter()
        .filter(is_current_report)
        .collect::<Vec<_>>();
    sort_reports_by_generated_at(&mut retained_items);
    if retained_items != stored_items {
        if let Some(object) = collection.as_object_mut() {
            object.insert("items".to_string(), Value::Array(retained_items.clone()));
        }
        store.write_collection(REPORT_COLLECTION, collection)?;
    }
    let mut reports = retained_items
        .into_iter()
        .filter(|report| match agent_filter.as_deref() {
            Some(agent_id) => report_has_agent(report, agent_id),
            None => true,
        })
        .collect::<Vec<_>>();
    if reports.len() > limit {
        reports = reports[reports.len() - limit..].to_vec();
    }
    reports.reverse();
    Ok(json!({
        "ok": true,
        "schemaVersion": AGENT_USAGE_SCHEMA_VERSION,
        "mode": "agent-usage-metering",
        "resultKind": "retained-reports",
        "reports": reports
    }))
}

fn summarize_agent_history(
    def: &AgentDef,
    params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> HistoryUsageSummary {
    if def.id == "codex" {
        if let Some(summary) = agent_usage_codex::summarize(params, window, warnings) {
            return summary;
        }
    }

    let mut conversation_params = params.clone();
    if let Some(object) = conversation_params.as_object_mut() {
        object.insert("agent".to_string(), json!(def.id));
    }
    let listed = match conversations::conversation_list(&conversation_params) {
        Ok(value) => value,
        Err(error) => {
            let _ = error;
            warnings.push(json!({
                "code": "native_history_scan_failed",
                "agentId": def.id
            }));
            return HistoryUsageSummary::default();
        }
    };
    let mut summary = HistoryUsageSummary::default();
    if let Some(sessions) = listed.get("sessions").and_then(Value::as_array) {
        for session in sessions {
            if let Some(path) = session.get("sourcePath").and_then(Value::as_str) {
                if !path.trim().is_empty() {
                    summary
                        .source_paths
                        .insert("native-history-store".to_string());
                }
            }
            let messages = session
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let session_model = session_model_label(session);
            let session_date = session_date_key(session, window);
            let before = summary.total_tokens();
            if session.get("usage").is_some() {
                if add_message_usage(
                    session,
                    &mut summary,
                    session_date,
                    session_model.clone(),
                    window,
                ) {
                    summary.message_count += 1;
                }
            } else {
                let mut pending_segment = Vec::<(MessageUsage, String)>::new();
                for message in messages {
                    let date_key =
                        message_date_key(&message, window).or_else(|| session_date.clone());
                    let added_messages = collect_message_usage_tree(
                        &message,
                        &mut summary,
                        &mut pending_segment,
                        date_key,
                        session_model.clone(),
                        window,
                    );
                    summary.message_count = summary.message_count.saturating_add(added_messages);
                }
                summary.message_count =
                    summary
                        .message_count
                        .saturating_add(flush_pending_message_usage(
                            &mut pending_segment,
                            &mut summary,
                        ));
            }
            if summary.total_tokens() > before {
                summary.session_count += 1;
            }
        }
    }
    if let Some(skipped) = listed
        .get("sources")
        .and_then(|sources| sources.get("skipped"))
        .and_then(Value::as_array)
    {
        summary.skipped = skipped
            .iter()
            .map(|item| {
                json!({
                    "code": text_field(item, &["code", "reason"])
                        .unwrap_or_else(|| "history_source_skipped".to_string()),
                    "agentId": def.id
                })
            })
            .collect();
    }
    summary
}

fn summarize_codex_openai_dashboard_history(
    params: &Value,
    warnings: &mut Vec<Value>,
) -> Option<HistoryUsageSummary> {
    if bool_param(params, "disableCodexOpenAIWebDashboard").unwrap_or(false) {
        return None;
    }
    if let Some(enabled) = bool_env("LICO_AGENT_USAGE_CODEX_OPENAI_WEB_DASHBOARD") {
        if !enabled {
            return None;
        }
    }
    let helper_path = resolve_openai_dashboard_helper_path(params)?;
    let timeout_ms = u64_param(params, "codexOpenAIWebDashboardTimeoutMs").unwrap_or(12_000);
    let mut command = Command::new(&helper_path);
    command
        .arg("fetch")
        .arg("--timeout-ms")
        .arg(timeout_ms.to_string());
    if let Some(url) = text_param(params, &["codexOpenAIWebDashboardUrl"]) {
        command.arg("--url").arg(url);
    }
    let interaction = text_param(
        params,
        &[
            "codexOpenAIWebDashboardKeychainInteraction",
            "codexOpenAiWebDashboardKeychainInteraction",
            "openAIDashboardKeychainInteraction",
            "openAiDashboardKeychainInteraction",
        ],
    )
    .or_else(|| env_text("LICO_OPENAI_DASHBOARD_KEYCHAIN_INTERACTION"))
    .unwrap_or_else(|| "none".to_string());
    let browser_cookie_import = bool_param(params, "openAIDashboardBrowserCookieImport")
        .or_else(|| bool_param(params, "openAiDashboardBrowserCookieImport"))
        .or_else(|| bool_param(params, "codexOpenAIWebDashboardBrowserCookieImport"))
        .or_else(|| bool_param(params, "codexOpenAiWebDashboardBrowserCookieImport"))
        .unwrap_or(false);
    command
        .arg("--keychain-interaction")
        .arg(interaction)
        .arg("--browser-cookie-import")
        .arg(browser_cookie_import.to_string());
    if let Some(cookie_header) = text_param(params, &["openAIDashboardCookieHeader"]) {
        command.env("LICO_OPENAI_DASHBOARD_COOKIE_HEADER", cookie_header);
    }
    let output = match command.output() {
        Ok(output) => output,
        Err(error) => {
            let _ = error;
            warnings.push(json!({
                "code": "codex_openai_dashboard_helper_failed",
                "agentId": "codex"
            }));
            return None;
        }
    };
    let payload = serde_json::from_slice::<Value>(&output.stdout).unwrap_or(Value::Null);
    if !output.status.success() {
        warnings.push(json!({
            "code": "codex_openai_dashboard_helper_failed",
            "agentId": "codex",
            "status": text_field(&payload, &["status"]).unwrap_or_else(|| "failed".to_string())
        }));
        return None;
    }
    match dashboard_history_from_helper_payload(&payload) {
        Some(summary) => Some(summary),
        None => {
            warnings.push(json!({
                "code": "codex_openai_dashboard_unavailable",
                "agentId": "codex",
                "status": text_field(&payload, &["status"]).unwrap_or_else(|| "no_dashboard_data".to_string())
            }));
            None
        }
    }
}

fn resolve_openai_dashboard_helper_path(params: &Value) -> Option<PathBuf> {
    if let Some(path) = text_param(params, &["openAIDashboardHelperPath"]) {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Some(path);
        }
    }
    if let Ok(path) = std::env::var("LICO_OPENAI_DASHBOARD_HELPER_PATH") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            let path = PathBuf::from(trimmed);
            if path.is_file() {
                return Some(path);
            }
        }
    }
    let current = std::env::current_exe().ok()?;
    let sibling = current.parent()?.join(OPENAI_DASHBOARD_HELPER_BINARY_NAME);
    if sibling.is_file() {
        return Some(sibling);
    }
    None
}

fn dashboard_history_from_helper_payload(payload: &Value) -> Option<HistoryUsageSummary> {
    let items = array_field(payload, &["usageBreakdown", "usage_breakdown"])?;
    let mut daily = Vec::<Value>::new();
    for item in items {
        let date = text_field(item, &["day", "date"])?;
        let services = array_field(item, &["services", "serviceUsage"])
            .cloned()
            .unwrap_or_default();
        let mut model_usage = serde_json::Map::<String, Value>::new();
        let mut model_breakdown = Vec::<Value>::new();
        let mut total = f64_field(item, &["totalCreditsUsed", "total_credits_used"]).unwrap_or(0.0);
        let mut summed = 0.0f64;
        for service in services {
            let Some(name) = text_field(&service, &["service", "name", "label"]) else {
                continue;
            };
            let credits = f64_field(&service, &["creditsUsed", "credits_used", "value", "total"])
                .unwrap_or(0.0);
            if credits <= 0.0 {
                continue;
            }
            summed += credits;
            model_usage.insert(name.clone(), json!(credits));
            model_breakdown.push(json!({
                "model": name,
                "creditsUsed": credits,
                "usageUnit": "credits"
            }));
        }
        if total <= 0.0 {
            total = summed;
        }
        if total <= 0.0 || model_usage.is_empty() {
            continue;
        }
        daily.push(json!({
            "date": date,
            "totalCreditsUsed": total,
            "usageUnit": "credits",
            "modelUsage": Value::Object(model_usage),
            "modelBreakdown": model_breakdown,
            "source": "openai-dashboard-web"
        }));
    }
    if daily.is_empty() {
        return None;
    }
    let mut summary = HistoryUsageSummary {
        source: Some("openai-dashboard-web"),
        dashboard_records: daily.len() as u64,
        dashboard_daily_usage: daily,
        ..HistoryUsageSummary::default()
    };
    summary
        .source_paths
        .insert("openai-dashboard-web".to_string());
    Some(summary)
}

fn message_date_key(message: &Value, window: &UsageWindow) -> Option<String> {
    text_field(
        message,
        &[
            "createdAt",
            "updatedAt",
            "timestamp",
            "time",
            "date",
            "created_at",
            "updated_at",
        ],
    )
    .and_then(|value| window.date_key(&value))
}

fn session_date_key(session: &Value, window: &UsageWindow) -> Option<String> {
    text_field(
        session,
        &[
            "updatedAt",
            "createdAt",
            "timestamp",
            "time",
            "date",
            "updated_at",
            "created_at",
        ],
    )
    .and_then(|value| window.date_key(&value))
}

fn usage_date_key(value: &str, window: &UsageWindow) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.len() == 10
        && trimmed.as_bytes().get(4) == Some(&b'-')
        && trimmed.as_bytes().get(7) == Some(&b'-')
    {
        return Some(trimmed.to_string());
    }
    if let Ok(timestamp) = OffsetDateTime::parse(trimmed, &Rfc3339) {
        let offset = timezone_offset_at(
            timestamp.unix_timestamp(),
            window.timezone_offset_minutes,
            &window.timezone_transitions,
        );
        return Some(date_key_from_date(
            (timestamp + Duration::minutes(offset)).date(),
        ));
    }
    trimmed
        .parse::<i64>()
        .ok()
        .and_then(|value| epoch_seconds_to_date_key(value, window))
}

fn epoch_seconds_to_date_key(value: i64, window: &UsageWindow) -> Option<String> {
    if value <= 0 {
        return None;
    }
    let absolute = (value as i128).abs();
    let seconds = if absolute >= 100_000_000_000_000_000 {
        value / 1_000_000_000
    } else if absolute >= 100_000_000_000_000 {
        value / 1_000_000
    } else if absolute >= 100_000_000_000 {
        value / 1_000
    } else {
        value
    };
    let offset = timezone_offset_at(
        seconds,
        window.timezone_offset_minutes,
        &window.timezone_transitions,
    );
    OffsetDateTime::from_unix_timestamp(seconds)
        .ok()
        .map(|time| date_key_from_date((time + Duration::minutes(offset)).date()))
}

fn date_key_from_date(date: Date) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        date.year(),
        u8::from(date.month()),
        date.day()
    )
}

fn add_message_usage(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    date_key: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
) -> bool {
    let Some(date_key) = date_key.filter(|value| window.contains(value)) else {
        return false;
    };
    let before = summary.total_tokens();
    let Some(usage) = message_usage(message, default_model) else {
        return false;
    };
    summary.add(usage, Some(date_key));
    summary.total_tokens() > before
}

fn message_usage(message: &Value, default_model: Option<String>) -> Option<MessageUsage> {
    if let Some(usage) = message.get("usage") {
        let mut prompt_tokens =
            number_field(usage, &["promptTokens", "prompt_tokens"]).unwrap_or(0);
        let mut completion_tokens =
            number_field(usage, &["completionTokens", "completion_tokens"]).unwrap_or(0);
        let field_total = prompt_tokens.saturating_add(completion_tokens);
        let total_tokens = number_field(usage, &["totalTokens", "total_tokens"])
            .filter(|value| *value > 0)
            .unwrap_or(field_total);
        if field_total != total_tokens {
            if field_total > total_tokens {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            } else if prompt_tokens > 0 {
                prompt_tokens = prompt_tokens.min(total_tokens);
                completion_tokens = total_tokens.saturating_sub(prompt_tokens);
            } else {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            }
        }
        if total_tokens == 0 {
            return None;
        }
        return Some(MessageUsage {
            prompt_tokens,
            cached_input_tokens: number_field(
                usage,
                &[
                    "cachedInputTokens",
                    "cached_input_tokens",
                    "cacheReadInputTokens",
                    "cache_read_input_tokens",
                ],
            )
            .unwrap_or(0)
            .min(prompt_tokens),
            completion_tokens,
            total_tokens,
            model: message_model_label(message).or(default_model),
            explicit: true,
        });
    }
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if role == "metadata" {
        return None;
    }
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let tokens = estimate_tokens(text);
    if tokens == 0 {
        return None;
    }
    let usage = if role == "agent" {
        MessageUsage {
            completion_tokens: tokens,
            total_tokens: tokens,
            model: message_model_label(message).or_else(|| default_model.clone()),
            explicit: false,
            ..MessageUsage::default()
        }
    } else {
        MessageUsage {
            prompt_tokens: tokens,
            total_tokens: tokens,
            model: message_model_label(message).or_else(|| default_model.clone()),
            explicit: false,
            ..MessageUsage::default()
        }
    };
    Some(usage)
}

fn collect_message_usage_tree(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    pending_segment: &mut Vec<(MessageUsage, String)>,
    fallback_date: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
) -> u64 {
    if let Some(children) = message.get("messages").and_then(Value::as_array)
        && !children.is_empty()
    {
        let mut added = children
            .iter()
            .map(|child| {
                let date_key = message_date_key(child, window).or_else(|| fallback_date.clone());
                collect_message_usage_tree(
                    child,
                    summary,
                    pending_segment,
                    date_key,
                    default_model.clone(),
                    window,
                )
            })
            .sum();
        if message.get("usage").is_some() {
            added += collect_message_usage(
                message,
                summary,
                pending_segment,
                fallback_date,
                default_model,
                window,
                true,
            );
        }
        return added;
    }
    collect_message_usage(
        message,
        summary,
        pending_segment,
        fallback_date,
        default_model,
        window,
        false,
    )
}

fn collect_message_usage(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    pending_segment: &mut Vec<(MessageUsage, String)>,
    date_key: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
    parent_scope: bool,
) -> u64 {
    let Some(usage) = message_usage(message, default_model) else {
        return 0;
    };
    if usage.explicit {
        let usage_scope = message
            .get("usageScope")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let covers_pending_segment = parent_scope
            || matches!(
                usage_scope,
                "request-response" | "pending-segment" | "turn" | "session"
            );
        let mut added = if covers_pending_segment {
            pending_segment.clear();
            0
        } else {
            flush_pending_message_usage(pending_segment, summary)
        };
        if let Some(date_key) = date_key.filter(|value| window.contains(value)) {
            summary.add(usage, Some(date_key));
            added += 1;
        }
        return added;
    }
    if let Some(date_key) = date_key.filter(|value| window.contains(value)) {
        pending_segment.push((usage, date_key));
    }
    0
}

fn flush_pending_message_usage(
    pending_segment: &mut Vec<(MessageUsage, String)>,
    summary: &mut HistoryUsageSummary,
) -> u64 {
    let added = pending_segment.len() as u64;
    for (usage, date_key) in pending_segment.drain(..) {
        summary.add(usage, Some(date_key));
    }
    added
}

fn session_model_label(session: &Value) -> Option<String> {
    text_field(
        session,
        &[
            "model",
            "modelId",
            "model_id",
            "modelName",
            "model_name",
            "modelLabel",
            "model_label",
        ],
    )
    .or_else(|| {
        session
            .pointer("/modelConfig/modelName")
            .and_then(|value| value.as_str().map(|text| text.trim().to_string()))
    })
    .map(|value| {
        if value.eq_ignore_ascii_case("default") {
            "cursor-auto".to_string()
        } else {
            value
        }
    })
}

fn message_model_label(message: &Value) -> Option<String> {
    text_field(
        message,
        &[
            "model",
            "modelId",
            "model_id",
            "modelName",
            "model_name",
            "modelLabel",
            "model_label",
        ],
    )
    .or_else(|| {
        message.get("modelInfo").and_then(|info| {
            text_field(
                info,
                &["modelName", "model_name", "model", "modelId", "model_id"],
            )
        })
    })
    .or_else(|| {
        message.get("usage").and_then(|usage| {
            text_field(
                usage,
                &[
                    "model",
                    "modelId",
                    "model_id",
                    "modelName",
                    "model_name",
                    "modelLabel",
                    "model_label",
                ],
            )
        })
    })
    .map(|value| {
        if value.eq_ignore_ascii_case("default") {
            "cursor-auto".to_string()
        } else {
            value
        }
    })
}

fn process_samples_from_params(params: &Value) -> Vec<ProcessSample> {
    let Some(value) = params
        .get("processSamples")
        .or_else(|| params.get("processSamplesJson"))
    else {
        return Vec::new();
    };
    let parsed = if let Some(text) = value.as_str() {
        serde_json::from_str::<Value>(text).unwrap_or(Value::Null)
    } else {
        value.clone()
    };
    parsed
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(process_sample_from_value)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn collect_platform_process_samples(params: &Value) -> Vec<ProcessSample> {
    #[cfg(target_os = "macos")]
    {
        let pids = json_pid_list(params);
        if pids.is_empty() {
            return Vec::new();
        }
        let Some(live) = crate::platform::macos_sample_process_network_bytes(&pids) else {
            return Vec::new();
        };
        let sampled_at = timestamp_rfc3339();
        let started_at = text_param(params, &["processStartedAt", "startedAt"]).unwrap_or_default();
        let agent_id = text_param(params, &["agent", "target", "agentId"])
            .map(|value| normalize_agent_id(&value))
            .unwrap_or_else(|| "unknown".to_string());
        let values =
            crate::platform::macos_process_samples_json(&agent_id, &live, &started_at, &sampled_at);
        return values
            .iter()
            .filter_map(process_sample_from_value)
            .collect();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = params;
        Vec::new()
    }
}

fn json_pid_list(params: &Value) -> Vec<u64> {
    let Some(value) = params.get("processPids").or_else(|| params.get("pids")) else {
        return Vec::new();
    };
    if let Some(items) = value.as_array() {
        return items
            .iter()
            .filter_map(|item| item.as_u64().or_else(|| item.as_i64().map(|v| v as u64)))
            .filter(|pid| *pid > 0)
            .collect();
    }
    if let Some(text) = value.as_str() {
        return text
            .split(|c: char| c == ',' || c.is_whitespace())
            .filter_map(|part| part.trim().parse::<u64>().ok())
            .filter(|pid| *pid > 0)
            .collect();
    }
    Vec::new()
}

fn process_sample_from_value(value: &Value) -> Option<ProcessSample> {
    let agent_id = text_field(value, &["agentId", "agent", "target"])
        .map(|agent| normalize_agent_id(&agent))?;
    Some(ProcessSample {
        agent_id,
        pid: number_field(value, &["pid", "processId"]).unwrap_or(0),
        process_name: text_field(value, &["processName", "name"]).unwrap_or_default(),
        started_at: text_field(value, &["startedAt", "startTime"]).unwrap_or_default(),
        sampled_at: text_field(value, &["sampledAt", "timestamp"]).unwrap_or_default(),
        rx_bytes: number_field(value, &["rxBytes", "receivedBytes", "bytesIn"]).unwrap_or(0),
        tx_bytes: number_field(value, &["txBytes", "sentBytes", "bytesOut"]).unwrap_or(0),
    })
}

fn summarize_process_samples(agent_id: &str, samples: &[ProcessSample]) -> ProcessMeterSummary {
    let relevant = samples
        .iter()
        .filter(|sample| sample.agent_id == agent_id)
        .cloned()
        .collect::<Vec<_>>();
    if relevant.is_empty() {
        return ProcessMeterSummary::default();
    }
    let mut groups = BTreeMap::<String, Vec<ProcessSample>>::new();
    for sample in relevant {
        let key = format!(
            "{}:{}:{}",
            sample.pid, sample.process_name, sample.started_at
        );
        groups.entry(key).or_default().push(sample);
    }
    let mut summary = ProcessMeterSummary {
        sample_count: groups.values().map(Vec::len).sum(),
        process_count: groups.len(),
        ..ProcessMeterSummary::default()
    };
    for (_key, mut items) in groups {
        items.sort_by(|left, right| left.sampled_at.cmp(&right.sampled_at));
        let Some(first) = items.first() else {
            continue;
        };
        let Some(last) = items.last() else {
            continue;
        };
        let rx_delta = last.rx_bytes.saturating_sub(first.rx_bytes);
        let tx_delta = last.tx_bytes.saturating_sub(first.tx_bytes);
        if items.len() == 1 {
            summary
                .warnings
                .push("process_network_sample_without_delta".to_string());
        }
        summary.metered_rx_bytes += rx_delta;
        summary.metered_tx_bytes += tx_delta;
    }
    summary
}

fn target_status_map(params: &Value, warnings: &mut Vec<Value>) -> BTreeMap<String, String> {
    let mut scan_params = params.clone();
    if let Some(object) = scan_params.as_object_mut() {
        object.insert("includeAccessibleEnvironments".to_string(), json!(false));
        object.insert("includeHistoryModelCatalog".to_string(), json!(false));
    }
    match targets::scan_targets_with_params(&scan_params) {
        Ok(scan) => scan
            .get("candidates")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        Some((
                            item.get("target")?.as_str()?.to_string(),
                            item.get("status")?.as_str()?.to_string(),
                        ))
                    })
                    .collect::<BTreeMap<_, _>>()
            })
            .unwrap_or_default(),
        Err(error) => {
            let _ = error;
            warnings.push(json!({
                "code": "target_scan_failed",
            }));
            BTreeMap::new()
        }
    }
}

fn persist_report(params: &Value, report: &Value) -> Result<()> {
    let store = client_state_store(params)?;
    let mut collection = store.read_collection(REPORT_COLLECTION)?;
    let mut items = collection
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(is_current_report)
        .collect::<Vec<_>>();
    items.push(report.clone());
    sort_reports_by_generated_at(&mut items);
    if items.len() > MAX_REPORTS {
        items = items[items.len() - MAX_REPORTS..].to_vec();
    }
    if let Some(object) = collection.as_object_mut() {
        object.insert("items".to_string(), Value::Array(items));
    }
    store.write_collection(REPORT_COLLECTION, collection)?;
    Ok(())
}

fn is_current_report(report: &Value) -> bool {
    report.get("schemaVersion").and_then(Value::as_u64) == Some(AGENT_USAGE_SCHEMA_VERSION as u64)
        && report_generated_at(report).is_some()
}

fn report_generated_at(report: &Value) -> Option<i128> {
    report
        .get("generatedAt")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .map(|value| value.unix_timestamp_nanos())
}

fn sort_reports_by_generated_at(reports: &mut [Value]) {
    reports.sort_by_key(|report| report_generated_at(report).unwrap_or(i128::MIN));
}

fn report_has_agent(report: &Value, agent_id: &str) -> bool {
    report
        .get("agents")
        .and_then(Value::as_array)
        .map(|agents| {
            agents
                .iter()
                .any(|agent| agent.get("agentId").and_then(Value::as_str) == Some(agent_id))
        })
        .unwrap_or(false)
}

fn client_state_store(params: &Value) -> Result<ClientStateStore> {
    if let Some(path) = text_param(params, &["stateRoot"]) {
        if !path.trim().is_empty() {
            return ClientStateStore::new(PathBuf::from(path));
        }
    }
    ClientStateStore::portable()
}

fn traffic_attribution(metered_total_bytes: u64, estimated_historical_bytes: u64) -> &'static str {
    if metered_total_bytes > 0 && estimated_historical_bytes > 0 {
        "mixed"
    } else if metered_total_bytes > 0 {
        "process-metered"
    } else if estimated_historical_bytes > 0 {
        "history-estimated"
    } else {
        "unavailable"
    }
}

fn traffic_confidence(process_confidence: &str, history_confidence: &str) -> &'static str {
    if process_confidence == "high" {
        "high"
    } else if history_confidence == "high" {
        "medium"
    } else if history_confidence == "low" || process_confidence == "medium" {
        "low"
    } else {
        "unavailable"
    }
}

fn account_allowances_for(agent_id: &str, params: &Value) -> Vec<Value> {
    match agent_id {
        "claude-code" => vec![direct_provider_unavailable_allowance(
            "claude-weekly-limit",
            "Claude weekly limit",
            "Claude",
            "week",
            "direct-provider:claude",
            "Native Claude quota lookup is not configured in this build.",
        )],
        "codex" => codex_system_oauth_allowances(params),
        "antigravity" => antigravity_allowances(params),
        "kilo-code" => kilo_allowances(params),
        "opencode" => vec![openrouter_balance_allowance(
            params,
            "model-api-balance",
            "Model API balance",
            "OpenCode",
            "balance",
        )],
        "kimi" => kimi_allowances(params),
        _ => Vec::new(),
    }
}

fn codex_system_oauth_allowances(params: &Value) -> Vec<Value> {
    if !codex_system_auth_allowances_enabled(params) {
        return codex_unavailable_allowances(
            "codex-oauth",
            "System Codex auth quota lookup is disabled for this scan.",
        );
    }

    let auth_path = match resolve_codex_auth_path(params) {
        Some(path) => path,
        None => {
            return codex_unavailable_allowances(
                "codex-oauth",
                "Codex auth.json is not available. Run `codex` once to log in.",
            );
        }
    };
    let (mut credentials, auth_json) = match load_codex_oauth_credentials(&auth_path) {
        Ok(value) => value,
        Err(message) => return codex_unavailable_allowances("codex-oauth", &message),
    };

    let usage_url = resolve_codex_usage_url(params, &auth_path);
    let reset_credits_url =
        resolve_codex_rate_limit_reset_credits_url(params, &auth_path, &usage_url);
    let usage = match fetch_codex_oauth_usage(&usage_url, &credentials) {
        Ok(value) => Ok(value),
        Err(CodexOAuthUsageError::Unauthorized) => {
            match refresh_codex_oauth_credentials(params, &credentials) {
                Ok(refreshed) => {
                    credentials = refreshed;
                    save_codex_oauth_credentials(&auth_path, &auth_json, &credentials).and_then(
                        |_| {
                            fetch_codex_oauth_usage(&usage_url, &credentials)
                                .map_err(|error| error.message())
                        },
                    )
                }
                Err(message) => Err(message),
            }
        }
        Err(error) => Err(error.message()),
    };

    match usage {
        Ok(payload) => {
            let reset_credits =
                fetch_codex_rate_limit_reset_credits(&reset_credits_url, &credentials).ok();
            let allowances = codex_oauth_allowances_from_payload(&payload, reset_credits.as_ref());
            if allowances.is_empty() {
                codex_unavailable_allowances(
                    "codex-oauth",
                    "System Codex usage response did not include quota windows.",
                )
            } else {
                allowances
            }
        }
        Err(message) => codex_unavailable_allowances("codex-oauth", &message),
    }
}

fn codex_unavailable_allowances(source: &str, message: &str) -> Vec<Value> {
    vec![
        unavailable_allowance_with_source(
            "chatgpt-session-limit",
            "ChatGPT session limit",
            "ChatGPT",
            "session",
            source,
            message,
        ),
        unavailable_allowance_with_source(
            "chatgpt-weekly-limit",
            "ChatGPT weekly limit",
            "ChatGPT",
            "week",
            source,
            message,
        ),
        unavailable_allowance_with_source(
            "chatgpt-limit-reset-credits",
            "ChatGPT limit reset credits",
            "ChatGPT",
            "reset-credits",
            source,
            message,
        ),
    ]
}

#[derive(Clone)]
struct AntigravityLocalEndpoint {
    scheme: String,
    port: u16,
    csrf_token: String,
    requires_csrf: bool,
}

struct AntigravityProcessInfo {
    pid: u32,
    csrf_token: String,
    extension_port: Option<u16>,
    extension_csrf_token: Option<String>,
    kind: AntigravityProcessKind,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AntigravityProcessKind {
    App,
    Ide,
    Cli,
}

#[derive(Clone)]
struct AntigravityModelQuota {
    label: String,
    model_id: String,
    remaining_fraction: Option<f64>,
    reset_at: Option<String>,
    reset_description: Option<String>,
}

struct AntigravityOAuthCredentials {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    email: Option<String>,
    project_id: Option<String>,
    client_id: Option<String>,
    client_secret: Option<String>,
    expiry_date_ms: Option<f64>,
    storage: AntigravityOAuthStorage,
}

enum AntigravityOAuthStorage {
    Environment,
    File(PathBuf, Value),
}

fn antigravity_allowances(params: &Value) -> Vec<Value> {
    if !antigravity_allowances_enabled(params) {
        return antigravity_unavailable_allowances(
            "antigravity-native",
            "Native Antigravity quota lookup is disabled for this scan.",
        );
    }

    match antigravity_local_allowances(params) {
        Ok(allowances) if !allowances.is_empty() => return allowances,
        _ => {}
    }

    match antigravity_oauth_allowances(params) {
        Ok(allowances) if !allowances.is_empty() => allowances,
        Ok(_) => antigravity_unavailable_allowances(
            "antigravity-oauth",
            "Antigravity OAuth response did not include usable quota data.",
        ),
        Err(message) => antigravity_unavailable_allowances("antigravity-native", &message),
    }
}

pub fn antigravity_model_catalog(params: &Value) -> Value {
    if let Some(raw) = text_param(params, &["antigravityAvailableModelsJson"]) {
        return match serde_json::from_str::<Value>(&raw) {
            Ok(payload) => antigravity_model_catalog_from_fetch_available_models(
                &payload,
                "antigravity-fixture:fetchAvailableModels",
            ),
            Err(_) => json!({
                "status": "unavailable",
                "source": "antigravity-fixture:fetchAvailableModels",
                "models": [],
                "diagnostics": [{
                    "source": "antigravity-fixture:fetchAvailableModels",
                    "status": "not-parseable"
                }]
            }),
        };
    }

    if bool_param(params, "disableAntigravityModelCatalogLookup").unwrap_or(false) {
        return json!({
            "status": "unavailable",
            "source": "antigravity-oauth:fetchAvailableModels",
            "models": [],
            "diagnostics": [{
                "source": "antigravity-oauth:fetchAvailableModels",
                "status": "disabled"
            }]
        });
    }

    if cfg!(test)
        && text_param(
            params,
            &[
                "antigravityOAuthCredentialsJson",
                "antigravityOAuthCredentialsPath",
                "antigravityOAuthPath",
                "antigravityFetchAvailableModelsUrl",
            ],
        )
        .is_none()
    {
        return json!({
            "status": "unavailable",
            "source": "antigravity-oauth:fetchAvailableModels",
            "models": [],
            "diagnostics": [{
                "source": "antigravity-oauth:fetchAvailableModels",
                "status": "disabled-in-tests"
            }]
        });
    }

    let source = "antigravity-oauth:fetchAvailableModels";
    let result = (|| -> std::result::Result<Vec<AntigravityModelQuota>, String> {
        let mut credentials = load_antigravity_oauth_credentials(params)?;
        if antigravity_oauth_should_refresh(credentials.expiry_date_ms) {
            credentials = refresh_antigravity_oauth_credentials(params, credentials)?;
        }
        let load_response = fetch_antigravity_load_code_assist(params, &credentials.access_token)?;
        let project_id = credentials
            .project_id
            .clone()
            .or_else(|| antigravity_project_id_from_load_response(&load_response));
        fetch_antigravity_remote_model_quotas(params, &credentials.access_token, project_id)
    })();

    match result {
        Ok(models) if !models.is_empty() => antigravity_model_catalog_from_quotas(&models, source),
        Ok(_) => json!({
            "status": "empty",
            "source": source,
            "models": [],
            "diagnostics": [{
                "source": source,
                "status": "empty"
            }]
        }),
        Err(message) => json!({
            "status": "unavailable",
            "source": source,
            "models": [],
            "diagnostics": [{
                "source": source,
                "status": "failed",
                "message": message
            }]
        }),
    }
}

fn antigravity_allowances_enabled(params: &Value) -> bool {
    if bool_param(params, "disableAntigravityAllowanceLookup").unwrap_or(false) {
        return false;
    }
    if bool_param(params, "enableAntigravityAllowanceLookup").unwrap_or(false)
        || text_param(
            params,
            &[
                "antigravityQuotaSummaryJson",
                "antigravityLocalBaseUrl",
                "antigravityOAuthCredentialsJson",
                "antigravityOAuthCredentialsPath",
                "antigravityOAuthPath",
            ],
        )
        .is_some()
    {
        return true;
    }
    if let Some(enabled) = bool_env("LICO_AGENT_USAGE_ANTIGRAVITY_ALLOWANCE") {
        return enabled;
    }
    if cfg!(test) {
        return false;
    }
    true
}

fn antigravity_unavailable_allowances(source: &str, message: &str) -> Vec<Value> {
    vec![
        unavailable_allowance_with_source(
            "antigravity-gemini-5h-limit",
            "Gemini 5-hour limit",
            "Gemini",
            "session",
            source,
            message,
        ),
        unavailable_allowance_with_source(
            "antigravity-gemini-weekly-limit",
            "Gemini weekly limit",
            "Gemini",
            "week",
            source,
            message,
        ),
        unavailable_allowance_with_source(
            "antigravity-claude-gpt-5h-limit",
            "Claude/GPT 5-hour limit",
            "Claude/GPT",
            "session",
            source,
            message,
        ),
        unavailable_allowance_with_source(
            "antigravity-claude-gpt-weekly-limit",
            "Claude/GPT weekly limit",
            "Claude/GPT",
            "week",
            source,
            message,
        ),
    ]
}

fn antigravity_local_allowances(params: &Value) -> std::result::Result<Vec<Value>, String> {
    if let Some(raw) = text_param(params, &["antigravityQuotaSummaryJson"]) {
        let payload = serde_json::from_str::<Value>(&raw)
            .map_err(|_| "Antigravity quota summary fixture is not valid JSON.".to_string())?;
        return antigravity_allowances_from_quota_summary(&payload, "antigravity-local:fixture");
    }

    if let Some(base_url) = text_param(params, &["antigravityLocalBaseUrl"]) {
        let csrf = text_param(params, &["antigravityCsrfToken"]).unwrap_or_default();
        let payload = fetch_antigravity_local_base_url(
            &base_url,
            &csrf,
            ANTIGRAVITY_LOCAL_QUOTA_SUMMARY_PATH,
        )?;
        return antigravity_allowances_from_quota_summary(
            &payload,
            "antigravity-local:quota-summary",
        );
    }

    if cfg!(test) {
        return Err("Antigravity live local quota lookup is disabled in tests.".to_string());
    }
    if bool_param(params, "disableAntigravityLocalAllowance").unwrap_or(false) {
        return Err("Antigravity local quota lookup is disabled for this scan.".to_string());
    }

    let process_infos = detect_antigravity_process_infos()?;
    let mut best: Option<(i32, Vec<Value>)> = None;
    for process_info in process_infos {
        let ports = match antigravity_listening_ports(process_info.pid) {
            Ok(ports) => ports,
            Err(_) => continue,
        };
        for endpoint in antigravity_connection_endpoints(&process_info, &ports) {
            let payload = match fetch_antigravity_local_endpoint(
                &endpoint,
                ANTIGRAVITY_LOCAL_QUOTA_SUMMARY_PATH,
                &json!({"forceRefresh": true}),
            ) {
                Ok(payload) => payload,
                Err(_) => continue,
            };
            let allowances = match antigravity_allowances_from_quota_summary(
                &payload,
                "antigravity-local:quota-summary",
            ) {
                Ok(allowances) => allowances,
                Err(_) => continue,
            };
            let score = antigravity_allowance_score(&allowances);
            if best
                .as_ref()
                .map(|(best_score, _)| score > *best_score)
                .unwrap_or(true)
            {
                best = Some((score, allowances));
            }
        }
    }
    best.map(|(_, allowances)| allowances)
        .ok_or_else(|| "Antigravity local quota summary is not reachable.".to_string())
}

fn fetch_antigravity_local_base_url(
    base_url: &str,
    csrf_token: &str,
    path: &str,
) -> std::result::Result<Value, String> {
    let url = format!("{}{}", trim_trailing_slashes(base_url), path);
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(5))
        .build();
    let body = json!({"forceRefresh": true});
    let mut request = agent
        .post(&url)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .set("Connect-Protocol-Version", "1");
    if !csrf_token.trim().is_empty() {
        request = request.set("X-Codeium-Csrf-Token", csrf_token.trim());
    }
    match request.send_json(body) {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Antigravity local quota summary returned invalid JSON.".to_string()),
        Err(ureq::Error::Status(status, _response)) => Err(format!(
            "Antigravity local quota summary returned HTTP {status}."
        )),
        Err(ureq::Error::Transport(_error)) => {
            Err("Antigravity local quota summary is unreachable.".to_string())
        }
    }
}

fn detect_antigravity_process_infos() -> std::result::Result<Vec<AntigravityProcessInfo>, String> {
    let output = Command::new("/bin/ps")
        .args(["-ax", "-o", "pid=,command="])
        .output()
        .map_err(|_| "Antigravity process scan could not start.".to_string())?;
    if !output.status.success() {
        return Err("Antigravity process scan failed.".to_string());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut saw_tokenless_ide = false;
    let mut results = Vec::new();
    for line in stdout.lines() {
        let Some((pid, command)) = antigravity_process_line(line) else {
            continue;
        };
        let Some(kind) = antigravity_process_kind(&command) else {
            continue;
        };
        let csrf_token = match extract_antigravity_flag("--csrf_token", &command) {
            Some(token) => token,
            None if kind == AntigravityProcessKind::Cli => String::new(),
            None => {
                saw_tokenless_ide = true;
                continue;
            }
        };
        results.push(AntigravityProcessInfo {
            pid,
            csrf_token,
            extension_port: extract_antigravity_flag("--extension_server_port", &command)
                .and_then(|value| value.parse::<u16>().ok()),
            extension_csrf_token: extract_antigravity_flag(
                "--extension_server_csrf_token",
                &command,
            ),
            kind,
        });
    }
    if results.is_empty() {
        if saw_tokenless_ide {
            Err("Antigravity local process is running without a usable CSRF token.".to_string())
        } else {
            Err("Antigravity local process is not running.".to_string())
        }
    } else {
        Ok(results)
    }
}

fn antigravity_process_line(line: &str) -> Option<(u32, String)> {
    let trimmed = line.trim();
    let (pid, command) = trimmed.split_once(char::is_whitespace)?;
    let pid = pid.trim().parse::<u32>().ok()?;
    let command = command.trim().to_string();
    if command.is_empty() {
        None
    } else {
        Some((pid, command))
    }
}

fn antigravity_process_kind(command: &str) -> Option<AntigravityProcessKind> {
    let lower = command.to_ascii_lowercase();
    if is_antigravity_language_server_command(&lower) && is_antigravity_command_line(&lower) {
        if is_antigravity_ide_command_line(&lower) {
            Some(AntigravityProcessKind::Ide)
        } else {
            Some(AntigravityProcessKind::App)
        }
    } else if is_antigravity_cli_command_line(&lower) {
        Some(AntigravityProcessKind::Cli)
    } else {
        None
    }
}

fn is_antigravity_language_server_command(lower: &str) -> bool {
    Regex::new(r"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)")
        .ok()
        .map(|regex| regex.is_match(lower))
        .unwrap_or(false)
}

fn is_antigravity_cli_command_line(lower: &str) -> bool {
    Regex::new(r"(^|[/\\])(antigravity-cli|antigravity_cli)([\s/\\]|$)")
        .ok()
        .map(|regex| regex.is_match(lower))
        .unwrap_or(false)
        || Regex::new(r"(^|[/\\])agy(\s|$)")
            .ok()
            .map(|regex| regex.is_match(lower))
            .unwrap_or(false)
}

fn is_antigravity_command_line(lower: &str) -> bool {
    (lower.contains("--app_data_dir") && lower.contains("antigravity"))
        || lower.contains("antigravity.app/")
        || lower.contains("antigravity.app\\")
        || lower.contains("antigravity ide.app/")
        || lower.contains("antigravity ide.app\\")
        || lower.contains("/antigravity/")
        || lower.contains("\\antigravity\\")
}

fn is_antigravity_ide_command_line(lower: &str) -> bool {
    [
        "antigravity ide.app/",
        "antigravity ide.app\\",
        "--app_data_dir antigravity-ide",
        "--app_data_dir=antigravity-ide",
        "/extensions/antigravity/bin/language_server",
        "\\extensions\\antigravity\\bin\\language_server",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn extract_antigravity_flag(flag: &str, command: &str) -> Option<String> {
    let pattern = format!(r"{}\s*=?\s*([^\s]+)", regex::escape(flag));
    Regex::new(&pattern)
        .ok()?
        .captures(command)
        .and_then(|captures| captures.get(1))
        .map(|value| value.as_str().trim().to_string())
        .filter(|value| !value.is_empty())
}

fn antigravity_listening_ports(pid: u32) -> std::result::Result<Vec<u16>, String> {
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        .into_iter()
        .find(|path| Path::new(path).exists())
        .ok_or_else(|| "lsof is not available for Antigravity local quota lookup.".to_string())?;
    let output = Command::new(lsof)
        .args(["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", &pid.to_string()])
        .output()
        .map_err(|_| "Antigravity listening port scan could not start.".to_string())?;
    if !output.status.success() {
        return Err("Antigravity listening ports were not found.".to_string());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let regex = Regex::new(r":(\d+)\s+\(LISTEN\)")
        .map_err(|_| "Antigravity listening port parser could not initialize.".to_string())?;
    let mut ports = BTreeSet::<u16>::new();
    for captures in regex.captures_iter(&stdout) {
        if let Some(port) = captures
            .get(1)
            .and_then(|value| value.as_str().parse::<u16>().ok())
        {
            ports.insert(port);
        }
    }
    if ports.is_empty() {
        Err("Antigravity listening ports were not found.".to_string())
    } else {
        Ok(ports.into_iter().collect())
    }
}

fn antigravity_connection_endpoints(
    process_info: &AntigravityProcessInfo,
    ports: &[u16],
) -> Vec<AntigravityLocalEndpoint> {
    let mut endpoints = Vec::<AntigravityLocalEndpoint>::new();
    for port in ports {
        endpoints.push(AntigravityLocalEndpoint {
            scheme: "https".to_string(),
            port: *port,
            csrf_token: process_info.csrf_token.clone(),
            requires_csrf: process_info.kind != AntigravityProcessKind::Cli,
        });
    }
    if let Some(port) = process_info.extension_port {
        if let Some(token) = process_info.extension_csrf_token.as_deref() {
            endpoints.push(AntigravityLocalEndpoint {
                scheme: "http".to_string(),
                port,
                csrf_token: token.to_string(),
                requires_csrf: true,
            });
        }
        if process_info.extension_csrf_token.as_deref() != Some(process_info.csrf_token.as_str()) {
            endpoints.push(AntigravityLocalEndpoint {
                scheme: "http".to_string(),
                port,
                csrf_token: process_info.csrf_token.clone(),
                requires_csrf: true,
            });
        }
    }
    endpoints
}

fn fetch_antigravity_local_endpoint(
    endpoint: &AntigravityLocalEndpoint,
    path: &str,
    body: &Value,
) -> std::result::Result<Value, String> {
    let curl = [
        "/usr/bin/curl",
        concat!("/", "opt", "/homebrew/bin/curl"),
        "/usr/local/bin/curl",
    ]
    .into_iter()
    .find(|path| Path::new(path).exists())
    .ok_or_else(|| "curl is not available for Antigravity local HTTPS lookup.".to_string())?;
    let url = format!("{}://127.0.0.1:{}{}", endpoint.scheme, endpoint.port, path);
    let body_text = body.to_string();
    let mut command = Command::new(curl);
    command.args([
        "-sS",
        "-k",
        "--max-time",
        "5",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Accept: application/json",
        "-H",
        "Connect-Protocol-Version: 1",
        "--data",
        &body_text,
        &url,
    ]);
    if endpoint.requires_csrf {
        command.args([
            "-H",
            &format!("X-Codeium-Csrf-Token: {}", endpoint.csrf_token),
        ]);
    }
    let output = command
        .output()
        .map_err(|_| "Antigravity local quota request could not start.".to_string())?;
    if !output.status.success() {
        return Err("Antigravity local quota request failed.".to_string());
    }
    serde_json::from_slice::<Value>(&output.stdout)
        .map_err(|_| "Antigravity local quota response was not valid JSON.".to_string())
}

fn antigravity_allowance_score(allowances: &[Value]) -> i32 {
    allowances.iter().fold(0_i32, |score, allowance| {
        let available = allowance.get("status").and_then(Value::as_str) == Some("available");
        let has_percent = text_field(allowance, &["value"])
            .map(|value| value.ends_with('%'))
            .unwrap_or(false);
        score + if available && has_percent { 10 } else { 1 }
    })
}

fn antigravity_allowances_from_quota_summary(
    payload: &Value,
    source: &str,
) -> std::result::Result<Vec<Value>, String> {
    if let Some(code) = payload.get("code") {
        let ok = code
            .as_i64()
            .map(|value| value == 0)
            .or_else(|| {
                code.as_str().map(|value| {
                    matches!(
                        value.trim().to_ascii_lowercase().as_str(),
                        "0" | "ok" | "success"
                    )
                })
            })
            .unwrap_or(true);
        if !ok {
            return Err("Antigravity quota summary returned an error code.".to_string());
        }
    }

    let summary = child_any(payload, &["response", "summary"]).unwrap_or(payload);
    let groups = summary
        .get("groups")
        .and_then(Value::as_array)
        .ok_or_else(|| "Antigravity quota summary did not include quota groups.".to_string())?;
    let mut group_items = groups
        .iter()
        .enumerate()
        .filter_map(|(index, group)| {
            let buckets = group.get("buckets").and_then(Value::as_array)?;
            if buckets.is_empty() {
                return None;
            }
            Some((index, group))
        })
        .collect::<Vec<_>>();
    group_items.sort_by_key(|(index, group)| (antigravity_quota_group_sort_rank(group), *index));

    let mut allowances = Vec::<Value>::new();
    for (_group_index, group) in group_items {
        let group_title = antigravity_quota_group_title(group);
        let mut buckets = group
            .get("buckets")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .enumerate()
            .collect::<Vec<_>>();
        buckets.sort_by_key(|(index, bucket)| (antigravity_quota_bucket_sort_rank(bucket), *index));
        for (_bucket_index, bucket) in buckets {
            let Some(bucket_id) = text_field(bucket, &["bucketId", "bucket_id"]) else {
                continue;
            };
            allowances.push(antigravity_allowance_from_quota_bucket(
                &group_title,
                &bucket_id,
                bucket,
                source,
            ));
        }
    }
    if allowances.is_empty() {
        Err("Antigravity quota summary did not include usable quota buckets.".to_string())
    } else {
        Ok(allowances)
    }
}

fn antigravity_allowance_from_quota_bucket(
    group_title: &str,
    bucket_id: &str,
    bucket: &Value,
    source: &str,
) -> Value {
    let bucket_title = antigravity_quota_bucket_title(bucket);
    let bucket_kind = antigravity_quota_bucket_kind(bucket_id, &bucket_title);
    let kind = antigravity_quota_allowance_kind(group_title, bucket_id, bucket_kind);
    let period = match bucket_kind {
        AntigravityQuotaBucketKind::Session => "session",
        AntigravityQuotaBucketKind::Weekly => "week",
        AntigravityQuotaBucketKind::Other => "quota",
    };
    let provider = if group_title.eq_ignore_ascii_case("claude/gpt") {
        "Claude/GPT"
    } else if group_title.eq_ignore_ascii_case("gemini") {
        "Gemini"
    } else {
        group_title
    };
    let label = format!("{group_title} {bucket_title}");
    let disabled = bucket
        .get("disabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let remaining =
        antigravity_quota_remaining_fraction(bucket).map(|value| (value * 100.0).clamp(0.0, 100.0));
    let status = if disabled || remaining.is_none() {
        "unavailable"
    } else if remaining.unwrap_or(0.0) <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    let reset_at = text_field(bucket, &["resetTime", "reset_time"]).unwrap_or_default();
    let reset_description = text_field(bucket, &["description", "resetDescription"]);
    let message = match reset_description.as_deref() {
        Some(text) if !text.is_empty() => format!("{label} quota · {text}"),
        _ => format!("{label} quota."),
    };
    let window_seconds = match bucket_kind {
        AntigravityQuotaBucketKind::Session => Some(300_u64 * 60),
        AntigravityQuotaBucketKind::Weekly => Some(7_u64 * 24 * 60 * 60),
        AntigravityQuotaBucketKind::Other => None,
    };
    json!({
        "kind": kind,
        "label": label,
        "provider": provider,
        "period": period,
        "status": status,
        "value": remaining.map(|value| format!("{}%", format_number(value))).unwrap_or_default(),
        "unit": "",
        "source": source,
        "message": message,
        "usedPercent": remaining.map(|value| 100.0 - value),
        "remainingPercent": remaining,
        "resetAt": reset_at,
        "resetsIn": reset_description.clone().unwrap_or_default(),
        "resetDescription": reset_description.unwrap_or_default(),
        "windowSeconds": window_seconds
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AntigravityQuotaBucketKind {
    Session,
    Weekly,
    Other,
}

fn antigravity_quota_group_sort_rank(group: &Value) -> u8 {
    let title = antigravity_quota_group_raw_title(group).to_ascii_lowercase();
    if title.contains("gemini") {
        0
    } else if title.contains("claude") || title.contains("gpt") {
        1
    } else {
        2
    }
}

fn antigravity_quota_bucket_sort_rank(bucket: &Value) -> u8 {
    let bucket_id = text_field(bucket, &["bucketId", "bucket_id"]).unwrap_or_default();
    let title = antigravity_quota_bucket_title(bucket);
    match antigravity_quota_bucket_kind(&bucket_id, &title) {
        AntigravityQuotaBucketKind::Session => 0,
        AntigravityQuotaBucketKind::Weekly => 1,
        AntigravityQuotaBucketKind::Other => 2,
    }
}

fn antigravity_quota_group_title(group: &Value) -> String {
    let title = antigravity_quota_group_raw_title(group);
    let lower = title.to_ascii_lowercase();
    if lower.contains("gemini") {
        "Gemini".to_string()
    } else if lower.contains("claude") || lower.contains("gpt") {
        "Claude/GPT".to_string()
    } else if title.is_empty() {
        "Quota".to_string()
    } else {
        title
    }
}

fn antigravity_quota_group_raw_title(group: &Value) -> String {
    text_field(group, &["displayName", "display_name"]).unwrap_or_default()
}

fn antigravity_quota_bucket_title(bucket: &Value) -> String {
    let bucket_id = text_field(bucket, &["bucketId", "bucket_id"]).unwrap_or_default();
    let display_name =
        text_field(bucket, &["displayName", "display_name"]).unwrap_or_else(|| bucket_id.clone());
    match antigravity_quota_bucket_kind(&bucket_id, &display_name) {
        AntigravityQuotaBucketKind::Session => "5-hour".to_string(),
        AntigravityQuotaBucketKind::Weekly => "weekly".to_string(),
        AntigravityQuotaBucketKind::Other => display_name,
    }
}

fn antigravity_quota_bucket_kind(
    bucket_id: &str,
    display_name: &str,
) -> AntigravityQuotaBucketKind {
    let combined = format!("{bucket_id} {display_name}").to_ascii_lowercase();
    if combined.contains("5h") || combined.contains("5-hour") || combined.contains("five hour") {
        AntigravityQuotaBucketKind::Session
    } else if combined.contains("weekly") {
        AntigravityQuotaBucketKind::Weekly
    } else {
        AntigravityQuotaBucketKind::Other
    }
}

fn antigravity_quota_allowance_kind(
    group_title: &str,
    bucket_id: &str,
    bucket_kind: AntigravityQuotaBucketKind,
) -> String {
    let group = group_title.to_ascii_lowercase();
    match (group.as_str(), bucket_kind) {
        ("gemini", AntigravityQuotaBucketKind::Session) => {
            "antigravity-gemini-5h-limit".to_string()
        }
        ("gemini", AntigravityQuotaBucketKind::Weekly) => {
            "antigravity-gemini-weekly-limit".to_string()
        }
        ("claude/gpt", AntigravityQuotaBucketKind::Session) => {
            "antigravity-claude-gpt-5h-limit".to_string()
        }
        ("claude/gpt", AntigravityQuotaBucketKind::Weekly) => {
            "antigravity-claude-gpt-weekly-limit".to_string()
        }
        _ => format!("antigravity-quota-summary-{}", slugify(bucket_id)),
    }
}

fn antigravity_quota_remaining_fraction(bucket: &Value) -> Option<f64> {
    f64_field(bucket, &["remainingFraction", "remaining_fraction"]).or_else(|| {
        let remaining = bucket.get("remaining")?;
        f64_field(remaining, &["remainingFraction", "remaining_fraction"]).or_else(|| {
            let oneof = text_field(remaining, &["case"]);
            if oneof.as_deref() == Some("remainingFraction") {
                f64_field(remaining, &["value"])
            } else {
                None
            }
        })
    })
}

fn antigravity_oauth_allowances(params: &Value) -> std::result::Result<Vec<Value>, String> {
    if cfg!(test)
        && text_param(
            params,
            &[
                "antigravityOAuthCredentialsJson",
                "antigravityOAuthCredentialsPath",
                "antigravityOAuthPath",
                "antigravityFetchAvailableModelsUrl",
            ],
        )
        .is_none()
    {
        return Err("Antigravity OAuth lookup is disabled in tests.".to_string());
    }
    if bool_param(params, "disableAntigravityOAuthAllowance").unwrap_or(false) {
        return Err("Antigravity OAuth quota lookup is disabled for this scan.".to_string());
    }

    let mut credentials = load_antigravity_oauth_credentials(params)?;
    if antigravity_oauth_should_refresh(credentials.expiry_date_ms) {
        credentials = refresh_antigravity_oauth_credentials(params, credentials)?;
    }

    let load_response = fetch_antigravity_load_code_assist(params, &credentials.access_token)?;
    let project_id = credentials
        .project_id
        .clone()
        .or_else(|| antigravity_project_id_from_load_response(&load_response));
    let models =
        fetch_antigravity_remote_model_quotas(params, &credentials.access_token, project_id)?;
    let allowances = antigravity_allowances_from_model_quotas(&models, "antigravity-oauth:remote");
    if allowances.is_empty() {
        Err("Antigravity OAuth response did not include usable quota models.".to_string())
    } else {
        Ok(allowances)
    }
}

fn load_antigravity_oauth_credentials(
    params: &Value,
) -> std::result::Result<AntigravityOAuthCredentials, String> {
    if let Some(raw) = text_param(params, &["antigravityOAuthCredentialsJson"])
        .or_else(|| env_text("ANTIGRAVITY_OAUTH_CREDENTIALS_JSON"))
    {
        let payload = serde_json::from_str::<Value>(&raw)
            .map_err(|_| "Antigravity OAuth credentials JSON is invalid.".to_string())?;
        return parse_antigravity_oauth_credentials(payload, AntigravityOAuthStorage::Environment);
    }

    let path = resolve_antigravity_oauth_credentials_path(params)
        .ok_or_else(|| "Antigravity OAuth credentials were not found.".to_string())?;
    let data =
        fs::read(&path).map_err(|_| "Antigravity OAuth credentials were not found.".to_string())?;
    let payload = serde_json::from_slice::<Value>(&data)
        .map_err(|_| "Antigravity OAuth credentials file is not valid JSON.".to_string())?;
    parse_antigravity_oauth_credentials(
        payload.clone(),
        AntigravityOAuthStorage::File(path, payload),
    )
}

fn resolve_antigravity_oauth_credentials_path(params: &Value) -> Option<PathBuf> {
    if let Some(path) = text_param(
        params,
        &["antigravityOAuthCredentialsPath", "antigravityOAuthPath"],
    ) {
        return Some(PathBuf::from(path));
    }
    if let Some(path) = env_text("LICO_ANTIGRAVITY_OAUTH_CREDENTIALS_PATH") {
        return Some(PathBuf::from(path));
    }
    if let Some(path) = env_text("ANTIGRAVITY_OAUTH_CREDENTIALS_PATH") {
        return Some(PathBuf::from(path));
    }
    None
}

fn parse_antigravity_oauth_credentials(
    payload: Value,
    storage: AntigravityOAuthStorage,
) -> std::result::Result<AntigravityOAuthCredentials, String> {
    let access_token = text_field(&payload, &["access_token", "accessToken"])
        .ok_or_else(|| "Antigravity OAuth access token is missing.".to_string())?;
    Ok(AntigravityOAuthCredentials {
        access_token,
        refresh_token: text_field(&payload, &["refresh_token", "refreshToken"]),
        id_token: text_field(&payload, &["id_token", "idToken"]),
        email: text_field(&payload, &["email"]),
        project_id: text_field(&payload, &["project_id", "projectId"]),
        client_id: text_field(&payload, &["client_id", "clientId"]),
        client_secret: text_field(&payload, &["client_secret", "clientSecret"]),
        expiry_date_ms: f64_field(&payload, &["expiry_date", "expiresAt"]),
        storage,
    })
}

fn antigravity_oauth_should_refresh(expiry_date_ms: Option<f64>) -> bool {
    let Some(expiry_date_ms) = expiry_date_ms else {
        return false;
    };
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        * 1000.0;
    expiry_date_ms - now_ms <= 60_000.0
}

fn refresh_antigravity_oauth_credentials(
    params: &Value,
    mut credentials: AntigravityOAuthCredentials,
) -> std::result::Result<AntigravityOAuthCredentials, String> {
    let refresh_token = credentials.refresh_token.clone().ok_or_else(|| {
        "Antigravity OAuth access token is expired and no refresh token is available.".to_string()
    })?;
    let client_id = credentials
        .client_id
        .clone()
        .or_else(|| env_text("ANTIGRAVITY_OAUTH_CLIENT_ID"))
        .ok_or_else(|| "Antigravity OAuth client id is not configured for refresh.".to_string())?;
    let client_secret = credentials
        .client_secret
        .clone()
        .or_else(|| env_text("ANTIGRAVITY_OAUTH_CLIENT_SECRET"))
        .ok_or_else(|| {
            "Antigravity OAuth client secret is not configured for refresh.".to_string()
        })?;
    let token_url = text_param(params, &["antigravityOAuthTokenUrl"])
        .or_else(|| env_text("LICO_ANTIGRAVITY_OAUTH_TOKEN_URL"))
        .unwrap_or_else(|| ANTIGRAVITY_OAUTH_TOKEN_URL.to_string());
    let body = form_urlencoded(&[
        ("client_id", client_id.as_str()),
        ("client_secret", client_secret.as_str()),
        ("refresh_token", refresh_token.as_str()),
        ("grant_type", "refresh_token"),
    ]);
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    let payload = match agent
        .post(&token_url)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .set("Accept", "application/json")
        .send_string(&body)
    {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Antigravity OAuth refresh response was not valid JSON.".to_string())?,
        Err(ureq::Error::Status(401 | 403, _response)) => {
            return Err("Antigravity OAuth refresh token was rejected.".to_string());
        }
        Err(ureq::Error::Status(_status, _response)) => {
            return Err("Antigravity OAuth refresh endpoint rejected the request.".to_string());
        }
        Err(ureq::Error::Transport(_error)) => {
            return Err("Antigravity OAuth refresh endpoint is unreachable.".to_string());
        }
    };

    credentials.access_token =
        text_field(&payload, &["access_token", "accessToken"]).unwrap_or(credentials.access_token);
    credentials.refresh_token =
        text_field(&payload, &["refresh_token", "refreshToken"]).or(credentials.refresh_token);
    credentials.id_token = text_field(&payload, &["id_token", "idToken"]).or(credentials.id_token);
    if let Some(expires_in) = f64_field(&payload, &["expires_in", "expiresIn"]) {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64()
            * 1000.0;
        credentials.expiry_date_ms = Some(now_ms + expires_in * 1000.0);
    }
    persist_antigravity_oauth_credentials(&credentials)?;
    Ok(credentials)
}

fn persist_antigravity_oauth_credentials(
    credentials: &AntigravityOAuthCredentials,
) -> std::result::Result<(), String> {
    let AntigravityOAuthStorage::File(path, existing) = &credentials.storage else {
        return Ok(());
    };
    let mut root = existing.clone();
    if !root.is_object() {
        root = json!({});
    }
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| "Antigravity OAuth credentials could not be updated.".to_string())?;
    root_object.insert(
        "access_token".to_string(),
        Value::String(credentials.access_token.clone()),
    );
    if let Some(refresh_token) = credentials.refresh_token.as_deref() {
        root_object.insert(
            "refresh_token".to_string(),
            Value::String(refresh_token.to_string()),
        );
    }
    if let Some(id_token) = credentials.id_token.as_deref() {
        root_object.insert("id_token".to_string(), Value::String(id_token.to_string()));
    }
    if let Some(email) = credentials.email.as_deref() {
        root_object.insert("email".to_string(), Value::String(email.to_string()));
    }
    if let Some(project_id) = credentials.project_id.as_deref() {
        root_object.insert(
            "project_id".to_string(),
            Value::String(project_id.to_string()),
        );
    }
    if let Some(client_id) = credentials.client_id.as_deref() {
        root_object.insert(
            "client_id".to_string(),
            Value::String(client_id.to_string()),
        );
    }
    if let Some(client_secret) = credentials.client_secret.as_deref() {
        root_object.insert(
            "client_secret".to_string(),
            Value::String(client_secret.to_string()),
        );
    }
    if let Some(expiry_date_ms) = credentials.expiry_date_ms {
        if let Some(number) = serde_json::Number::from_f64(expiry_date_ms) {
            root_object.insert("expiry_date".to_string(), Value::Number(number));
        }
    }
    let data = serde_json::to_vec_pretty(&root)
        .map_err(|_| "Antigravity OAuth credentials could not be serialized.".to_string())?;
    write_private_json_file_with_message(
        path,
        &data,
        "Antigravity OAuth credentials could not be updated.",
    )
}

fn fetch_antigravity_load_code_assist(
    params: &Value,
    access_token: &str,
) -> std::result::Result<Value, String> {
    let url = text_param(params, &["antigravityLoadCodeAssistUrl"])
        .unwrap_or_else(|| format!("{ANTIGRAVITY_REMOTE_BASE_URL}/v1internal:loadCodeAssist"));
    antigravity_remote_post_json(
        &url,
        access_token,
        &json!({
            "metadata": {
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            }
        }),
    )
}

fn fetch_antigravity_remote_model_quotas(
    params: &Value,
    access_token: &str,
    project_id: Option<String>,
) -> std::result::Result<Vec<AntigravityModelQuota>, String> {
    let url = text_param(params, &["antigravityFetchAvailableModelsUrl"]).unwrap_or_else(|| {
        format!("{ANTIGRAVITY_REMOTE_BASE_URL}/v1internal:fetchAvailableModels")
    });
    let body = project_id
        .as_deref()
        .map(|project| json!({"project": project}))
        .unwrap_or_else(|| json!({}));
    let response = antigravity_remote_post_json(&url, access_token, &body)?;
    let mut quotas = antigravity_model_quotas_from_fetch_available_models(&response);
    if !quotas.is_empty()
        && quotas
            .iter()
            .all(|quota| quota.remaining_fraction.unwrap_or(0.0) >= 0.999)
    {
        if let Ok(verified) =
            fetch_antigravity_remote_quota_buckets(params, access_token, project_id)
        {
            if verified
                .iter()
                .any(|quota| quota.remaining_fraction.is_some())
            {
                quotas = merge_antigravity_verified_quotas(quotas, verified);
            }
        }
    }
    Ok(quotas)
}

fn fetch_antigravity_remote_quota_buckets(
    params: &Value,
    access_token: &str,
    project_id: Option<String>,
) -> std::result::Result<Vec<AntigravityModelQuota>, String> {
    let url = text_param(params, &["antigravityRetrieveUserQuotaUrl"])
        .unwrap_or_else(|| format!("{ANTIGRAVITY_REMOTE_BASE_URL}/v1internal:retrieveUserQuota"));
    let body = project_id
        .as_deref()
        .map(|project| json!({"project": project}))
        .unwrap_or_else(|| json!({}));
    let response = antigravity_remote_post_json(&url, access_token, &body)?;
    Ok(antigravity_model_quotas_from_quota_buckets(&response))
}

fn antigravity_remote_post_json(
    url: &str,
    access_token: &str,
    body: &Value,
) -> std::result::Result<Value, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    match agent
        .post(url)
        .set("Authorization", &format!("Bearer {access_token}"))
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .set("User-Agent", "antigravity")
        .send_json(body.clone())
    {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Antigravity remote API returned invalid JSON.".to_string()),
        Err(ureq::Error::Status(401, _response)) => {
            Err("Antigravity OAuth credentials were rejected.".to_string())
        }
        Err(ureq::Error::Status(403, _response)) => {
            Err("Antigravity remote quota API denied access.".to_string())
        }
        Err(ureq::Error::Status(status, _response)) => Err(format!(
            "Antigravity remote quota API returned HTTP {status}."
        )),
        Err(ureq::Error::Transport(_error)) => {
            Err("Antigravity remote quota API is unreachable.".to_string())
        }
    }
}

fn antigravity_project_id_from_load_response(payload: &Value) -> Option<String> {
    match payload.get("cloudaicompanionProject") {
        Some(Value::String(value)) => {
            Some(value.trim().to_string()).filter(|value| !value.is_empty())
        }
        Some(Value::Object(_)) => nested(payload, &["cloudaicompanionProject", "id"])
            .or_else(|| nested(payload, &["cloudaicompanionProject", "projectId"]))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        _ => None,
    }
}

fn antigravity_model_quotas_from_fetch_available_models(
    payload: &Value,
) -> Vec<AntigravityModelQuota> {
    let Some(models) = payload.get("models").and_then(Value::as_object) else {
        return Vec::new();
    };
    models
        .iter()
        .filter_map(|(model_id, model)| {
            let quota_info = model.get("quotaInfo").or_else(|| model.get("quota_info"))?;
            let label = text_field(model, &["displayName", "display_name", "label"])
                .unwrap_or_else(|| model_id.to_string());
            Some(AntigravityModelQuota {
                label,
                model_id: model_id.to_string(),
                remaining_fraction: f64_field(
                    quota_info,
                    &["remainingFraction", "remaining_fraction"],
                ),
                reset_at: text_field(quota_info, &["resetTime", "reset_time"]),
                reset_description: None,
            })
        })
        .collect()
}

fn antigravity_model_catalog_from_fetch_available_models(payload: &Value, source: &str) -> Value {
    let quotas = antigravity_model_quotas_from_fetch_available_models(payload);
    antigravity_model_catalog_from_quotas(&quotas, source)
}

fn antigravity_model_catalog_from_quotas(quotas: &[AntigravityModelQuota], source: &str) -> Value {
    let mut seen = BTreeSet::<String>::new();
    let models = quotas
        .iter()
        .filter_map(|quota| {
            let name = quota.label.trim();
            if name.is_empty() || !seen.insert(name.to_ascii_lowercase()) {
                return None;
            }
            Some(json!({
                "name": name,
                "id": quota.model_id.as_str(),
                "provider": "",
                "source": source,
                "sources": [source],
                "reasoningEfforts": []
            }))
        })
        .collect::<Vec<_>>();
    json!({
        "status": if models.is_empty() { "empty" } else { "available" },
        "source": source,
        "models": models,
        "diagnostics": []
    })
}

fn antigravity_model_quotas_from_quota_buckets(payload: &Value) -> Vec<AntigravityModelQuota> {
    let Some(buckets) = payload.get("buckets").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut by_model = BTreeMap::<String, AntigravityModelQuota>::new();
    for bucket in buckets {
        let Some(model_id) = text_field(bucket, &["modelId", "model_id"]) else {
            continue;
        };
        let quota = AntigravityModelQuota {
            label: model_id.clone(),
            model_id: model_id.clone(),
            remaining_fraction: f64_field(bucket, &["remainingFraction", "remaining_fraction"]),
            reset_at: text_field(bucket, &["resetTime", "reset_time"]),
            reset_description: None,
        };
        match by_model.get(&model_id) {
            Some(existing)
                if existing.remaining_fraction.unwrap_or(f64::MAX)
                    <= quota.remaining_fraction.unwrap_or(f64::MAX) => {}
            _ => {
                by_model.insert(model_id, quota);
            }
        }
    }
    by_model.into_values().collect()
}

fn merge_antigravity_verified_quotas(
    model_quotas: Vec<AntigravityModelQuota>,
    verified_quotas: Vec<AntigravityModelQuota>,
) -> Vec<AntigravityModelQuota> {
    let mut verified_by_id = verified_quotas
        .into_iter()
        .map(|quota| (quota.model_id.to_ascii_lowercase(), quota))
        .collect::<BTreeMap<_, _>>();
    let mut merged = Vec::<AntigravityModelQuota>::new();
    for model_quota in model_quotas {
        let key = model_quota.model_id.to_ascii_lowercase();
        if let Some(verified) = verified_by_id.remove(&key) {
            merged.push(AntigravityModelQuota {
                label: model_quota.label,
                model_id: model_quota.model_id,
                remaining_fraction: verified
                    .remaining_fraction
                    .or(model_quota.remaining_fraction),
                reset_at: verified.reset_at.or(model_quota.reset_at),
                reset_description: verified.reset_description.or(model_quota.reset_description),
            });
        }
    }
    merged.extend(verified_by_id.into_values());
    merged
}

fn antigravity_allowances_from_model_quotas(
    quotas: &[AntigravityModelQuota],
    source: &str,
) -> Vec<Value> {
    let gemini = antigravity_representative_model_quota(quotas, AntigravityModelPool::Gemini);
    let claude_gpt =
        antigravity_representative_model_quota(quotas, AntigravityModelPool::ClaudeGpt);
    let mut allowances = Vec::<Value>::new();
    if let Some(quota) = gemini {
        allowances.push(antigravity_allowance_from_model_quota(
            quota,
            "antigravity-gemini-model-limit",
            "Gemini model limit",
            "Gemini",
            source,
        ));
    }
    if let Some(quota) = claude_gpt {
        allowances.push(antigravity_allowance_from_model_quota(
            quota,
            "antigravity-claude-gpt-model-limit",
            "Claude/GPT model limit",
            "Claude/GPT",
            source,
        ));
    }
    allowances
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AntigravityModelPool {
    Gemini,
    ClaudeGpt,
}

fn antigravity_representative_model_quota(
    quotas: &[AntigravityModelQuota],
    pool: AntigravityModelPool,
) -> Option<&AntigravityModelQuota> {
    quotas
        .iter()
        .filter(|quota| quota.remaining_fraction.is_some())
        .filter(|quota| antigravity_model_pool(quota) == Some(pool))
        .min_by(|left, right| {
            let left_remaining = left.remaining_fraction.unwrap_or(1.0);
            let right_remaining = right.remaining_fraction.unwrap_or(1.0);
            left_remaining
                .partial_cmp(&right_remaining)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| left.label.cmp(&right.label))
        })
}

fn antigravity_model_pool(quota: &AntigravityModelQuota) -> Option<AntigravityModelPool> {
    let combined = format!("{} {}", quota.model_id, quota.label).to_ascii_lowercase();
    if combined.contains("claude") || combined.contains("gpt") || combined.contains("openai") {
        Some(AntigravityModelPool::ClaudeGpt)
    } else if combined.contains("gemini")
        && (combined.contains("pro") || combined.contains("flash"))
    {
        Some(AntigravityModelPool::Gemini)
    } else {
        None
    }
}

fn antigravity_allowance_from_model_quota(
    quota: &AntigravityModelQuota,
    kind: &str,
    label: &str,
    provider: &str,
    source: &str,
) -> Value {
    let remaining = quota
        .remaining_fraction
        .map(|value| (value * 100.0).clamp(0.0, 100.0));
    let status = if remaining.unwrap_or(0.0) <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    let reset = quota
        .reset_description
        .clone()
        .or_else(|| quota.reset_at.clone())
        .unwrap_or_default();
    json!({
        "kind": kind,
        "label": label,
        "provider": provider,
        "period": "quota",
        "status": status,
        "value": remaining.map(|value| format!("{}%", format_number(value))).unwrap_or_default(),
        "unit": "",
        "source": source,
        "message": if reset.is_empty() {
            format!("{label} from Antigravity remote model quota.")
        } else {
            format!("{label} from Antigravity remote model quota · {reset}")
        },
        "usedPercent": remaining.map(|value| 100.0 - value),
        "remainingPercent": remaining,
        "resetAt": quota.reset_at.clone().unwrap_or_default(),
        "resetsIn": quota.reset_description.clone().unwrap_or_default()
    })
}

fn form_urlencoded(values: &[(&str, &str)]) -> String {
    values
        .iter()
        .map(|(key, value)| {
            format!(
                "{}={}",
                form_urlencode_component(key),
                form_urlencode_component(value)
            )
        })
        .collect::<Vec<_>>()
        .join("&")
}

fn form_urlencode_component(value: &str) -> String {
    let mut out = String::new();
    for byte in value.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            b' ' => out.push('+'),
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

fn direct_provider_unavailable_allowance(
    kind: &str,
    label: &str,
    provider: &str,
    period: &str,
    source: &str,
    message: &str,
) -> Value {
    unavailable_allowance_with_source(kind, label, provider, period, source, message)
}

fn openrouter_balance_allowance(
    params: &Value,
    kind: &str,
    label: &str,
    provider: &str,
    period: &str,
) -> Value {
    let Some(api_key) = text_param(
        params,
        &["openRouterApiKey", "openrouterApiKey", "opencodeApiKey"],
    )
    .or_else(|| env_text("OPENROUTER_API_KEY")) else {
        return direct_provider_unavailable_allowance(
            kind,
            label,
            provider,
            period,
            "direct-provider:openrouter",
            "OpenRouter API key is not configured for native balance lookup.",
        );
    };
    let base_url = text_param(params, &["openRouterBaseUrl", "openrouterBaseUrl"])
        .or_else(|| env_text("OPENROUTER_API_BASE_URL"))
        .unwrap_or_else(|| OPENROUTER_DEFAULT_API_BASE_URL.to_string());
    let url = format!("{}/credits", trim_trailing_slashes(&base_url));
    let payload = match fetch_bearer_json(&url, &api_key, "LicoArc", None) {
        Ok(payload) => payload,
        Err(message) => {
            return direct_provider_unavailable_allowance(
                kind,
                label,
                provider,
                period,
                "direct-provider:openrouter",
                &message,
            );
        }
    };
    let Some(data) = payload.get("data") else {
        return direct_provider_unavailable_allowance(
            kind,
            label,
            provider,
            period,
            "direct-provider:openrouter",
            "OpenRouter balance response did not include credit data.",
        );
    };
    let total = f64_field(data, &["total_credits", "totalCredits"]).unwrap_or(0.0);
    let used = f64_field(data, &["total_usage", "totalUsage"]).unwrap_or(0.0);
    let remaining = (total - used).max(0.0);
    balance_allowance_value(
        kind,
        label,
        provider,
        period,
        remaining,
        "USD credits",
        "direct-provider:openrouter",
        "OpenRouter credit balance.",
    )
}

fn kilo_allowances(params: &Value) -> Vec<Value> {
    let Some(token) = resolve_kilo_bearer_token(params) else {
        return kilo_unavailable_allowances(
            "Kilo API key or CLI auth is not configured for native balance lookup.",
        );
    };
    let base_url = text_param(params, &["kiloBaseUrl", "kiloApiBaseUrl"])
        .or_else(|| env_text("KILO_API_BASE_URL"))
        .unwrap_or_else(|| KILO_DEFAULT_API_BASE_URL.to_string());
    let payload = match fetch_kilo_usage_json(&base_url, &token) {
        Ok(payload) => payload,
        Err(message) => {
            return kilo_unavailable_allowances(&message);
        }
    };
    let pass_payload = kilo_payload_at(&payload, 1);
    let credit_payload = kilo_payload_at(&payload, 0);
    vec![
        kilo_pass_allowance(pass_payload).unwrap_or_else(|| {
            direct_provider_unavailable_allowance(
                "kilo-pass-limit",
                "Kilo Pass",
                "Kilo Pass",
                "month",
                "direct-provider:kilo",
                "Kilo balance response did not include Kilo Pass usage data.",
            )
        }),
        kilo_recharge_credits_allowance(credit_payload).unwrap_or_else(|| {
            direct_provider_unavailable_allowance(
                "kilo-recharge-credits",
                "Recharge credits",
                "Kilo",
                "balance",
                "direct-provider:kilo",
                "Kilo balance response did not include recharge credit data.",
            )
        }),
    ]
}

fn kilo_unavailable_allowances(message: &str) -> Vec<Value> {
    vec![
        direct_provider_unavailable_allowance(
            "kilo-pass-limit",
            "Kilo Pass",
            "Kilo Pass",
            "month",
            "direct-provider:kilo",
            message,
        ),
        direct_provider_unavailable_allowance(
            "kilo-recharge-credits",
            "Recharge credits",
            "Kilo",
            "balance",
            "direct-provider:kilo",
            message,
        ),
    ]
}

fn kimi_allowances(params: &Value) -> Vec<Value> {
    let Some(api_key) = text_param(params, &["kimiApiKey", "moonshotApiKey"])
        .or_else(|| env_text("KIMI_API_KEY"))
        .or_else(|| env_text("MOONSHOT_API_KEY"))
    else {
        return kimi_unavailable_allowances(
            "Kimi API key is not configured for native balance lookup.",
        );
    };
    let base_url = text_param(params, &["kimiBaseUrl", "moonshotBaseUrl"])
        .or_else(|| env_text("KIMI_API_BASE_URL"))
        .or_else(|| env_text("MOONSHOT_API_BASE_URL"))
        .unwrap_or_else(|| KIMI_DEFAULT_API_BASE_URL.to_string());
    let url = format!("{}/users/me/balance", trim_trailing_slashes(&base_url));
    let payload = match fetch_bearer_json(&url, &api_key, "LicoArc", None) {
        Ok(payload) => payload,
        Err(message) => return kimi_unavailable_allowances(&message),
    };
    let Some(data) = payload.get("data") else {
        return kimi_unavailable_allowances("Kimi balance response did not include account data.");
    };
    let mut allowances = Vec::<Value>::new();
    if let Some(available) = f64_field(data, &["available_balance"]) {
        let status = if available > 0.0 {
            "available"
        } else {
            "exhausted"
        };
        allowances.push(json!({
            "kind": "kimi-available-balance",
            "label": "Available balance",
            "provider": "Kimi",
            "period": "balance",
            "status": status,
            "value": format_number(available),
            "unit": "credits",
            "source": "direct-provider:kimi",
            "message": "Kimi account available balance."
        }));
    }
    if let Some(cash) = f64_field(data, &["cash_balance"]) {
        let status = if cash > 0.0 { "available" } else { "exhausted" };
        allowances.push(json!({
            "kind": "kimi-cash-balance",
            "label": "Cash balance",
            "provider": "Kimi",
            "period": "balance",
            "status": status,
            "value": format_number(cash),
            "unit": "credits",
            "source": "direct-provider:kimi",
            "message": "Kimi cash balance."
        }));
    }
    if let Some(voucher) = f64_field(data, &["voucher_balance"]) {
        let status = if voucher > 0.0 {
            "available"
        } else {
            "exhausted"
        };
        allowances.push(json!({
            "kind": "kimi-voucher-balance",
            "label": "Voucher balance",
            "provider": "Kimi",
            "period": "balance",
            "status": status,
            "value": format_number(voucher),
            "unit": "credits",
            "source": "direct-provider:kimi",
            "message": "Kimi voucher balance."
        }));
    }
    if allowances.is_empty() {
        return kimi_unavailable_allowances(
            "Kimi balance response did not include any balance fields.",
        );
    }
    allowances
}

fn kimi_unavailable_allowances(message: &str) -> Vec<Value> {
    vec![direct_provider_unavailable_allowance(
        "kimi-available-balance",
        "Available balance",
        "Kimi",
        "balance",
        "direct-provider:kimi",
        message,
    )]
}

fn kilo_pass_allowance(payload: Option<&Value>) -> Option<Value> {
    let usage = kilo_pass_usage(payload?)?;
    let total = (usage.base + usage.bonus).max(0.0);
    let remaining = (total - usage.used).max(0.0);
    let remaining_percent = if total > 0.0 {
        (remaining / total * 100.0).clamp(0.0, 100.0)
    } else {
        0.0
    };
    let status = if remaining <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    let message = if usage.bonus > 0.0 {
        format!(
            "Kilo Pass · ${} / ${} (+ ${} bonus).",
            format_currency(usage.used),
            format_currency(usage.base),
            format_currency(usage.bonus)
        )
    } else {
        format!(
            "Kilo Pass · ${} / ${}.",
            format_currency(usage.used),
            format_currency(usage.base)
        )
    };
    Some(json!({
        "kind": "kilo-pass-limit",
        "label": "Kilo Pass",
        "provider": "Kilo Pass",
        "period": "month",
        "status": status,
        "value": format!("{}%", format_number(remaining_percent)),
        "unit": "",
        "source": "direct-provider:kilo",
        "message": message,
        "usedUsd": usage.used,
        "baseUsd": usage.base,
        "bonusUsd": usage.bonus,
        "remainingUsd": remaining,
        "remainingPercent": remaining_percent
    }))
}

fn kilo_recharge_credits_allowance(payload: Option<&Value>) -> Option<Value> {
    let credits = kilo_recharge_credits(payload?)?;
    let status = if credits.remaining <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    let message = if let Some(total) = credits.total {
        format!(
            "Kilo recharge credits · {} / {} credits.",
            format_currency(credits.remaining),
            format_currency(total)
        )
    } else {
        format!(
            "Kilo recharge credits · {} credits.",
            format_currency(credits.remaining)
        )
    };
    Some(json!({
        "kind": "kilo-recharge-credits",
        "label": "Recharge credits",
        "provider": "Kilo",
        "period": "balance",
        "status": status,
        "value": format_currency(credits.remaining),
        "unit": "credits",
        "source": "direct-provider:kilo",
        "message": message,
        "remainingCredits": credits.remaining,
        "totalCredits": credits.total
    }))
}

fn balance_allowance_value(
    kind: &str,
    label: &str,
    provider: &str,
    period: &str,
    value: f64,
    unit: &str,
    source: &str,
    message: &str,
) -> Value {
    let status = if value <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    json!({
        "kind": kind,
        "label": label,
        "provider": provider,
        "period": period,
        "status": status,
        "value": format!("${}", format_currency(value)),
        "unit": unit,
        "source": source,
        "message": message
    })
}

fn env_text(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn trim_trailing_slashes(value: &str) -> String {
    let mut trimmed = value.trim().to_string();
    while trimmed.ends_with('/') {
        trimmed.pop();
    }
    trimmed
}

fn fetch_bearer_json(
    url: &str,
    token: &str,
    user_agent: &str,
    extra_header: Option<(&str, &str)>,
) -> std::result::Result<Value, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    let mut request = agent
        .get(url)
        .set("Authorization", &format!("Bearer {token}"))
        .set("User-Agent", user_agent)
        .set("Accept", "application/json");
    if let Some((name, value)) = extra_header {
        request = request.set(name, value);
    }
    match request.call() {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Native provider balance endpoint returned invalid JSON.".to_string()),
        Err(ureq::Error::Status(401 | 403, _response)) => {
            Err("Native provider credentials were rejected.".to_string())
        }
        Err(ureq::Error::Status(status, _response)) => Err(format!(
            "Native provider balance endpoint returned HTTP {status}."
        )),
        Err(ureq::Error::Transport(_error)) => {
            Err("Native provider balance endpoint is unreachable.".to_string())
        }
    }
}

fn resolve_kilo_bearer_token(params: &Value) -> Option<String> {
    text_param(params, &["kiloApiKey", "kiloToken"])
        .or_else(|| env_text("KILO_API_KEY"))
        .or_else(|| load_kilo_cli_token(params))
}

fn load_kilo_cli_token(params: &Value) -> Option<String> {
    let auth_path = text_param(params, &["kiloAuthPath"])
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .map(|home| home.join(".local/share/kilo/auth.json"))
        })?;
    let data = fs::read(auth_path).ok()?;
    let parsed = serde_json::from_slice::<Value>(&data).ok()?;
    nested(&parsed, &["kilo", "access"])
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn fetch_kilo_usage_json(base_url: &str, token: &str) -> std::result::Result<Value, String> {
    let endpoint = format!(
        "{}/{}",
        trim_trailing_slashes(base_url),
        KILO_TRPC_PROCEDURES.join(",")
    );
    let input = json!({
        "0": {"json": null},
        "1": {"json": null},
        "2": {"json": null}
    })
    .to_string();
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    let response = agent
        .get(&endpoint)
        .query("batch", "1")
        .query("input", &input)
        .set("Authorization", &format!("Bearer {token}"))
        .set("User-Agent", "LicoArc")
        .set("Accept", "application/json")
        .call();
    match response {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Kilo balance endpoint returned invalid JSON.".to_string()),
        Err(ureq::Error::Status(401 | 403, _response)) => {
            Err("Kilo credentials were rejected.".to_string())
        }
        Err(ureq::Error::Status(404, _response)) => {
            Err("Kilo balance endpoint was not found.".to_string())
        }
        Err(ureq::Error::Status(status, _response)) => {
            Err(format!("Kilo balance endpoint returned HTTP {status}."))
        }
        Err(ureq::Error::Transport(_error)) => {
            Err("Kilo balance endpoint is unreachable.".to_string())
        }
    }
}

fn kilo_payload_at(payload: &Value, index: usize) -> Option<&Value> {
    let entry = payload
        .as_array()
        .and_then(|items| items.get(index))
        .or_else(|| payload.get(index.to_string()))?;
    nested(entry, &["result", "data", "json"])
        .or_else(|| nested(entry, &["result", "json"]))
        .or_else(|| nested(entry, &["result", "data"]))
}

struct KiloPassUsage {
    used: f64,
    base: f64,
    bonus: f64,
}

struct KiloRechargeCredits {
    remaining: f64,
    total: Option<f64>,
}

fn kilo_recharge_credits(payload: &Value) -> Option<KiloRechargeCredits> {
    if let Some(blocks) = find_array_by_key(payload, "creditBlocks") {
        let mut total = 0.0;
        let mut remaining = 0.0;
        let mut saw_remaining = false;
        for block in blocks {
            if let Some(amount) = f64_field(block, &["amount_mUsd", "amountMUsd"]) {
                total += amount / 1_000_000.0;
            }
            if let Some(balance) = f64_field(block, &["balance_mUsd", "balanceMUsd"]) {
                remaining += balance / 1_000_000.0;
                saw_remaining = true;
            }
        }
        if saw_remaining {
            return Some(KiloRechargeCredits {
                remaining: remaining.max(0.0),
                total: if total > 0.0 { Some(total) } else { None },
            });
        }
        if total > 0.0 {
            return Some(KiloRechargeCredits {
                remaining: total.max(0.0),
                total: Some(total.max(0.0)),
            });
        }
    }
    extract_balance(payload).map(|(value, _unit)| KiloRechargeCredits {
        remaining: value.max(0.0),
        total: None,
    })
}

fn kilo_pass_usage(payload: &Value) -> Option<KiloPassUsage> {
    let subscription = payload
        .get("subscription")
        .filter(|value| value.is_object())
        .unwrap_or(payload);
    let used = f64_field(subscription, &["currentPeriodUsageUsd", "used", "usage"]);
    let base = f64_field(
        subscription,
        &["currentPeriodBaseCreditsUsd", "baseCredits"],
    );
    let bonus = f64_field(
        subscription,
        &["currentPeriodBonusCreditsUsd", "bonusCredits"],
    )
    .unwrap_or(0.0);
    let total = base.map(|value| value + bonus).or_else(|| {
        f64_field(
            subscription,
            &["total", "creditsTotal", "totalCredits", "limit"],
        )
    });
    let remaining = f64_field(
        subscription,
        &["remaining", "creditsRemaining", "remainingCredits"],
    );
    let total = total.or_else(|| {
        remaining
            .zip(used)
            .map(|(remaining, used)| remaining + used)
    });
    let total = total?;
    if total <= 0.0 {
        return None;
    }
    let used = used
        .or_else(|| remaining.map(|remaining| (total - remaining).max(0.0)))
        .unwrap_or(0.0);
    let base = base.unwrap_or((total - bonus).max(0.0));
    Some(KiloPassUsage {
        used: used.max(0.0),
        base,
        bonus,
    })
}

fn find_array_by_key<'a>(value: &'a Value, key: &str) -> Option<&'a Vec<Value>> {
    if let Some(array) = value.get(key).and_then(Value::as_array) {
        return Some(array);
    }
    if let Some(object) = value.as_object() {
        for child in object.values() {
            if let Some(array) = find_array_by_key(child, key) {
                return Some(array);
            }
        }
    }
    if let Some(array) = value.as_array() {
        for child in array {
            if let Some(found) = find_array_by_key(child, key) {
                return Some(found);
            }
        }
    }
    None
}

fn format_currency(value: f64) -> String {
    format!("{:.2}", value.max(0.0))
}

fn allowance_from_rate_window(
    kind: &str,
    label: &str,
    provider: &str,
    period: &str,
    source: &str,
    window: &Value,
) -> Value {
    let used = f64_field(window, &["usedPercent", "used_percent"]).unwrap_or(100.0);
    let remaining = (100.0 - used).clamp(0.0, 100.0);
    let reset = reset_text_from_rate_window(window);
    let reset_at = reset_at_text_from_rate_window(window);
    let reset_after_seconds = number_field(window, &["resetAfterSeconds", "reset_after_seconds"]);
    let window_seconds = number_field(window, &["limitWindowSeconds", "limit_window_seconds"]);
    let message = if reset.is_empty() {
        format!("{provider} quota window.")
    } else {
        format!("{provider} quota window · {reset}")
    };
    let status = if remaining <= 0.0 {
        "exhausted"
    } else {
        "available"
    };
    json!({
        "kind": kind,
        "label": label,
        "provider": provider,
        "period": period,
        "status": status,
        "value": format!("{}%", format_number(remaining)),
        "unit": "",
        "source": source,
        "message": message,
        "usedPercent": used,
        "remainingPercent": remaining,
        "resetAt": reset_at,
        "resetAfterSeconds": reset_after_seconds,
        "resetsIn": reset,
        "windowSeconds": window_seconds
    })
}

fn reset_text_from_rate_window(window: &Value) -> String {
    if let Some(text) = text_field(window, &["resetDescription", "resetsIn", "resets_in"]) {
        return text;
    }
    if let Some(seconds) = number_field(window, &["resetAfterSeconds", "reset_after_seconds"]) {
        return format!("resets in {}", format_duration_short(seconds));
    }
    reset_at_text_from_rate_window(window)
}

fn reset_at_text_from_rate_window(window: &Value) -> String {
    if let Some(text) = text_field(window, &["resetsAt", "resetAt", "reset_at"]) {
        return text;
    }
    let Some(raw) = number_field(window, &["resetAt", "reset_at"]) else {
        return String::new();
    };
    let seconds = epoch_seconds(raw);
    OffsetDateTime::from_unix_timestamp(seconds as i64)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok())
        .unwrap_or_default()
}

fn epoch_seconds(value: u64) -> u64 {
    if value > 20_000_000_000 {
        value / 1000
    } else {
        value
    }
}

fn format_duration_short(seconds: u64) -> String {
    let days = seconds / 86_400;
    let hours = (seconds % 86_400) / 3_600;
    let minutes = (seconds % 3_600) / 60;
    if days > 0 {
        if hours > 0 {
            format!("{days}d {hours}h")
        } else {
            format!("{days}d")
        }
    } else if hours > 0 {
        if minutes > 0 {
            format!("{hours}h {minutes}m")
        } else {
            format!("{hours}h")
        }
    } else {
        format!("{minutes}m")
    }
}

struct CodexOAuthCredentials {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    account_id: Option<String>,
}

enum CodexOAuthUsageError {
    Unauthorized,
    Message(String),
}

impl CodexOAuthUsageError {
    fn message(self) -> String {
        match self {
            CodexOAuthUsageError::Unauthorized => {
                "System Codex access token is not authorized.".to_string()
            }
            CodexOAuthUsageError::Message(message) => message,
        }
    }
}

fn codex_system_auth_allowances_enabled(params: &Value) -> bool {
    if bool_param(params, "disableCodexSystemAuthAllowance").unwrap_or(false) {
        return false;
    }
    if bool_param(params, "enableCodexSystemAuthAllowance").unwrap_or(false)
        || text_param(params, &["codexAuthPath", "codexHome", "codexUsageUrl"]).is_some()
    {
        return true;
    }
    if let Some(enabled) = bool_env("LICO_AGENT_USAGE_CODEX_SYSTEM_AUTH") {
        return enabled;
    }
    if cfg!(test) {
        return false;
    }
    true
}

fn bool_env(key: &str) -> Option<bool> {
    std::env::var(key)
        .ok()
        .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        })
}

fn resolve_codex_auth_path(params: &Value) -> Option<PathBuf> {
    if let Some(path) = text_param(params, &["codexAuthPath"]) {
        return Some(PathBuf::from(path));
    }
    if let Ok(path) = std::env::var("LICO_CODEX_AUTH_PATH") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }
    resolve_codex_home(params).map(|home| home.join("auth.json"))
}

fn resolve_codex_home(params: &Value) -> Option<PathBuf> {
    if let Some(path) = text_param(params, &["codexHome"]) {
        return Some(PathBuf::from(path));
    }
    if let Ok(path) = std::env::var("CODEX_HOME") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(".codex"))
}

fn load_codex_oauth_credentials(
    auth_path: &Path,
) -> std::result::Result<(CodexOAuthCredentials, Value), String> {
    let data = fs::read(auth_path)
        .map_err(|_| "Codex auth.json is not available. Run `codex` once to log in.".to_string())?;
    let auth_json = serde_json::from_slice::<Value>(&data)
        .map_err(|_| "Codex auth.json is not valid JSON.".to_string())?;
    let tokens = match auth_json.get("tokens").and_then(Value::as_object) {
        Some(tokens) => tokens,
        None => {
            if text_field(&auth_json, &["OPENAI_API_KEY"]).is_some() {
                return Err(
                    "System Codex auth is an API key, not ChatGPT OAuth credentials.".to_string(),
                );
            }
            return Err("Codex OAuth tokens are missing from auth.json.".to_string());
        }
    };
    let access_token = token_text(tokens, &["access_token", "accessToken"])
        .ok_or_else(|| "Codex OAuth access token is missing from auth.json.".to_string())?;
    let refresh_token = token_text(tokens, &["refresh_token", "refreshToken"]);
    let id_token = token_text(tokens, &["id_token", "idToken"]);
    let account_id = token_text(tokens, &["account_id", "accountId"]);
    Ok((
        CodexOAuthCredentials {
            access_token,
            refresh_token,
            id_token,
            account_id,
        },
        auth_json,
    ))
}

fn token_text(tokens: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| tokens.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn resolve_codex_usage_url(params: &Value, auth_path: &Path) -> String {
    if let Some(url) = text_param(params, &["codexUsageUrl"]) {
        return url;
    }
    if let Ok(url) = std::env::var("LICO_CODEX_USAGE_URL") {
        let trimmed = url.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    let base = text_param(params, &["codexChatGptBaseUrl"])
        .or_else(|| {
            std::env::var("LICO_CODEX_CHATGPT_BASE_URL")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .or_else(|| codex_chatgpt_base_url_from_config(params, auth_path))
        .unwrap_or_else(|| CODEX_DEFAULT_CHATGPT_BASE_URL.to_string());
    codex_usage_url_from_base(&base)
}

fn codex_chatgpt_base_url_from_config(params: &Value, auth_path: &Path) -> Option<String> {
    let config_home = text_param(params, &["codexHome"])
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var("CODEX_HOME")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| auth_path.parent().map(Path::to_path_buf))?;
    let contents = fs::read_to_string(config_home.join("config.toml")).ok()?;
    let parsed = contents.parse::<toml::Value>().ok()?;
    parsed
        .get("chatgpt_base_url")
        .and_then(toml::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn codex_usage_url_from_base(base: &str) -> String {
    let mut normalized = base.trim().to_string();
    if normalized.is_empty() {
        normalized = CODEX_DEFAULT_CHATGPT_BASE_URL.to_string();
    }
    while normalized.ends_with('/') {
        normalized.pop();
    }
    if (normalized.starts_with("https://chatgpt.com")
        || normalized.starts_with("https://chat.openai.com"))
        && !normalized.contains("/backend-api")
    {
        normalized.push_str("/backend-api");
    }
    let path = if normalized.contains("/backend-api") {
        "/wham/usage"
    } else {
        "/api/codex/usage"
    };
    format!("{normalized}{path}")
}

fn resolve_codex_rate_limit_reset_credits_url(
    params: &Value,
    auth_path: &Path,
    usage_url: &str,
) -> String {
    if let Some(url) = text_param(params, &["codexRateLimitResetCreditsUrl"]) {
        return url;
    }
    if let Ok(url) = std::env::var("LICO_CODEX_RATE_LIMIT_RESET_CREDITS_URL") {
        let trimmed = url.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    if let Some(prefix) = usage_url.strip_suffix("/wham/usage") {
        return format!("{prefix}/wham/rate-limit-reset-credits");
    }
    if let Some(prefix) = usage_url.strip_suffix("/api/codex/usage") {
        return format!("{prefix}/wham/rate-limit-reset-credits");
    }
    let base = text_param(params, &["codexChatGptBaseUrl"])
        .or_else(|| {
            std::env::var("LICO_CODEX_CHATGPT_BASE_URL")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .or_else(|| codex_chatgpt_base_url_from_config(params, auth_path))
        .unwrap_or_else(|| CODEX_DEFAULT_CHATGPT_BASE_URL.to_string());
    codex_rate_limit_reset_credits_url_from_base(&base)
}

fn codex_rate_limit_reset_credits_url_from_base(base: &str) -> String {
    let mut normalized = base.trim().to_string();
    if normalized.is_empty() {
        normalized = CODEX_DEFAULT_CHATGPT_BASE_URL.to_string();
    }
    while normalized.ends_with('/') {
        normalized.pop();
    }
    if (normalized.starts_with("https://chatgpt.com")
        || normalized.starts_with("https://chat.openai.com"))
        && !normalized.contains("/backend-api")
    {
        normalized.push_str("/backend-api");
    }
    format!("{normalized}/wham/rate-limit-reset-credits")
}

fn fetch_codex_oauth_usage(
    usage_url: &str,
    credentials: &CodexOAuthCredentials,
) -> std::result::Result<Value, CodexOAuthUsageError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    let mut request = agent
        .get(usage_url)
        .set(
            "Authorization",
            &format!("Bearer {}", credentials.access_token),
        )
        .set("User-Agent", "LicoArc")
        .set("Accept", "application/json");
    if let Some(account_id) = credentials.account_id.as_deref() {
        request = request.set("ChatGPT-Account-Id", account_id);
    }
    match request.call() {
        Ok(response) => response.into_json::<Value>().map_err(|_| {
            CodexOAuthUsageError::Message(
                "System Codex usage endpoint returned invalid JSON.".to_string(),
            )
        }),
        Err(ureq::Error::Status(401 | 403, _response)) => Err(CodexOAuthUsageError::Unauthorized),
        Err(ureq::Error::Status(status, _response)) => Err(CodexOAuthUsageError::Message(format!(
            "System Codex usage endpoint returned HTTP {status}."
        ))),
        Err(ureq::Error::Transport(_error)) => Err(CodexOAuthUsageError::Message(
            "System Codex usage endpoint is unreachable.".to_string(),
        )),
    }
}

fn fetch_codex_rate_limit_reset_credits(
    url: &str,
    credentials: &CodexOAuthCredentials,
) -> std::result::Result<Value, CodexOAuthUsageError> {
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(4))
        .build();
    let mut request = agent
        .get(url)
        .set(
            "Authorization",
            &format!("Bearer {}", credentials.access_token),
        )
        .set("User-Agent", "LicoArc")
        .set("Accept", "application/json")
        .set("OpenAI-Beta", "codex-1")
        .set("originator", "Codex Desktop");
    if let Some(account_id) = credentials.account_id.as_deref() {
        request = request.set("ChatGPT-Account-ID", account_id);
    }
    match request.call() {
        Ok(response) => response.into_json::<Value>().map_err(|_| {
            CodexOAuthUsageError::Message(
                "System Codex reset credits endpoint returned invalid JSON.".to_string(),
            )
        }),
        Err(ureq::Error::Status(401 | 403, _response)) => Err(CodexOAuthUsageError::Unauthorized),
        Err(ureq::Error::Status(status, _response)) => Err(CodexOAuthUsageError::Message(format!(
            "System Codex reset credits endpoint returned HTTP {status}."
        ))),
        Err(ureq::Error::Transport(_error)) => Err(CodexOAuthUsageError::Message(
            "System Codex reset credits endpoint is unreachable.".to_string(),
        )),
    }
}

fn refresh_codex_oauth_credentials(
    params: &Value,
    credentials: &CodexOAuthCredentials,
) -> std::result::Result<CodexOAuthCredentials, String> {
    let refresh_token = credentials.refresh_token.as_deref().ok_or_else(|| {
        "System Codex access token is expired and no refresh token is available.".to_string()
    })?;
    let refresh_url = text_param(params, &["codexOAuthRefreshUrl"])
        .or_else(|| {
            std::env::var("LICO_CODEX_OAUTH_REFRESH_URL")
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(|| CODEX_OAUTH_REFRESH_URL.to_string());
    let agent = ureq::AgentBuilder::new()
        .timeout(StdDuration::from_secs(10))
        .build();
    let response = agent
        .post(&refresh_url)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_json(json!({
            "client_id": CODEX_OAUTH_CLIENT_ID,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "scope": "openid profile email"
        }));
    let payload = match response {
        Ok(response) => response
            .into_json::<Value>()
            .map_err(|_| "Codex OAuth refresh endpoint returned invalid JSON.".to_string())?,
        Err(ureq::Error::Status(401, _response)) => {
            return Err(
                "Codex OAuth refresh token is expired. Run `codex` to log in again.".to_string(),
            );
        }
        Err(ureq::Error::Status(_status, _response)) => {
            return Err("Codex OAuth refresh endpoint rejected the refresh request.".to_string());
        }
        Err(ureq::Error::Transport(_error)) => {
            return Err("Codex OAuth refresh endpoint is unreachable.".to_string());
        }
    };
    let access_token = text_field(&payload, &["access_token", "accessToken"])
        .unwrap_or_else(|| credentials.access_token.clone());
    if access_token.is_empty() {
        return Err("Codex OAuth refresh response did not include an access token.".to_string());
    }
    let refresh_token = text_field(&payload, &["refresh_token", "refreshToken"])
        .or_else(|| credentials.refresh_token.clone());
    let id_token =
        text_field(&payload, &["id_token", "idToken"]).or_else(|| credentials.id_token.clone());
    Ok(CodexOAuthCredentials {
        access_token,
        refresh_token,
        id_token,
        account_id: credentials.account_id.clone(),
    })
}

fn save_codex_oauth_credentials(
    auth_path: &Path,
    existing: &Value,
    credentials: &CodexOAuthCredentials,
) -> std::result::Result<(), String> {
    let mut root = existing.clone();
    if !root.is_object() {
        root = json!({});
    }
    let root_object = root
        .as_object_mut()
        .ok_or_else(|| "Codex auth.json could not be updated.".to_string())?;
    let mut tokens = serde_json::Map::<String, Value>::new();
    tokens.insert(
        "access_token".to_string(),
        Value::String(credentials.access_token.clone()),
    );
    if let Some(refresh_token) = credentials.refresh_token.as_deref() {
        tokens.insert(
            "refresh_token".to_string(),
            Value::String(refresh_token.to_string()),
        );
    }
    if let Some(id_token) = credentials.id_token.as_deref() {
        tokens.insert("id_token".to_string(), Value::String(id_token.to_string()));
    }
    if let Some(account_id) = credentials.account_id.as_deref() {
        tokens.insert(
            "account_id".to_string(),
            Value::String(account_id.to_string()),
        );
    }
    root_object.insert("tokens".to_string(), Value::Object(tokens));
    root_object.insert(
        "last_refresh".to_string(),
        Value::String(timestamp_rfc3339()),
    );
    let data = serde_json::to_vec_pretty(&root)
        .map_err(|_| "Codex auth.json could not be serialized.".to_string())?;
    write_private_json_file(auth_path, &data)
}

fn write_private_json_file(path: &Path, data: &[u8]) -> std::result::Result<(), String> {
    write_private_json_file_with_message(path, data, "Codex auth.json could not be updated.")
}

fn write_private_json_file_with_message(
    path: &Path,
    data: &[u8],
    message: &str,
) -> std::result::Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{message} Location is invalid."))?;
    fs::create_dir_all(parent)
        .map_err(|_| format!("{message} Directory could not be prepared."))?;
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("auth.json");
    let staged = parent.join(format!(".{file_name}.lico-staged-{}", Uuid::new_v4()));
    let write_result = (|| -> std::io::Result<()> {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options.open(&staged)?;
        file.write_all(data)?;
        file.sync_all()?;
        fs::rename(&staged, path)?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&staged);
    }
    write_result.map_err(|_| message.to_string())
}

fn codex_oauth_allowances_from_payload(
    payload: &Value,
    reset_credits_payload: Option<&Value>,
) -> Vec<Value> {
    let mut allowances = Vec::<Value>::new();
    if let Some(rate_limit) = child_any(payload, &["rate_limit", "rateLimit"]) {
        push_codex_rate_limit_allowances(
            &mut allowances,
            rate_limit,
            "chatgpt",
            "ChatGPT",
            "ChatGPT",
        );
    }
    if let Some(available_count) = reset_credits_payload
        .and_then(codex_reset_credit_available_count)
        .or_else(|| codex_reset_credit_available_count(payload))
    {
        allowances.push(codex_reset_credit_allowance(available_count));
    }
    if let Some(additional) =
        array_field(payload, &["additional_rate_limits", "additionalRateLimits"])
    {
        for item in additional {
            let Some(rate_limit) = child_any(item, &["rate_limit", "rateLimit"]) else {
                continue;
            };
            let name = text_field(item, &["limit_name", "limitName"])
                .or_else(|| text_field(item, &["metered_feature", "meteredFeature"]))
                .unwrap_or_else(|| "Codex".to_string());
            let slug = slugify(&name);
            if slug.is_empty() {
                continue;
            }
            push_codex_rate_limit_allowances(&mut allowances, rate_limit, &slug, &name, &name);
        }
    }
    allowances
}

fn codex_reset_credit_available_count(payload: &Value) -> Option<u64> {
    nested(payload, &["rate_limit_reset_credits", "available_count"])
        .and_then(number_value)
        .or_else(|| {
            nested(payload, &["rateLimitResetCredits", "availableCount"]).and_then(number_value)
        })
        .or_else(|| payload.get("available_count").and_then(number_value))
        .or_else(|| payload.get("availableCount").and_then(number_value))
}

fn push_codex_rate_limit_allowances(
    allowances: &mut Vec<Value>,
    rate_limit: &Value,
    kind_prefix: &str,
    label_prefix: &str,
    provider: &str,
) {
    let start_len = allowances.len();
    if let Some(window) = child_any(rate_limit, &["primary_window", "primaryWindow"]) {
        allowances.push(allowance_from_rate_window(
            &format!("{kind_prefix}-session-limit"),
            &format!("{label_prefix} session limit"),
            provider,
            "session",
            "codex-oauth:system",
            window,
        ));
    }
    if let Some(window) = child_any(rate_limit, &["secondary_window", "secondaryWindow"])
        .filter(|window| looks_codex_oauth_weekly_window(window))
        .or_else(|| child_any(rate_limit, &["weekly_window", "weeklyWindow"]))
    {
        allowances.push(allowance_from_rate_window(
            &format!("{kind_prefix}-weekly-limit"),
            &format!("{label_prefix} weekly limit"),
            provider,
            "week",
            "codex-oauth:system",
            window,
        ));
    }
    if allowances.len() == start_len {
        if let Some(window) = rate_limit_windows(rate_limit)
            .into_iter()
            .find(|window| f64_field(window, &["usedPercent", "used_percent"]).is_some())
        {
            allowances.push(allowance_from_rate_window(
                &format!("{kind_prefix}-quota-limit"),
                &format!("{label_prefix} quota limit"),
                provider,
                "quota",
                "codex-oauth:system",
                window,
            ));
        }
    }
}

fn codex_reset_credit_allowance(available_count: u64) -> Value {
    let status = if available_count > 0 {
        "available"
    } else {
        "exhausted"
    };
    json!({
        "kind": "chatgpt-limit-reset-credits",
        "label": "ChatGPT limit reset credits",
        "provider": "ChatGPT",
        "period": "reset-credits",
        "status": status,
        "value": format!("{available_count} available"),
        "unit": "",
        "source": "codex-oauth:system",
        "message": format!("ChatGPT limit reset credits · {available_count} available."),
        "availableCount": available_count
    })
}

fn rate_limit_windows(rate_limit: &Value) -> Vec<&Value> {
    [
        "primary_window",
        "primaryWindow",
        "secondary_window",
        "secondaryWindow",
        "weekly_window",
        "weeklyWindow",
        "tertiary_window",
        "tertiaryWindow",
    ]
    .into_iter()
    .filter_map(|key| rate_limit.get(key))
    .collect()
}

fn looks_codex_oauth_weekly_window(window: &Value) -> bool {
    let seconds = f64_field(window, &["limit_window_seconds", "limitWindowSeconds"]).unwrap_or(0.0);
    if seconds >= 6.5 * 24.0 * 60.0 * 60.0 {
        return true;
    }
    looks_weekly_window(window)
}

fn child_any<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

fn array_field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Vec<Value>> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_array))
}

fn slugify(value: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash && !out.is_empty() {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

fn looks_weekly_window(window: &Value) -> bool {
    let minutes = f64_field(window, &["windowMinutes"]).unwrap_or(0.0);
    if minutes >= 6.5 * 24.0 * 60.0 {
        return true;
    }
    text_field(window, &["resetDescription"])
        .map(|value| value.to_lowercase().contains("week"))
        .unwrap_or(false)
}

fn extract_balance(item: &Value) -> Option<(f64, String)> {
    for path in [
        &["credits", "remaining"][..],
        &["openaiDashboard", "creditsRemaining"][..],
        &["usage", "creditsRemaining"][..],
        &["usage", "creditBalance"][..],
        &["usage", "balance"][..],
    ] {
        if let Some(value) = nested(item, path).and_then(f64_value) {
            return Some((value, "credits".to_string()));
        }
    }
    find_balance_number(item).map(|value| (value, "credits".to_string()))
}

fn find_balance_number(value: &Value) -> Option<f64> {
    let object = value.as_object()?;
    for (key, child) in object {
        let key_lower = key.to_lowercase();
        if matches!(
            key_lower.as_str(),
            "creditsremaining" | "creditbalance" | "balance" | "remaining"
        ) {
            if let Some(number) = f64_value(child) {
                return Some(number);
            }
        }
        if (key_lower.contains("credit") || key_lower.contains("balance"))
            && let Some(number) = first_number(child)
        {
            return Some(number);
        }
    }
    for child in object.values() {
        if let Some(number) = find_balance_number(child) {
            return Some(number);
        }
    }
    None
}

fn first_number(value: &Value) -> Option<f64> {
    if let Some(number) = f64_value(value) {
        return Some(number);
    }
    if let Some(object) = value.as_object() {
        for child in object.values() {
            if let Some(number) = first_number(child) {
                return Some(number);
            }
        }
    }
    if let Some(array) = value.as_array() {
        for child in array {
            if let Some(number) = first_number(child) {
                return Some(number);
            }
        }
    }
    None
}

fn nested<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut current = value;
    for key in path {
        current = current.get(*key)?;
    }
    Some(current)
}

fn format_number(value: f64) -> String {
    if (value.fract()).abs() < 0.05 {
        format!("{}", value.round() as i64)
    } else {
        format!("{value:.1}")
    }
}

fn unavailable_allowance_with_source(
    kind: &str,
    label: &str,
    provider: &str,
    period: &str,
    source: &str,
    message: &str,
) -> Value {
    json!({
        "kind": kind,
        "label": label,
        "provider": provider,
        "period": period,
        "status": "unavailable",
        "value": "",
        "unit": "",
        "source": source,
        "message": message
    })
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn expand_user_path(value: &str) -> PathBuf {
    let trimmed = value.trim();
    if trimmed == "~" {
        return default_home_dir();
    }
    if let Some(rest) = trimmed
        .strip_prefix("~/")
        .or_else(|| trimmed.strip_prefix("~\\"))
    {
        return default_home_dir().join(rest);
    }
    PathBuf::from(trimmed)
}

fn default_home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .or_else(|| directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn text_field(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn number_field(value: &Value, keys: &[&str]) -> Option<u64> {
    let object = value.as_object()?;
    for key in keys {
        if let Some(number) = object.get(*key).and_then(number_value) {
            return Some(number);
        }
    }
    None
}

fn f64_field(value: &Value, keys: &[&str]) -> Option<f64> {
    let object = value.as_object()?;
    for key in keys {
        if let Some(number) = object.get(*key).and_then(f64_value) {
            return Some(number);
        }
    }
    None
}

fn u64_param(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(number_value)
}

fn i64_param(params: &Value, key: &str) -> Option<i64> {
    let value = params.get(key)?;
    value
        .as_i64()
        .or_else(|| value.as_str()?.trim().parse::<i64>().ok())
}

fn bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| {
        value.as_bool().or_else(|| {
            value.as_str().and_then(|text| {
                let normalized = text.trim().to_ascii_lowercase();
                match normalized.as_str() {
                    "1" | "true" | "yes" | "on" => Some(true),
                    "0" | "false" | "no" | "off" => Some(false),
                    _ => None,
                }
            })
        })
    })
}

fn number_value(value: &Value) -> Option<u64> {
    if let Some(number) = value.as_u64() {
        return Some(number);
    }
    if let Some(number) = value.as_i64().filter(|number| *number >= 0) {
        return Some(number as u64);
    }
    value
        .as_str()
        .and_then(|text| text.trim().parse::<u64>().ok())
}

fn f64_value(value: &Value) -> Option<f64> {
    value.as_f64().or_else(|| {
        value.as_str().and_then(|text| {
            let trimmed = text.trim().trim_end_matches('%').trim();
            trimmed.parse::<f64>().ok()
        })
    })
}

fn normalize_agent_id(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" => "claude-code".to_string(),
        "github-copilot" => "copilot".to_string(),
        "vscode" | "vs-code" => "code".to_string(),
        "kilo" => "kilo-code".to_string(),
        "kimi" | "moonshot" => "kimi".to_string(),
        "hermes-agent" => "hermes".to_string(),
        "pi-agent" | "pi-coding-agent" => "pi".to_string(),
        other => other.to_string(),
    }
}

fn estimate_tokens(text: &str) -> u64 {
    let mut cjk = 0usize;
    let mut other = 0usize;
    for ch in text.chars() {
        if ch.is_whitespace() {
            continue;
        }
        if is_cjk(ch) {
            cjk += 1;
        } else {
            other += 1;
        }
    }
    ((cjk as f64 * 0.9) + (other as f64 / 4.0)).ceil() as u64
}

fn is_cjk(ch: char) -> bool {
    matches!(
        ch as u32,
        0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x3040..=0x30FF | 0xAC00..=0xD7AF
    )
}

fn timestamp_rfc3339() -> String {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    OffsetDateTime::from_unix_timestamp(duration.as_secs() as i64)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH)
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::io::{Read, Write as IoWrite};
    use std::net::TcpListener;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::thread;

    #[test]
    fn agent_usage_scan_extracts_explicit_tokens_without_prompt_text() {
        let dir = temp_dir("usage-explicit-history");
        fs::write(
            dir.join("history.jsonl"),
            [
                r#"{"sessionId":"s1","role":"user","content":"secret prompt body","createdAt":"2026-07-01T10:00:00Z","usage":{"prompt_tokens":11,"total_tokens":11,"model":"gpt-test"}}"#,
                r#"{"sessionId":"s1","role":"assistant","content":"secret answer body","createdAt":"2026-07-01T10:00:01Z","usage":{"completion_tokens":7,"total_tokens":7,"model":"gpt-test"}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy()
        }))
        .unwrap();

        assert_eq!(result["mode"], "agent-usage-metering");
        assert_eq!(result["summary"]["totalTokens"], 18);
        assert_eq!(result["agents"][0]["history"]["promptTokens"], 11);
        assert_eq!(result["agents"][0]["history"]["completionTokens"], 7);
        assert_eq!(
            result["agents"][0]["history"]["dailyUsage"][0]["date"],
            "2026-07-01"
        );
        assert_eq!(
            result["agents"][0]["history"]["dailyUsage"][0]["totalTokens"],
            18
        );
        assert!(
            result["agents"][0]["allowances"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let serialized = serde_json::to_string(&result).unwrap();
        assert!(!serialized.contains("secret prompt body"));
        assert!(!serialized.contains("secret answer body"));
    }

    #[test]
    fn agent_usage_kimi_code_uses_exact_turn_usage_and_model() {
        let root = temp_dir("usage-kimi-code-wire");
        let wire = root.join("work/session/agents/main/wire.jsonl");
        fs::create_dir_all(wire.parent().unwrap()).unwrap();
        fs::write(
            &wire,
            [
                r#"{"type":"context.append_message","time":"2026-07-10T10:00:00Z","message":{"role":"user","content":"Synthetic prompt that must be covered by explicit turn usage"}}"#,
                r#"{"type":"usage.record","time":"2026-07-10T10:00:01Z","model":"kimi-code/kimi-for-coding","usageScope":"turn","usage":{"inputOther":100,"inputCacheRead":20,"inputCacheCreation":5,"output":30}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-kimi-code-state");

        let result = scan(&json!({
            "agent": "kimi-code",
            "root": root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let agent = &result["agents"][0];
        let history = &agent["history"];
        assert_eq!(agent["agentId"], "kimi-code");
        assert_eq!(agent["label"], "Kimi Code - CLI");
        assert_eq!(history["promptTokens"], 125);
        assert_eq!(history["cachedInputTokens"], 20);
        assert_eq!(history["completionTokens"], 30);
        assert_eq!(history["totalTokens"], 155);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 0);
        assert_eq!(
            history["dailyUsage"][0]["modelUsage"]["kimi-code/kimi-for-coding"],
            155
        );
        assert_eq!(
            history["dailyUsage"][0]["modelTokenUsage"]["kimi-code/kimi-for-coding"]["promptTokens"],
            125
        );
        assert_eq!(
            history["dailyUsage"][0]["modelTokenUsage"]["kimi-code/kimi-for-coding"]["cachedInputTokens"],
            20
        );
        assert_eq!(
            history["dailyUsage"][0]["modelTokenUsage"]["kimi-code/kimi-for-coding"]["completionTokens"],
            30
        );
    }

    #[test]
    fn agent_usage_parent_explicit_usage_covers_pending_content_segment() {
        let dir = temp_dir("usage-parent-explicit-segment");
        fs::write(
            dir.join("session.json"),
            json!({
                "id": "content-block-session",
                "messages": [
                    {
                        "role": "user",
                        "createdAt": "2026-07-08T10:00:00Z",
                        "content": [
                            {"type": "input_text", "text": "question block"}
                        ]
                    },
                    {
                        "role": "assistant",
                        "createdAt": "2026-07-08T10:00:01Z",
                        "content": [
                            {"type": "output_text", "text": "first answer block"},
                            {"type": "output_text", "text": "second answer block"},
                            {"type": "tool_use", "name": "read_fixture", "input": {}}
                        ],
                        "usage": {
                            "input_tokens": 100,
                            "cached_input_tokens": 40,
                            "output_tokens": 10,
                            "total_tokens": 110
                        }
                    }
                ]
            })
            .to_string(),
        )
        .unwrap();
        let state_root = temp_dir("usage-parent-explicit-segment-state");

        let result = scan(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(history["totalTokens"], 110);
        assert_eq!(history["promptTokens"], 100);
        assert_eq!(history["cachedInputTokens"], 40);
        assert_eq!(history["completionTokens"], 10);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 0);
    }

    #[test]
    fn agent_usage_parent_explicit_usage_keeps_uncovered_tail_estimate() {
        let dir = temp_dir("usage-parent-explicit-uncovered-tail");
        fs::write(
            dir.join("session.json"),
            json!({
                "id": "content-block-tail-session",
                "messages": [
                    {
                        "role": "user",
                        "createdAt": "2026-07-08T10:00:00Z",
                        "content": [{"type": "input_text", "text": "question"}]
                    },
                    {
                        "role": "assistant",
                        "createdAt": "2026-07-08T10:00:01Z",
                        "content": [{"type": "output_text", "text": "answer"}],
                        "usage": {
                            "input_tokens": 100,
                            "cached_input_tokens": 40,
                            "output_tokens": 10,
                            "total_tokens": 110
                        }
                    },
                    {
                        "role": "user",
                        "createdAt": "2026-07-08T10:00:02Z",
                        "content": [{"type": "input_text", "text": "abcd"}]
                    }
                ]
            })
            .to_string(),
        )
        .unwrap();
        let state_root = temp_dir("usage-parent-explicit-uncovered-tail-state");

        let result = scan(&json!({
            "agent": "opencode",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(history["totalTokens"], 111);
        assert_eq!(history["promptTokens"], 101);
        assert_eq!(history["cachedInputTokens"], 40);
        assert_eq!(history["completionTokens"], 10);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 1);
    }

    #[test]
    fn agent_usage_scan_prefers_codex_events_and_estimates_uncovered_tail() {
        let dir = temp_dir("usage-codex-token-events");
        fs::write(
            dir.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-07-01T10:00:00Z","type":"session_meta","payload":{"id":"session-1"}}"#,
                r#"{"timestamp":"2026-07-01T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#,
                r#"{"timestamp":"2026-07-01T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6,"cached_input_tokens":0,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":10},"last_token_usage":{"input_tokens":6,"cached_input_tokens":0,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":10}}}}"#,
                r#"{"timestamp":"2026-07-01T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8,"cached_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":13},"last_token_usage":{"input_tokens":2,"cached_input_tokens":2,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":3}}}}"#,
                r#"{"timestamp":"2026-07-02T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18,"cached_input_tokens":2,"output_tokens":10,"reasoning_output_tokens":4,"total_tokens":28},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5,"reasoning_output_tokens":2,"total_tokens":15}}}}"#,
                r#"{"timestamp":"2026-07-02T11:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"abcd"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-codex-token-events-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(
            history["source"],
            "codex-local-token-events+history-estimate"
        );
        assert_eq!(history["sessionCount"], 1);
        assert_eq!(history["totalTokens"], 29);
        assert_eq!(history["promptTokens"], 19);
        assert_eq!(history["cachedInputTokens"], 2);
        assert_eq!(history["completionTokens"], 10);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 1);
        assert_eq!(history["dailyUsage"][0]["date"], "2026-07-01");
        assert_eq!(history["dailyUsage"][0]["totalTokens"], 13);
        assert_eq!(history["dailyUsage"][1]["date"], "2026-07-02");
        assert_eq!(history["dailyUsage"][1]["totalTokens"], 16);
        assert_eq!(history["dailyUsage"][1]["modelUsage"]["gpt-test-codex"], 16);
    }

    #[test]
    fn agent_usage_codex_uses_history_estimates_when_token_events_are_absent() {
        let dir = temp_dir("usage-codex-history-estimate");
        fs::write(
            dir.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-07-02T11:00:00Z","type":"session_meta","payload":{"id":"session-estimated"}}"#,
                r#"{"timestamp":"2026-07-02T11:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#,
                r#"{"timestamp":"2026-07-02T11:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"estimated prompt"}]}}"#,
                r#"{"timestamp":"2026-07-02T11:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"estimated answer"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-codex-history-estimate-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(history["source"], "codex-local-history-estimate");
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 0);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 2);
        assert!(history["totalTokens"].as_u64().unwrap_or_default() > 0);
    }

    #[test]
    fn agent_usage_codex_reconciles_repeated_and_divergent_snapshots() {
        let dir = temp_dir("usage-codex-divergent-events");
        fs::write(
            dir.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-divergent"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16},"last_token_usage":{"input_tokens":60,"cached_input_tokens":20,"output_tokens":6}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":100},"last_token_usage":{"input_tokens":40,"cached_input_tokens":30,"output_tokens":5}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1050,"cached_input_tokens":930,"output_tokens":110},"last_token_usage":{"input_tokens":50,"cached_input_tokens":30,"output_tokens":10}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1050,"cached_input_tokens":930,"output_tokens":110},"last_token_usage":{"input_tokens":50,"cached_input_tokens":30,"output_tokens":10}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-codex-divergent-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "forceRefresh": true,
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(history["promptTokens"], 250);
        assert_eq!(history["cachedInputTokens"], 100);
        assert_eq!(history["completionTokens"], 31);
        assert_eq!(history["totalTokens"], 281);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 4);
    }

    #[test]
    fn agent_usage_codex_reuses_and_appends_file_cache() {
        let dir = temp_dir("usage-codex-incremental-events");
        let rollout = dir.join("rollout.jsonl");
        fs::write(
            &rollout,
            [
                r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-incremental"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6,"cached_input_tokens":2,"output_tokens":4},"last_token_usage":{"input_tokens":6,"cached_input_tokens":2,"output_tokens":4}}}}"#,
            ]
            .join("\n")
                + "\n",
        )
        .unwrap();
        let state_root = temp_dir("usage-codex-incremental-state");
        let params = json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "forceRefresh": true,
            "now": "2026-07-10T12:00:00Z"
        });

        let cold = scan(&params).unwrap();
        let cold_cache = &cold["agents"][0]["history"]["scanCache"];
        assert_eq!(cold_cache["rescannedFiles"], 1);
        assert!(cold_cache["parsedBytes"].as_u64().unwrap() > 0);

        let warm = scan(&params).unwrap();
        let warm_cache = &warm["agents"][0]["history"]["scanCache"];
        assert_eq!(warm_cache["reusedFiles"], 1);
        assert_eq!(warm_cache["parsedBytes"], 0);

        let mut file = fs::OpenOptions::new().append(true).open(&rollout).unwrap();
        writeln!(
            file,
            "{}",
            r#"{"timestamp":"2026-07-08T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8,"cached_input_tokens":2,"output_tokens":5},"last_token_usage":{"input_tokens":2,"cached_input_tokens":0,"output_tokens":1}}}}"#
        )
        .unwrap();

        let appended = scan(&params).unwrap();
        let history = &appended["agents"][0]["history"];
        assert_eq!(history["totalTokens"], 13);
        assert_eq!(history["scanCache"]["appendedFiles"], 1);
        assert!(history["scanCache"]["parsedBytes"].as_u64().unwrap() > 0);
    }

    #[test]
    fn agent_usage_codex_deduplicates_active_and_archived_session_rows() {
        let dir = temp_dir("usage-codex-duplicate-events");
        let active = dir.join("active.jsonl");
        let archived = dir.join("archived.jsonl");
        let contents = [
            r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"session-duplicate"}}"#,
            r#"{"timestamp":"2026-07-08T10:00:01Z","type":"turn_context","payload":{"model":"gpt-test-codex"}}"#,
            r#"{"timestamp":"2026-07-08T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2},"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":2}}}}"#,
        ]
        .join("\n");
        fs::write(active, &contents).unwrap();
        fs::write(archived, &contents).unwrap();
        let state_root = temp_dir("usage-codex-duplicate-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "forceRefresh": true,
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_eq!(history["sessionCount"], 1);
        assert_eq!(history["totalTokens"], 12);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 1);
    }

    #[test]
    fn agent_usage_codex_totals_match_the_report_window() {
        let dir = temp_dir("usage-codex-window-events");
        fs::write(
            dir.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-06-01T10:00:00Z","type":"session_meta","payload":{"id":"session-window"}}"#,
                r#"{"timestamp":"2026-06-01T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10},"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}"#,
                r#"{"timestamp":"2026-07-10T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":106,"output_tokens":14},"last_token_usage":{"input_tokens":6,"output_tokens":4}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("usage-codex-window-state");

        let result = scan(&json!({
            "agent": "codex",
            "root": dir.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "historyDays": 30,
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        assert_eq!(result["summary"]["windowDays"], 30);
        assert_eq!(result["summary"]["windowStart"], "2026-06-11");
        assert_eq!(result["summary"]["totalTokens"], 10);
        assert_eq!(
            result["agents"][0]["history"]["dailyUsage"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn agent_usage_codex_dashboard_payload_maps_credit_history() {
        let summary = dashboard_history_from_helper_payload(&json!({
            "ok": true,
            "usageBreakdown": [
                {
                    "day": "2026-07-08",
                    "services": [
                        {"service": "Desktop App", "creditsUsed": 91.96},
                        {"service": "CLI", "creditsUsed": 155.25}
                    ]
                },
                {
                    "day": "2026-07-09",
                    "totalCreditsUsed": 7.5,
                    "services": [
                        {"service": "GitHub Code Review", "creditsUsed": 7.5}
                    ]
                }
            ]
        }))
        .unwrap();

        assert_eq!(summary.source, Some("openai-dashboard-web"));
        assert_eq!(summary.dashboard_records, 2);
        assert_eq!(summary.total_tokens(), 0);
        let daily = summary.daily_usage_json();
        assert_eq!(daily[0]["date"], "2026-07-08");
        assert_eq!(daily[0]["usageUnit"], "credits");
        assert!((daily[0]["totalCreditsUsed"].as_f64().unwrap() - 247.21).abs() < 0.001);
        assert_eq!(daily[0]["modelUsage"]["Desktop App"], 91.96);
        assert_eq!(daily[0]["modelUsage"]["CLI"], 155.25);
        assert_eq!(daily[1]["date"], "2026-07-09");
        assert_eq!(daily[1]["totalCreditsUsed"], 7.5);
    }

    #[cfg(unix)]
    #[test]
    fn agent_usage_scan_keeps_dashboard_credits_separate_from_tokens() {
        let helper_dir = temp_dir("usage-codex-dashboard-helper");
        let args_path = helper_dir.join("args.txt");
        let helper_path = helper_dir.join("helper.sh");
        fs::write(
            &helper_path,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$*" > '{}'
cat <<'JSON'
{{"ok":true,"status":"ready","usageBreakdown":[{{"day":"2026-07-09","services":[{{"service":"Desktop App","creditsUsed":91.96}},{{"service":"CLI","creditsUsed":154.99}}]}}]}}
JSON
"#,
                args_path.to_string_lossy()
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&helper_path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&helper_path, permissions).unwrap();
        let state_root = temp_dir("usage-codex-dashboard-helper-state");
        let history_root = temp_dir("usage-codex-dashboard-helper-history");

        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "openAIDashboardHelperPath": helper_path.to_string_lossy(),
            "codexOpenAIWebDashboardTimeoutMs": 2500,
            "includeBillingHistory": true
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        assert_ne!(history["source"], "openai-dashboard-web");
        assert_eq!(history["totalTokens"], 0);
        assert!(history["dailyUsage"].as_array().unwrap().is_empty());
        let billing = &result["agents"][0]["billingHistory"];
        assert_eq!(billing["usageUnit"], "credits");
        assert_eq!(billing["dailyUsage"][0]["date"], "2026-07-09");
        assert_eq!(billing["dailyUsage"][0]["totalCreditsUsed"], 246.95);
        let args = fs::read_to_string(args_path).unwrap();
        assert!(args.contains("--keychain-interaction none"));
        assert!(args.contains("--browser-cookie-import false"));
    }

    #[test]
    fn agent_usage_process_samples_calculate_deltas() {
        let state_root = temp_dir("usage-process-state");
        let history_root = temp_dir("usage-process-empty-history");
        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "processSamples": [
                {"agentId":"codex","pid":42,"processName":"codex","startedAt":"t0","sampledAt":"t1","rxBytes":1000,"txBytes":2000},
                {"agentId":"codex","pid":42,"processName":"codex","startedAt":"t0","sampledAt":"t2","rxBytes":1500,"txBytes":2250}
            ]
        }))
        .unwrap();

        assert_eq!(result["summary"]["meteredRxBytes"], 500);
        assert_eq!(result["summary"]["meteredTxBytes"], 250);
        assert_eq!(
            result["agents"][0]["traffic"]["attribution"],
            "process-metered"
        );
        assert_eq!(result["agents"][0]["confidence"], "high");
    }

    #[test]
    fn agent_usage_report_reads_retained_reports() {
        let state_root = temp_dir("usage-report-state");
        let history_root = temp_dir("usage-report-history");
        let _ = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy()
        }))
        .unwrap();
        let listed = report(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "limit": "5"
        }))
        .unwrap();

        assert_eq!(listed["mode"], "agent-usage-metering");
        assert_eq!(listed["resultKind"], "retained-reports");
        assert_eq!(listed["reports"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn agent_usage_standard_scan_retains_report() {
        let state_root = temp_dir("usage-retained-state");
        let history_root = temp_dir("usage-retained-history");
        let _ = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy()
        }))
        .unwrap();
        let listed = report(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "limit": "5"
        }))
        .unwrap();

        assert_eq!(listed["reports"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn agent_usage_allowances_cover_requested_account_slots() {
        let state_root = temp_dir("usage-account-allowances");
        let history_root = temp_dir("usage-account-empty-history");
        let claude = scan(&json!({
            "agent": "claude-code",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "includeAllowances": true
        }))
        .unwrap();
        assert_eq!(
            claude["agents"][0]["allowances"][0]["kind"],
            "claude-weekly-limit"
        );

        let result = scan(&json!({
            "agent": "antigravity",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "includeAllowances": true
        }))
        .unwrap();

        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances.len(), 4);
        assert_eq!(allowances[0]["kind"], "antigravity-gemini-5h-limit");
        assert_eq!(allowances[1]["kind"], "antigravity-gemini-weekly-limit");
        assert_eq!(allowances[2]["kind"], "antigravity-claude-gpt-5h-limit");
        assert_eq!(allowances[3]["kind"], "antigravity-claude-gpt-weekly-limit");
        assert_eq!(allowances[0]["status"], "unavailable");
    }

    #[test]
    fn agent_usage_antigravity_quota_summary_maps_four_windows() {
        let state_root = temp_dir("usage-antigravity-quota-summary-state");
        let history_root = temp_dir("usage-antigravity-quota-summary-history");
        let quota_summary = json!({
            "response": {
                "groups": [
                    {
                        "displayName": "Claude/GPT quota",
                        "buckets": [
                            {
                                "bucketId": "claude_gpt_weekly",
                                "displayName": "Weekly",
                                "remaining": {"case": "remainingFraction", "value": 1.0},
                                "description": "fully refresh in 6d 23h"
                            },
                            {
                                "bucketId": "claude_gpt_5h",
                                "displayName": "5h",
                                "remainingFraction": 0.98,
                                "description": "fully refresh in 4h 59m"
                            }
                        ]
                    },
                    {
                        "displayName": "Gemini quota",
                        "buckets": [
                            {
                                "bucketId": "gemini_weekly",
                                "displayName": "Weekly",
                                "remainingFraction": 0.15,
                                "description": "fully refresh in 5d 7h"
                            },
                            {
                                "bucketId": "gemini_5h",
                                "displayName": "5-hour",
                                "remainingFraction": 0.68,
                                "description": "fully refresh in 3h 28m"
                            }
                        ]
                    }
                ]
            }
        });

        let result = scan(&json!({
            "agent": "antigravity",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "enableAntigravityAllowanceLookup": true,
            "antigravityQuotaSummaryJson": quota_summary.to_string()
        }))
        .unwrap();

        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances.len(), 4);
        assert_eq!(allowances[0]["kind"], "antigravity-gemini-5h-limit");
        assert_eq!(allowances[0]["label"], "Gemini 5-hour");
        assert_eq!(allowances[0]["value"], "68%");
        assert_eq!(allowances[0]["period"], "session");
        assert_eq!(allowances[0]["source"], "antigravity-local:fixture");
        assert_eq!(allowances[1]["kind"], "antigravity-gemini-weekly-limit");
        assert_eq!(allowances[1]["value"], "15%");
        assert_eq!(allowances[1]["period"], "week");
        assert_eq!(allowances[2]["kind"], "antigravity-claude-gpt-5h-limit");
        assert_eq!(allowances[2]["value"], "98%");
        assert_eq!(allowances[3]["kind"], "antigravity-claude-gpt-weekly-limit");
        assert_eq!(allowances[3]["value"], "100%");
    }

    #[test]
    fn agent_usage_allowances_only_skips_history_and_retention() {
        let state_root = temp_dir("usage-allowances-only-state");
        let history_root = temp_dir("usage-allowances-only-history");
        fs::write(
            history_root.join("history.jsonl"),
            r#"{"sessionId":"s1","role":"user","content":"hello","usage":{"total_tokens":88}}"#,
        )
        .unwrap();

        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true
        }))
        .unwrap();

        assert_eq!(result["providerMode"], "allowances-only");
        assert_eq!(result["summary"]["totalTokens"], 0);
        assert_eq!(result["sources"]["history"], "not-scanned");

        let listed = report(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "limit": "5"
        }))
        .unwrap();
        assert!(listed["reports"].as_array().unwrap().is_empty());
    }

    #[test]
    fn agent_usage_codex_system_oauth_allowance_maps_weekly_window() {
        let auth_dir = temp_dir("usage-codex-oauth-auth");
        let auth_path = auth_dir.join("auth.json");
        fs::write(
            &auth_path,
            json!({
                "tokens": {
                    "access_token": "test-access-token",
                    "refresh_token": "test-refresh-token",
                    "account_id": "test-account-id"
                }
            })
            .to_string(),
        )
        .unwrap();
        let (usage_url, server) = serve_json_once(
            "/wham/usage",
            200,
            r#"{"rate_limit":{"primary_window":{"used_percent":2,"reset_after_seconds":13740,"reset_at":1780000000,"limit_window_seconds":18000},"secondary_window":{"used_percent":27,"reset_after_seconds":542100,"reset_at":1780000000,"limit_window_seconds":604800}},"rate_limit_reset_credits":{"available_count":1}}"#,
        );
        let state_root = temp_dir("usage-codex-oauth-state");
        let history_root = temp_dir("usage-codex-oauth-history");

        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "enableCodexSystemAuthAllowance": true,
            "codexAuthPath": auth_path.to_string_lossy(),
            "codexUsageUrl": usage_url
        }))
        .unwrap();
        let request = server.join().unwrap();

        assert_eq!(request.path, "/wham/usage");
        assert_eq!(
            request.header("authorization").as_deref(),
            Some("Bearer test-access-token")
        );
        assert_eq!(
            request.header("chatgpt-account-id").as_deref(),
            Some("test-account-id")
        );
        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances.len(), 3);
        assert_eq!(allowances[0]["kind"], "chatgpt-session-limit");
        assert_eq!(allowances[0]["status"], "available");
        assert_eq!(allowances[0]["value"], "98%");
        assert_eq!(allowances[0]["resetAfterSeconds"], 13740);
        assert_eq!(allowances[1]["kind"], "chatgpt-weekly-limit");
        assert_eq!(allowances[1]["status"], "available");
        assert_eq!(allowances[1]["value"], "73%");
        assert_eq!(allowances[1]["source"], "codex-oauth:system");
        assert_eq!(allowances[2]["kind"], "chatgpt-limit-reset-credits");
        assert_eq!(allowances[2]["value"], "1 available");
    }

    #[test]
    fn agent_usage_codex_system_oauth_fetches_reset_credits_endpoint() {
        let auth_dir = temp_dir("usage-codex-oauth-reset-credits-auth");
        let auth_path = auth_dir.join("auth.json");
        fs::write(
            &auth_path,
            json!({
                "tokens": {
                    "access_token": "test-access-token",
                    "account_id": "test-account-id"
                }
            })
            .to_string(),
        )
        .unwrap();
        let (usage_url, usage_server) = serve_json_once(
            "/wham/usage",
            200,
            r#"{"rate_limit":{"secondary_window":{"used_percent":91,"reset_after_seconds":420000,"limit_window_seconds":604800}}}"#,
        );
        let (reset_credits_url, reset_credits_server) = serve_json_once(
            "/wham/rate-limit-reset-credits",
            200,
            r#"{"credits":[],"available_count":2}"#,
        );
        let state_root = temp_dir("usage-codex-oauth-reset-credits-state");
        let history_root = temp_dir("usage-codex-oauth-reset-credits-history");

        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "enableCodexSystemAuthAllowance": true,
            "codexAuthPath": auth_path.to_string_lossy(),
            "codexUsageUrl": usage_url,
            "codexRateLimitResetCreditsUrl": reset_credits_url
        }))
        .unwrap();
        let usage_request = usage_server.join().unwrap();
        let reset_credits_request = reset_credits_server.join().unwrap();

        assert_eq!(usage_request.path, "/wham/usage");
        assert_eq!(reset_credits_request.path, "/wham/rate-limit-reset-credits");
        assert_eq!(
            reset_credits_request.header("authorization").as_deref(),
            Some("Bearer test-access-token")
        );
        assert_eq!(
            reset_credits_request
                .header("chatgpt-account-id")
                .as_deref(),
            Some("test-account-id")
        );
        assert_eq!(
            reset_credits_request.header("openai-beta").as_deref(),
            Some("codex-1")
        );
        assert_eq!(
            reset_credits_request.header("originator").as_deref(),
            Some("Codex Desktop")
        );
        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances[0]["kind"], "chatgpt-weekly-limit");
        assert_eq!(allowances[0]["value"], "9%");
        assert_eq!(allowances[1]["kind"], "chatgpt-limit-reset-credits");
        assert_eq!(allowances[1]["value"], "2 available");
    }

    #[test]
    fn agent_usage_codex_system_oauth_refreshes_expired_access_token() {
        let auth_dir = temp_dir("usage-codex-oauth-refresh-auth");
        let auth_path = auth_dir.join("auth.json");
        fs::write(
            &auth_path,
            json!({
                "tokens": {
                    "access_token": "old-access-token",
                    "refresh_token": "old-refresh-token",
                    "account_id": "test-account-id"
                }
            })
            .to_string(),
        )
        .unwrap();
        let (usage_url, usage_server) = serve_json_sequence(
            "/wham/usage",
            vec![
                (401, "{}"),
                (
                    200,
                    r#"{"rate_limit":{"secondary_window":{"used_percent":55,"reset_at":1780000000,"limit_window_seconds":604800}}}"#,
                ),
            ],
        );
        let (refresh_url, refresh_server) = serve_json_once(
            "/oauth/token",
            200,
            r#"{"access_token":"new-access-token","refresh_token":"new-refresh-token","id_token":"new-id-token"}"#,
        );
        let state_root = temp_dir("usage-codex-oauth-refresh-state");
        let history_root = temp_dir("usage-codex-oauth-refresh-history");

        let result = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "enableCodexSystemAuthAllowance": true,
            "codexAuthPath": auth_path.to_string_lossy(),
            "codexUsageUrl": usage_url,
            "codexOAuthRefreshUrl": refresh_url
        }))
        .unwrap();
        let usage_requests = usage_server.join().unwrap();
        let refresh_request = refresh_server.join().unwrap();

        assert_eq!(usage_requests.len(), 2);
        assert_eq!(
            usage_requests[0].header("authorization").as_deref(),
            Some("Bearer old-access-token")
        );
        assert_eq!(
            usage_requests[1].header("authorization").as_deref(),
            Some("Bearer new-access-token")
        );
        assert!(
            refresh_request
                .body
                .contains(r#""grant_type":"refresh_token""#)
        );
        let allowance = &result["agents"][0]["allowances"][0];
        assert_eq!(allowance["status"], "available");
        assert_eq!(allowance["value"], "45%");

        let saved = serde_json::from_slice::<Value>(&fs::read(&auth_path).unwrap()).unwrap();
        assert_eq!(saved["tokens"]["access_token"], "new-access-token");
        assert_eq!(saved["tokens"]["refresh_token"], "new-refresh-token");
        assert_eq!(saved["tokens"]["id_token"], "new-id-token");
        assert_eq!(saved["tokens"]["account_id"], "test-account-id");
    }

    #[test]
    fn agent_usage_openrouter_balance_uses_native_http() {
        let (credits_url, server) = serve_json_once(
            "/credits",
            200,
            r#"{"data":{"total_credits":20,"total_usage":7.5}}"#,
        );
        let base_url = credits_url.trim_end_matches("/credits").to_string();
        let state_root = temp_dir("usage-openrouter-state");
        let history_root = temp_dir("usage-openrouter-history");

        let result = scan(&json!({
            "agent": "opencode",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "openRouterApiKey": "test-openrouter-key",
            "openRouterBaseUrl": base_url
        }))
        .unwrap();
        let request = server.join().unwrap();

        assert_eq!(request.path, "/credits");
        assert_eq!(
            request.header("authorization").as_deref(),
            Some("Bearer test-openrouter-key")
        );
        let allowance = &result["agents"][0]["allowances"][0];
        assert_eq!(allowance["kind"], "model-api-balance");
        assert_eq!(allowance["status"], "available");
        assert_eq!(allowance["value"], "$12.50");
        assert_eq!(allowance["source"], "direct-provider:openrouter");
    }

    #[test]
    fn agent_usage_kilo_balance_uses_native_http() {
        let procedure_path =
            "/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod";
        let (usage_url, server) = serve_json_once_prefix(
            procedure_path,
            200,
            r#"[{"result":{"data":{"json":{"creditBlocks":[{"amount_mUsd":20000000,"balance_mUsd":12500000}]}}}},{"result":{"data":{"json":{"subscription":{"currentPeriodUsageUsd":5,"currentPeriodBaseCreditsUsd":20,"currentPeriodBonusCreditsUsd":0}}}}},{"result":{"data":{"json":null}}}]"#,
        );
        let base_url = usage_url.trim_end_matches(KILO_TRPC_PROCEDURES.join(",").as_str());
        let state_root = temp_dir("usage-kilo-state");
        let history_root = temp_dir("usage-kilo-history");

        let result = scan(&json!({
            "agent": "kilo-code",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "kiloApiKey": "test-kilo-token",
            "kiloBaseUrl": base_url
        }))
        .unwrap();
        let request = server.join().unwrap();

        assert!(request.path.starts_with(procedure_path));
        assert_eq!(
            request.header("authorization").as_deref(),
            Some("Bearer test-kilo-token")
        );
        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances.len(), 2);
        let pass = &allowances[0];
        assert_eq!(pass["kind"], "kilo-pass-limit");
        assert_eq!(pass["status"], "available");
        assert_eq!(pass["period"], "month");
        assert_eq!(pass["value"], "75%");
        assert_eq!(pass["source"], "direct-provider:kilo");
        let recharge = &allowances[1];
        assert_eq!(recharge["kind"], "kilo-recharge-credits");
        assert_eq!(recharge["status"], "available");
        assert_eq!(recharge["period"], "balance");
        assert_eq!(recharge["value"], "12.50");
        assert_eq!(recharge["unit"], "credits");
        assert_eq!(recharge["source"], "direct-provider:kilo");
    }

    #[test]
    fn agent_usage_kimi_balance_uses_native_http() {
        let (balance_url, server) = serve_json_once(
            "/users/me/balance",
            200,
            r#"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#,
        );
        let base_url = balance_url
            .trim_end_matches("/users/me/balance")
            .to_string();
        let state_root = temp_dir("usage-kimi-state");
        let history_root = temp_dir("usage-kimi-history");

        let result = scan(&json!({
            "agent": "kimi",
            "stateRoot": state_root.to_string_lossy(),
            "root": history_root.to_string_lossy(),
            "allowancesOnly": true,
            "kimiApiKey": "test-kimi-key",
            "kimiBaseUrl": base_url
        }))
        .unwrap();
        let request = server.join().unwrap();

        assert_eq!(request.path, "/users/me/balance");
        assert_eq!(
            request.header("authorization").as_deref(),
            Some("Bearer test-kimi-key")
        );
        let allowances = result["agents"][0]["allowances"].as_array().unwrap();
        assert_eq!(allowances.len(), 3);
        let available = &allowances[0];
        assert_eq!(available["kind"], "kimi-available-balance");
        assert_eq!(available["status"], "available");
        assert_eq!(available["value"], "49.6");
        assert_eq!(available["unit"], "credits");
        assert_eq!(available["source"], "direct-provider:kimi");
        let cash = &allowances[1];
        assert_eq!(cash["kind"], "kimi-cash-balance");
        assert_eq!(cash["value"], "3");
        let voucher = &allowances[2];
        assert_eq!(voucher["kind"], "kimi-voucher-balance");
        assert_eq!(voucher["value"], "46.6");
    }

    fn temp_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-agent-usage-{}-{}-{}",
            name,
            now.as_secs(),
            now.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    struct CapturedRequest {
        path: String,
        headers: BTreeMap<String, String>,
        body: String,
    }

    impl CapturedRequest {
        fn header(&self, key: &str) -> Option<String> {
            self.headers.get(&key.to_ascii_lowercase()).cloned()
        }
    }

    fn serve_json_once(
        path: &'static str,
        status: u16,
        body: &'static str,
    ) -> (String, thread::JoinHandle<CapturedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _peer) = listener.accept().unwrap();
            let request = read_captured_request(&mut stream);
            let reason = if status == 200 { "OK" } else { "ERROR" };
            let response = format!(
                "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            assert_eq!(request.path, path);
            request
        });
        (format!("http://{address}{path}"), handle)
    }

    fn serve_json_once_prefix(
        path_prefix: &'static str,
        status: u16,
        body: &'static str,
    ) -> (String, thread::JoinHandle<CapturedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _peer) = listener.accept().unwrap();
            let request = read_captured_request(&mut stream);
            let reason = if status == 200 { "OK" } else { "ERROR" };
            let response = format!(
                "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(response.as_bytes()).unwrap();
            assert!(request.path.starts_with(path_prefix));
            request
        });
        (format!("http://{address}{path_prefix}"), handle)
    }

    fn serve_json_sequence(
        path: &'static str,
        responses: Vec<(u16, &'static str)>,
    ) -> (String, thread::JoinHandle<Vec<CapturedRequest>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let mut requests = Vec::<CapturedRequest>::new();
            for (status, body) in responses {
                let (mut stream, _peer) = listener.accept().unwrap();
                let request = read_captured_request(&mut stream);
                let reason = if status == 200 { "OK" } else { "ERROR" };
                let response = format!(
                    "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).unwrap();
                assert_eq!(request.path, path);
                requests.push(request);
            }
            requests
        });
        (format!("http://{address}{path}"), handle)
    }

    fn read_captured_request(stream: &mut std::net::TcpStream) -> CapturedRequest {
        stream
            .set_read_timeout(Some(StdDuration::from_secs(2)))
            .unwrap();
        let mut buffer = Vec::<u8>::new();
        let mut chunk = [0_u8; 4096];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(size) => {
                    buffer.extend_from_slice(&chunk[..size]);
                    if http_request_complete(&buffer) {
                        break;
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                }
                Err(error) => panic!("test server read failed: {error}"),
            }
        }
        parse_captured_request(&buffer)
    }

    fn http_request_complete(buffer: &[u8]) -> bool {
        let Some(header_end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") else {
            return false;
        };
        let headers = String::from_utf8_lossy(&buffer[..header_end]);
        let content_length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                if name.eq_ignore_ascii_case("content-length") {
                    value.trim().parse::<usize>().ok()
                } else {
                    None
                }
            })
            .unwrap_or(0);
        buffer.len() >= header_end + 4 + content_length
    }

    fn parse_captured_request(buffer: &[u8]) -> CapturedRequest {
        let text = String::from_utf8_lossy(buffer);
        let mut lines = text.lines();
        let first_line = lines.next().unwrap_or_default();
        let path = first_line
            .split_whitespace()
            .nth(1)
            .unwrap_or_default()
            .to_string();
        let mut headers = BTreeMap::<String, String>::new();
        for line in lines {
            if line.trim().is_empty() {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                headers.insert(name.to_ascii_lowercase(), value.trim().to_string());
            }
        }
        let body = buffer
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|header_end| String::from_utf8_lossy(&buffer[header_end + 4..]).to_string())
            .unwrap_or_default();
        CapturedRequest {
            path,
            headers,
            body,
        }
    }
}
