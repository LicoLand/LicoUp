use crate::client_state::ClientStateStore;
use crate::conversations;
use crate::targets;
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const AGENT_USAGE_SCHEMA_VERSION: u32 = 1;
const REPORT_COLLECTION: &str = "agent-usage-reports";
const MAX_REPORTS: usize = 20;

#[derive(Clone, Copy)]
struct AgentDef {
    id: &'static str,
    label: &'static str,
}

const SUPPORTED_AGENTS: &[AgentDef] = &[
    AgentDef {
        id: "antigravity",
        label: "Antigravity",
    },
    AgentDef {
        id: "claude-code",
        label: "Claude Code",
    },
    AgentDef {
        id: "code",
        label: "VS Code",
    },
    AgentDef {
        id: "codex",
        label: "Codex",
    },
    AgentDef {
        id: "copilot",
        label: "GitHub Copilot",
    },
    AgentDef {
        id: "cursor",
        label: "Cursor",
    },
    AgentDef {
        id: "hermes",
        label: "Hermes Agent",
    },
    AgentDef {
        id: "kilo-code",
        label: "Kilo Code",
    },
    AgentDef {
        id: "openclaw",
        label: "OpenClaw",
    },
    AgentDef {
        id: "opencode",
        label: "OpenCode",
    },
];

#[derive(Default)]
struct HistoryUsageSummary {
    session_count: u64,
    message_count: u64,
    explicit_prompt_tokens: u64,
    explicit_completion_tokens: u64,
    explicit_total_tokens: u64,
    estimated_prompt_tokens: u64,
    estimated_completion_tokens: u64,
    estimated_total_tokens: u64,
    explicit_records: u64,
    estimated_records: u64,
    source_paths: BTreeSet<String>,
    skipped: Vec<Value>,
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
        if self.explicit_records > 0 {
            "high"
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
            "completionTokens": self.completion_tokens(),
            "totalTokens": self.total_tokens(),
            "tokenSourceBreakdown": {
                "explicitRecords": self.explicit_records,
                "estimatedRecords": self.estimated_records,
                "explicitPromptTokens": self.explicit_prompt_tokens,
                "explicitCompletionTokens": self.explicit_completion_tokens,
                "explicitTotalTokens": self.explicit_total_tokens,
                "estimatedPromptTokens": self.estimated_prompt_tokens,
                "estimatedCompletionTokens": self.estimated_completion_tokens,
                "estimatedTotalTokens": self.estimated_total_tokens
            },
            "estimatedPayloadBytes": self.estimated_payload_bytes(),
            "confidence": self.confidence()
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
    processes: Vec<Value>,
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
    let observe_ms = u64_param(params, "observeMs").unwrap_or(0);
    let process_samples = process_samples_from_params(params);
    let mut warnings = Vec::<Value>::new();
    let target_status = target_status_map(params, &mut warnings);
    if observe_ms > 0 && process_samples.is_empty() {
        warnings.push(json!({
            "code": "process_network_meter_unavailable",
            "message": "No supported process network meter is available in this runtime; process bytes are reported as unavailable unless samples are provided."
        }));
    }

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
        let history = summarize_agent_history(def, params, &mut warnings);
        let process = summarize_process_samples(def.id, &process_samples);
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
        summary.explicit_completion_tokens += history.explicit_completion_tokens;
        summary.explicit_total_tokens += history.explicit_total_tokens;
        summary.estimated_prompt_tokens += history.estimated_prompt_tokens;
        summary.estimated_completion_tokens += history.estimated_completion_tokens;
        summary.estimated_total_tokens += history.estimated_total_tokens;
        summary.explicit_records += history.explicit_records;
        summary.estimated_records += history.estimated_records;
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
            "processes": process.processes,
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
        "providerMode": if process_samples.is_empty() { "contract" } else { "local-live" },
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
            "attribution": traffic_attribution(summary_metered_rx + summary_metered_tx, summary_estimated_historical_bytes),
            "confidence": traffic_confidence(
                if summary_metered_rx + summary_metered_tx > 0 { "high" } else { "unavailable" },
                summary.confidence()
            )
        },
        "agents": agents,
        "sources": {
            "history": "native-history-adapters",
            "traffic": if process_samples.is_empty() { "platform-unavailable" } else { "process-samples" },
            "retention": {
                "collection": REPORT_COLLECTION,
                "maxReports": MAX_REPORTS
            }
        },
        "warnings": warnings
    });
    persist_report(params, &report)?;
    Ok(report)
}

pub fn report(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let collection = store.read_collection(REPORT_COLLECTION)?;
    let agent_filter =
        text_param(params, &["agent", "target"]).map(|value| normalize_agent_id(&value));
    let limit = u64_param(params, "limit").unwrap_or(10) as usize;
    let mut reports = collection
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|report| match agent_filter.as_deref() {
            Some(agent_id) => report_has_agent(report, agent_id),
            None => true,
        })
        .collect::<Vec<_>>();
    if reports.len() > limit {
        reports = reports[reports.len() - limit..].to_vec();
    }
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
    warnings: &mut Vec<Value>,
) -> HistoryUsageSummary {
    let mut conversation_params = params.clone();
    if let Some(object) = conversation_params.as_object_mut() {
        object.insert("agent".to_string(), json!(def.id));
    }
    let listed = match conversations::conversation_list(&conversation_params) {
        Ok(value) => value,
        Err(error) => {
            warnings.push(json!({
                "code": "native_history_scan_failed",
                "agentId": def.id,
                "message": error.to_string()
            }));
            return HistoryUsageSummary::default();
        }
    };
    let mut summary = HistoryUsageSummary::default();
    if let Some(sessions) = listed.get("sessions").and_then(Value::as_array) {
        summary.session_count = sessions.len() as u64;
        for session in sessions {
            if let Some(path) = session.get("sourcePath").and_then(Value::as_str) {
                if !path.trim().is_empty() {
                    summary.source_paths.insert(path.to_string());
                }
            }
            let messages = session
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            summary.message_count += session
                .get("messageCount")
                .and_then(Value::as_u64)
                .unwrap_or(messages.len() as u64);
            for message in messages {
                add_message_usage(&message, &mut summary);
            }
        }
    }
    if let Some(skipped) = listed
        .get("sources")
        .and_then(|sources| sources.get("skipped"))
        .and_then(Value::as_array)
    {
        summary.skipped = skipped.to_vec();
    }
    summary
}

fn add_message_usage(message: &Value, summary: &mut HistoryUsageSummary) {
    if let Some(usage) = message.get("usage") {
        let prompt = number_field(usage, &["promptTokens", "prompt_tokens"]);
        let completion = number_field(usage, &["completionTokens", "completion_tokens"]);
        let total = number_field(usage, &["totalTokens", "total_tokens"])
            .unwrap_or(prompt.unwrap_or(0) + completion.unwrap_or(0));
        summary.explicit_prompt_tokens += prompt.unwrap_or(0);
        summary.explicit_completion_tokens += completion.unwrap_or(0);
        summary.explicit_total_tokens += total;
        summary.explicit_records += 1;
        return;
    }
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if role == "metadata" {
        return;
    }
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let tokens = estimate_tokens(text);
    if tokens == 0 {
        return;
    }
    if role == "agent" {
        summary.estimated_completion_tokens += tokens;
    } else {
        summary.estimated_prompt_tokens += tokens;
    }
    summary.estimated_total_tokens += tokens;
    summary.estimated_records += 1;
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
        summary.processes.push(json!({
            "pid": last.pid,
            "processName": last.process_name,
            "startedAt": last.started_at,
            "sampledAt": last.sampled_at,
            "rxBytes": last.rx_bytes,
            "txBytes": last.tx_bytes,
            "deltaRxBytes": rx_delta,
            "deltaTxBytes": tx_delta,
            "sampleCount": items.len(),
            "meterSource": "process-samples"
        }));
    }
    summary
}

fn target_status_map(params: &Value, warnings: &mut Vec<Value>) -> BTreeMap<String, String> {
    let mut scan_params = params.clone();
    if let Some(object) = scan_params.as_object_mut() {
        object.insert("includeAccessibleEnvironments".to_string(), json!(false));
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
            warnings.push(json!({
                "code": "target_scan_failed",
                "message": error.to_string()
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
        .unwrap_or_default();
    items.push(report.clone());
    if items.len() > MAX_REPORTS {
        items = items[items.len() - MAX_REPORTS..].to_vec();
    }
    if let Some(object) = collection.as_object_mut() {
        object.insert("items".to_string(), Value::Array(items));
    }
    store.write_collection(REPORT_COLLECTION, collection)?;
    store.activity_log().append(
        "agent_usage.report.scanned",
        json!({
            "target": text_param(params, &["agent", "target"]).unwrap_or_else(|| "all".to_string()),
            "agentCount": report["summary"]["agentCount"].clone(),
            "totalTokens": report["summary"]["totalTokens"].clone()
        }),
    )?;
    Ok(())
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

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
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

fn u64_param(params: &Value, key: &str) -> Option<u64> {
    params.get(key).and_then(number_value)
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

fn normalize_agent_id(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" => "claude-code".to_string(),
        "github-copilot" => "copilot".to_string(),
        "vscode" | "vs-code" => "code".to_string(),
        "kilo" => "kilo-code".to_string(),
        "hermes-agent" => "hermes".to_string(),
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

    #[test]
    fn agent_usage_scan_extracts_explicit_tokens_without_prompt_text() {
        let dir = temp_dir("usage-explicit-history");
        fs::write(
            dir.join("history.jsonl"),
            [
                r#"{"sessionId":"s1","role":"user","content":"secret prompt body","usage":{"prompt_tokens":11,"total_tokens":11}}"#,
                r#"{"sessionId":"s1","role":"assistant","content":"secret answer body","usage":{"completion_tokens":7,"total_tokens":7}}"#,
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
        let serialized = serde_json::to_string(&result).unwrap();
        assert!(!serialized.contains("secret prompt body"));
        assert!(!serialized.contains("secret answer body"));
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
        let _ = scan(&json!({
            "agent": "codex",
            "stateRoot": state_root.to_string_lossy()
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
}
