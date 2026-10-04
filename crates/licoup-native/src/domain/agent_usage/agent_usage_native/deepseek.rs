//! Exact usage from the installed Harness's own durable session log.
//!
//! The row format, its versioning and its compression belong to the Harness,
//! so its reader lives in the DeepSeek adapter package
//! (`licoup_agent_deepseek::session_store`) rather than here. What stays in the
//! kernel is the *accounting*: which artifact is the current generation of one
//! session, how a sample becomes a request record, and which calendar day it
//! lands on. That division is the same one the removed Node worker had — it
//! resolved the vendor's store and this pipeline did the arithmetic — with no
//! Node runtime and no vendor library in the middle.

use super::super::contract::{HistoryUsageSummary, MessageUsage};
use super::super::variant::{UsageVariant, model_label};
use super::super::window::UsageWindow;
use super::models::ParseResult;
use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The exact upper bound a JSON number can carry before a JavaScript reader
/// loses integer fidelity: the reader used to be a Node script, and the
/// accounting the kernel kept then keeps the same bound now.
const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;


/// A read of one session artifact failed, named by the stage it failed at.
#[derive(Debug)]
pub(super) struct ReadFailure(pub(super) &'static str);
impl std::fmt::Display for ReadFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "DeepSeek Harness usage {} failed", self.0)
    }
}
impl std::error::Error for ReadFailure {}

/// The one artifact that represents each session, when several generations of it
/// are present on disk: the newest generation, since generations are
/// representations of one session and never additional consumption.
pub(super) fn canonical_sources(sources: BTreeMap<PathBuf, String>) -> BTreeMap<PathBuf, String> {
    licoup_agent_deepseek::session_store::newest_generation(sources)
}

/// The usage reader, as this pipeline holds it.
///
/// It carries no handle: the artifact is read whole, from the package that owns
/// the format, so there is no worker process to keep alive and nothing to shut
/// down between sources.
#[derive(Default)]
pub(super) struct Reader;

impl Reader {
    pub(super) fn parse(
        &mut self,
        path: &Path,
        size: u64,
        calendar: &UsageWindow,
    ) -> Result<ParseResult> {
        let samples = licoup_agent_deepseek::session_store::read_usage_samples(path)
            .map_err(anyhow::Error::from)
            .context(ReadFailure("session-read"))?;
        summarize_samples(samples, size, calendar)
    }
}

/// One sample of the shape the package's own reader reports, kept here so this
/// module's tests can describe a fold without the vendor's file format.
#[cfg(test)]
fn parse_samples(bytes: &[u8], size: u64, calendar: &UsageWindow) -> Result<ParseResult> {
    let samples: Vec<licoup_agent_deepseek::session_store::UsageSample> =
        serde_json::from_slice(bytes)?;
    summarize_samples(samples, size, calendar)
}

/// Fold the package's own samples into this pipeline's accounting.
fn summarize_samples(
    samples: Vec<licoup_agent_deepseek::session_store::UsageSample>,
    size: u64,
    calendar: &UsageWindow,
) -> Result<ParseResult> {
    let mut summary = HistoryUsageSummary::default();
    let mut saw_session = false;
    for sample in samples {
        let Some(day) = calendar
            .date_key(&sample.time.to_string())
            .filter(|day| calendar.contains(day))
        else {
            continue;
        };
        saw_session = true;
        let model = model_label(&json!({"model": sample.model, "providerId": sample.provider}));
        let variant = UsageVariant::from_metadata(&json!({"reasoningEffort": sample.effort}));
        if let Some(mut usage) = sample.usage.as_ref().and_then(exact_usage) {
            usage.model = model;
            usage.variant = variant;
            summary.add(usage, Some(day));
        } else {
            summary.add_token_unavailable_request_with_variant(Some(day), model, variant);
        }
    }
    summary.session_count = u64::from(saw_session);
    Ok(ParseResult {
        session_increment: summary.session_count,
        summary,
        parsed_bytes: size,
        ..Default::default()
    })
}

/// Harness uses disjoint input/cache buckets; reasoning is a subset of output.
/// Its public session meter aggregates absent optional cache buckets as zero.
/// Retain those reported counts even when a full-call total was not recorded;
/// supplied totals and counts must still satisfy the consistency checks below.
fn exact_usage(value: &Value) -> Option<MessageUsage> {
    let count = |key| {
        value
            .get(key)?
            .as_u64()
            .filter(|count| *count <= MAX_SAFE_INTEGER)
    };
    let input = count("inputTokens")?;
    let output = count("outputTokens")?;
    let optional = |key| {
        if value.get(key).is_some() {
            count(key).map(Some)
        } else {
            Some(None)
        }
    };
    let read = optional("cacheReadTokens")?;
    let write = optional("cacheWriteTokens")?;
    let reasoning = optional("reasoningTokens")?;
    if reasoning.is_some_and(|reasoning| reasoning > output) {
        return None;
    }
    let known_prompt = input
        .checked_add(read.unwrap_or(0))?
        .checked_add(write.unwrap_or(0))?;
    let total = optional("totalTokens")?.or_else(|| known_prompt.checked_add(output))?;
    if total > MAX_SAFE_INTEGER {
        return None;
    }
    let prompt = total.checked_sub(output)?;
    if prompt < known_prompt || (read.is_some() && write.is_some() && prompt != known_prompt) {
        return None;
    }
    Some(MessageUsage {
        prompt_tokens: prompt,
        cached_input_tokens: read.unwrap_or(0),
        completion_tokens: output,
        total_tokens: total,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_disjoint_buckets_include_reasoning_once_and_refuse_inconsistent_totals() {
        let usage = exact_usage(&json!({"inputTokens":70,"cacheReadTokens":30,"outputTokens":20,"reasoningTokens":15,"totalTokens":120})).unwrap();
        assert_eq!(
            (
                usage.prompt_tokens,
                usage.cached_input_tokens,
                usage.completion_tokens,
                usage.total_tokens
            ),
            (100, 30, 20, 120)
        );
        let meter = exact_usage(
            &json!({"inputTokens":70,"cacheReadTokens":30,"outputTokens":20,"reasoningTokens":15}),
        )
        .unwrap();
        assert_eq!(
            (
                meter.prompt_tokens,
                meter.cached_input_tokens,
                meter.completion_tokens,
                meter.total_tokens
            ),
            (100, 30, 20, 120)
        );
        assert_eq!(
            exact_usage(&json!({"inputTokens":70,"outputTokens":20}))
                .unwrap()
                .total_tokens,
            90
        );
        assert!(
            exact_usage(&json!({"inputTokens":70,"outputTokens":20,"cacheReadTokens":-1}))
                .is_none()
        );
        assert!(
            exact_usage(&json!({"inputTokens":70,"outputTokens":20,"cacheWriteTokens":null}))
                .is_none()
        );
        assert!(exact_usage(&json!({"inputTokens":70,"outputTokens":1.5})).is_none());
        assert!(
            exact_usage(&json!({"inputTokens":9007199254740991_u64,"outputTokens":1})).is_none()
        );
        assert!(
            exact_usage(
                &json!({"inputTokens":70,"outputTokens":20,"reasoningTokens":21,"totalTokens":90})
            )
            .is_none()
        );
        assert!(exact_usage(&json!({"inputTokens":70,"cacheReadTokens":30,"cacheWriteTokens":0,"outputTokens":20,"totalTokens":121})).is_none());
        assert_eq!(exact_usage(&json!({"inputTokens":70,"cacheReadTokens":30,"cacheWriteTokens":4,"outputTokens":20})).unwrap().total_tokens,124);
    }

    #[test]
    fn canonical_generation_has_one_stable_session_source() {
        let sources = [
            "session.jsonl.zstd",
            "session.v1.jsonl.zstd",
            "session.v3.jsonl.zstd",
            "session.v03.jsonl.zstd",
            "session.v4.jsonl.zstd.tmp",
        ]
        .into_iter()
        .map(|name| (PathBuf::from("root/project/id").join(name), "test".into()))
        .collect();
        let selected = canonical_sources(sources);
        assert_eq!(selected.len(), 1);
        assert_eq!(
            selected.first_key_value().unwrap().0.file_name().unwrap(),
            "session.v3.jsonl.zstd"
        );
    }

    #[test]
    fn exact_snapshot_replacement_and_reopen_keep_tokens_requests_and_effort_once() {
        use super::super::cache::{RefreshStatements, aggregate_usage, open_cache_database};
        let root =
            std::env::temp_dir().join(format!("licoup-harness-cache-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("usage.sqlite");
        let calendar = UsageWindow::from_params(
            &json!({"now":"2026-07-15T12:00:00Z", "historyDays":1, "timezoneOffsetMinutes":480}),
        );
        let initial = json!({"samples":[
            {"time":1784109600000_u64,"model":"deepseek-native","provider":"deepseek-official","effort":"high","usage":{"inputTokens":70,"cacheReadTokens":30,"outputTokens":20,"reasoningTokens":15}},
            {"time":1784109600001_u64,"model":"deepseek-native","provider":"deepseek-official","usage":null}
        ]});
        let parsed = parse_samples(&serde_json::to_vec(&initial).unwrap(), 100, &calendar).unwrap();
        assert_eq!(parsed.summary.total_tokens(), 120);
        assert_eq!(parsed.summary.token_unavailable_records, 1);
        let mut changed = initial.clone();
        changed["samples"].as_array_mut().unwrap().push(json!({"time":1784109600002_u64,"model":"deepseek-native","provider":"deepseek-official","effort":"low","usage":{"inputTokens":4,"outputTokens":2,"totalTokens":6}}));
        let changed =
            parse_samples(&serde_json::to_vec(&changed).unwrap(), 200, &calendar).unwrap();
        let mut connection = open_cache_database(&path).unwrap();
        // Re-reading an unchanged generation and publishing its successor both
        // replace this session's mutable daily row rather than append old usage.
        for summary in [&parsed.summary, &parsed.summary, &changed.summary] {
            let transaction = connection.transaction().unwrap();
            let mut statements = RefreshStatements::prepare(&transaction).unwrap();
            statements
                .replace_rollup("scope", "session", summary)
                .unwrap();
            drop(statements);
            transaction.commit().unwrap();
        }
        drop(connection);
        let mut connection = open_cache_database(&path).unwrap();
        let summary = aggregate_usage(&mut connection, "scope", &calendar).unwrap();
        assert_eq!(summary.total_tokens(), 126);
        assert_eq!(summary.estimated_records, 0);
        assert_eq!(summary.token_unavailable_records, 1);
        let day = &summary.daily_usage["2026-07-15"];
        assert_eq!(day.request_count, 3);
        assert_eq!(
            day.model_variants
                .values()
                .map(|usage| usage.total_tokens)
                .sum::<u64>(),
            126
        );
        assert_eq!(
            day.model_variants
                .values()
                .map(|usage| usage.request_count)
                .sum::<u64>(),
            3
        );
        assert_eq!(
            day.model_variants
                .iter()
                .find(|((_, variant), _)| variant.effort.as_deref() == Some("high"))
                .unwrap()
                .1
                .total_tokens,
            120
        );
        assert_eq!(
            day.model_variants
                .iter()
                .find(|((_, variant), _)| variant.effort.as_deref() == Some("low"))
                .unwrap()
                .1
                .total_tokens,
            6
        );
        drop(connection);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn harness_history_roots_honor_explicit_home_without_loading_configuration() {
        use crate::domain::conversation::source_catalog::{HistoryAdapter, history_roots};
        let root = PathBuf::from("fixture").join("harness");
        let roots = history_roots(
            HistoryAdapter::DeepSeekHarness,
            &json!({"homeDir":"fixture-home", "deepseekHarnessHome":root}),
        );
        assert_eq!(roots.len(), 1);
        assert_eq!(roots[0].path, root.join("sessions"));
        assert_eq!(roots[0].source_kind, "deepseek-harness-session-store");
    }
}
