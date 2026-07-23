//! Stable local-token-usage contract and aggregation models.

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub(super) const AGENT_USAGE_SCHEMA_VERSION: u32 = 6;
pub(super) const AGENT_USAGE_MODE: &str = "local-token-usage";
pub(super) const AGENT_USAGE_TOKEN_SOURCE_MODE: &str = "native-metadata-first-incremental";
pub(super) const REPORT_COLLECTION: &str = "agent-usage-reports";
pub(super) const MAX_REPORTS: usize = 20;
pub(super) const DEFAULT_USAGE_WINDOW_DAYS: u64 = 30;
pub(super) const MAX_USAGE_WINDOW_DAYS: u64 = 90;
pub(super) const UNATTRIBUTED_MODEL: &str = "Others";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct AgentDef {
    pub(super) id: &'static str,
    pub(super) label: &'static str,
}

pub(super) const SUPPORTED_AGENTS: &[AgentDef] = &[
    AgentDef {
        id: "antigravity",
        label: "Antigravity",
    },
    AgentDef {
        id: "claude-code",
        label: "Claude Code",
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
    AgentDef {
        id: "kimi",
        label: "Kimi",
    },
    AgentDef {
        id: "kimi-code",
        label: "Kimi Code",
    },
    AgentDef {
        id: "pi",
        label: "Pi Agent",
    },
];

#[derive(Clone, Debug, Default)]
pub(super) struct HistoryUsageSummary {
    pub(super) source: Option<&'static str>,
    pub(super) session_count: u64,
    pub(super) message_count: u64,
    pub(super) explicit_prompt_tokens: u64,
    pub(super) explicit_cached_input_tokens: u64,
    pub(super) explicit_completion_tokens: u64,
    pub(super) explicit_total_tokens: u64,
    pub(super) estimated_prompt_tokens: u64,
    pub(super) estimated_completion_tokens: u64,
    pub(super) estimated_total_tokens: u64,
    pub(super) explicit_records: u64,
    pub(super) estimated_records: u64,
    pub(super) source_paths: BTreeSet<String>,
    pub(super) skipped: Vec<Value>,
    pub(super) daily_usage: BTreeMap<String, DailyUsageSummary>,
    pub(super) scan_cache: Option<Value>,
}

impl HistoryUsageSummary {
    pub(super) fn prompt_tokens(&self) -> u64 {
        self.explicit_prompt_tokens
            .saturating_add(self.estimated_prompt_tokens)
    }

    pub(super) fn completion_tokens(&self) -> u64 {
        self.explicit_completion_tokens
            .saturating_add(self.estimated_completion_tokens)
    }

    pub(super) fn total_tokens(&self) -> u64 {
        self.explicit_total_tokens
            .saturating_add(self.estimated_total_tokens)
    }

    pub(super) fn confidence(&self) -> &'static str {
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

    pub(super) fn to_json(&self) -> Value {
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
                "estimatedTotalTokens": self.estimated_total_tokens
            },
            "dailyUsage": self.daily_usage_json(),
            "source": self.source.unwrap_or("native-history-adapters"),
            "confidence": self.confidence(),
            "scanCache": self.scan_cache
        })
    }

    pub(super) fn add(&mut self, usage: MessageUsage, date_key: Option<String>) {
        if usage.total_tokens == 0 {
            return;
        }
        match usage.accuracy {
            UsageAccuracy::Exact => {
                self.explicit_prompt_tokens = self
                    .explicit_prompt_tokens
                    .saturating_add(usage.prompt_tokens);
                self.explicit_cached_input_tokens = self
                    .explicit_cached_input_tokens
                    .saturating_add(usage.cached_input_tokens.min(usage.prompt_tokens));
                self.explicit_completion_tokens = self
                    .explicit_completion_tokens
                    .saturating_add(usage.completion_tokens);
                self.explicit_total_tokens = self
                    .explicit_total_tokens
                    .saturating_add(usage.total_tokens);
                self.explicit_records = self.explicit_records.saturating_add(1);
            }
            UsageAccuracy::Estimated => {
                self.estimated_prompt_tokens = self
                    .estimated_prompt_tokens
                    .saturating_add(usage.prompt_tokens);
                self.estimated_completion_tokens = self
                    .estimated_completion_tokens
                    .saturating_add(usage.completion_tokens);
                self.estimated_total_tokens = self
                    .estimated_total_tokens
                    .saturating_add(usage.total_tokens);
                self.estimated_records = self.estimated_records.saturating_add(1);
            }
        }
        if let Some(date_key) = date_key.filter(|value| !value.trim().is_empty()) {
            self.daily_usage.entry(date_key).or_default().add(usage);
        }
    }

    pub(super) fn merge(&mut self, other: &Self) {
        self.session_count = self.session_count.saturating_add(other.session_count);
        self.message_count = self.message_count.saturating_add(other.message_count);
        self.explicit_prompt_tokens = self
            .explicit_prompt_tokens
            .saturating_add(other.explicit_prompt_tokens);
        self.explicit_cached_input_tokens = self
            .explicit_cached_input_tokens
            .saturating_add(other.explicit_cached_input_tokens);
        self.explicit_completion_tokens = self
            .explicit_completion_tokens
            .saturating_add(other.explicit_completion_tokens);
        self.explicit_total_tokens = self
            .explicit_total_tokens
            .saturating_add(other.explicit_total_tokens);
        self.estimated_prompt_tokens = self
            .estimated_prompt_tokens
            .saturating_add(other.estimated_prompt_tokens);
        self.estimated_completion_tokens = self
            .estimated_completion_tokens
            .saturating_add(other.estimated_completion_tokens);
        self.estimated_total_tokens = self
            .estimated_total_tokens
            .saturating_add(other.estimated_total_tokens);
        self.explicit_records = self.explicit_records.saturating_add(other.explicit_records);
        self.estimated_records = self
            .estimated_records
            .saturating_add(other.estimated_records);
        for (date, usage) in &other.daily_usage {
            self.daily_usage
                .entry(date.clone())
                .or_default()
                .merge(usage);
        }
    }

    fn daily_usage_json(&self) -> Vec<Value> {
        self.daily_usage
            .iter()
            .filter(|(_, usage)| usage.total_tokens > 0)
            .map(|(date, usage)| {
                json!({
                    "date": date,
                    "promptTokens": usage.prompt_tokens,
                    "cachedInputTokens": usage.cached_input_tokens,
                    "completionTokens": usage.completion_tokens,
                    "totalTokens": usage.total_tokens,
                    "messageCount": usage.message_count,
                    "modelUsage": usage.model_usage_totals_json(),
                    "modelTokenUsage": usage.model_token_usage_json(),
                    "explicitRecords": usage.explicit_records,
                    "estimatedRecords": usage.estimated_records
                })
            })
            .collect()
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct MessageUsage {
    pub(super) prompt_tokens: u64,
    pub(super) cached_input_tokens: u64,
    pub(super) completion_tokens: u64,
    pub(super) total_tokens: u64,
    pub(super) model: Option<String>,
    pub(super) accuracy: UsageAccuracy,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum UsageAccuracy {
    #[default]
    Exact,
    Estimated,
}

#[derive(Clone, Debug, Default)]
pub(super) struct DailyUsageSummary {
    pub(super) prompt_tokens: u64,
    pub(super) cached_input_tokens: u64,
    pub(super) completion_tokens: u64,
    pub(super) total_tokens: u64,
    pub(super) message_count: u64,
    pub(super) explicit_records: u64,
    pub(super) estimated_records: u64,
    pub(super) estimated_prompt_tokens: u64,
    pub(super) estimated_completion_tokens: u64,
    pub(super) model_usage: BTreeMap<String, ModelTokenUsageSummary>,
}

impl DailyUsageSummary {
    fn add(&mut self, usage: MessageUsage) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(usage.prompt_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(usage.cached_input_tokens.min(usage.prompt_tokens));
        self.completion_tokens = self
            .completion_tokens
            .saturating_add(usage.completion_tokens);
        self.total_tokens = self.total_tokens.saturating_add(usage.total_tokens);
        self.message_count = self.message_count.saturating_add(1);
        match usage.accuracy {
            UsageAccuracy::Exact => {
                self.explicit_records = self.explicit_records.saturating_add(1);
            }
            UsageAccuracy::Estimated => {
                self.estimated_records = self.estimated_records.saturating_add(1);
                self.estimated_prompt_tokens = self
                    .estimated_prompt_tokens
                    .saturating_add(usage.prompt_tokens);
                self.estimated_completion_tokens = self
                    .estimated_completion_tokens
                    .saturating_add(usage.completion_tokens);
            }
        }
        let model = usage
            .model
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_owned());
        self.model_usage.entry(model).or_default().add(
            usage.prompt_tokens,
            usage.cached_input_tokens,
            usage.completion_tokens,
            usage.total_tokens,
            usage.accuracy,
        );
    }

    pub(super) fn add_model_usage(
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
            UsageAccuracy::Exact,
        );
    }

    pub(super) fn add_model_usage_with_estimates(
        &mut self,
        model: String,
        prompt_tokens: u64,
        cached_input_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
        estimated_prompt_tokens: u64,
        estimated_completion_tokens: u64,
    ) {
        let usage = self.model_usage.entry(model).or_default();
        usage.add(
            prompt_tokens,
            cached_input_tokens,
            completion_tokens,
            total_tokens,
            UsageAccuracy::Exact,
        );
        usage.estimated_prompt_tokens = usage
            .estimated_prompt_tokens
            .saturating_add(estimated_prompt_tokens.min(prompt_tokens));
        usage.estimated_completion_tokens = usage
            .estimated_completion_tokens
            .saturating_add(estimated_completion_tokens.min(completion_tokens));
    }

    fn merge(&mut self, other: &Self) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(other.prompt_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(other.cached_input_tokens);
        self.completion_tokens = self
            .completion_tokens
            .saturating_add(other.completion_tokens);
        self.total_tokens = self.total_tokens.saturating_add(other.total_tokens);
        self.message_count = self.message_count.saturating_add(other.message_count);
        self.explicit_records = self.explicit_records.saturating_add(other.explicit_records);
        self.estimated_records = self
            .estimated_records
            .saturating_add(other.estimated_records);
        self.estimated_prompt_tokens = self
            .estimated_prompt_tokens
            .saturating_add(other.estimated_prompt_tokens);
        self.estimated_completion_tokens = self
            .estimated_completion_tokens
            .saturating_add(other.estimated_completion_tokens);
        for (model, usage) in &other.model_usage {
            self.model_usage
                .entry(model.clone())
                .and_modify(|current| current.merge(*usage))
                .or_insert(*usage);
        }
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

#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ModelTokenUsageSummary {
    pub(super) prompt_tokens: u64,
    pub(super) cached_input_tokens: u64,
    pub(super) completion_tokens: u64,
    pub(super) total_tokens: u64,
    pub(super) estimated_prompt_tokens: u64,
    pub(super) estimated_completion_tokens: u64,
}

impl ModelTokenUsageSummary {
    fn add(
        &mut self,
        prompt_tokens: u64,
        cached_input_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
        accuracy: UsageAccuracy,
    ) {
        self.prompt_tokens = self.prompt_tokens.saturating_add(prompt_tokens);
        self.cached_input_tokens = self
            .cached_input_tokens
            .saturating_add(cached_input_tokens.min(prompt_tokens));
        self.completion_tokens = self.completion_tokens.saturating_add(completion_tokens);
        self.total_tokens = self.total_tokens.saturating_add(total_tokens);
        if accuracy == UsageAccuracy::Estimated {
            self.estimated_prompt_tokens =
                self.estimated_prompt_tokens.saturating_add(prompt_tokens);
            self.estimated_completion_tokens = self
                .estimated_completion_tokens
                .saturating_add(completion_tokens);
        }
    }

    fn merge(&mut self, other: Self) {
        self.add(
            other.prompt_tokens,
            other.cached_input_tokens,
            other.completion_tokens,
            other.total_tokens,
            UsageAccuracy::Exact,
        );
        self.estimated_prompt_tokens = self
            .estimated_prompt_tokens
            .saturating_add(other.estimated_prompt_tokens);
        self.estimated_completion_tokens = self
            .estimated_completion_tokens
            .saturating_add(other.estimated_completion_tokens);
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

pub(super) fn text_field(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub(super) fn number_field(value: &Value, keys: &[&str]) -> Option<u64> {
    let object = value.as_object()?;
    keys.iter()
        .find_map(|key| object.get(*key).and_then(number_value))
}

pub(super) fn number_value(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| {
            value
                .as_i64()
                .filter(|number| *number >= 0)
                .map(|v| v as u64)
        })
        .or_else(|| value.as_str()?.trim().parse::<u64>().ok())
}

pub(super) fn normalize_agent_id(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" => "claude-code".to_owned(),
        "github-copilot" => "copilot".to_owned(),
        "vscode" | "vs-code" => "code".to_owned(),
        "kilo" => "kilo-code".to_owned(),
        "kimi" | "moonshot" => "kimi".to_owned(),
        "hermes-agent" => "hermes".to_owned(),
        "pi-agent" | "pi-coding-agent" => "pi".to_owned(),
        other => other.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_usage_sources_use_product_identity() {
        let labels = SUPPORTED_AGENTS
            .iter()
            .map(|agent| (agent.id, agent.label))
            .collect::<BTreeMap<_, _>>();

        assert_eq!(labels.get("codex"), Some(&"Codex"));
        assert_eq!(labels.get("kimi-code"), Some(&"Kimi Code"));
        assert_eq!(labels.get("kimi"), Some(&"Kimi"));
    }

    #[test]
    fn aggregation_preserves_agent_and_model_dimensions() {
        let mut first = HistoryUsageSummary::default();
        first.add(
            MessageUsage {
                prompt_tokens: 8,
                cached_input_tokens: 3,
                total_tokens: 8,
                model: Some("model-a".to_owned()),
                ..MessageUsage::default()
            },
            Some("2026-07-01".to_owned()),
        );
        let mut second = HistoryUsageSummary::default();
        second.add(
            MessageUsage {
                completion_tokens: 5,
                total_tokens: 5,
                model: Some("model-b".to_owned()),
                accuracy: UsageAccuracy::Estimated,
                ..MessageUsage::default()
            },
            Some("2026-07-01".to_owned()),
        );
        first.merge(&second);

        let contract = first.to_json();
        assert_eq!(contract["totalTokens"], 13);
        assert_eq!(contract["dailyUsage"][0]["modelUsage"]["model-a"], 8);
        assert_eq!(contract["dailyUsage"][0]["modelUsage"]["model-b"], 5);
        assert_eq!(contract["confidence"], "medium");
        assert_eq!(contract["tokenSourceBreakdown"]["estimatedRecords"], 1);
    }

    #[test]
    fn contract_identity_is_schema_six_metadata_first_incremental() {
        assert_eq!(AGENT_USAGE_SCHEMA_VERSION, 6);
        assert_eq!(AGENT_USAGE_MODE, "local-token-usage");
        assert_eq!(
            AGENT_USAGE_TOKEN_SOURCE_MODE,
            "native-metadata-first-incremental"
        );
        assert_eq!(DEFAULT_USAGE_WINDOW_DAYS, 30);
    }
}
