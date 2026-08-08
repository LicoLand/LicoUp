use super::super::contract::HistoryUsageSummary;
use serde_json::{Value, json};

#[derive(Clone, Debug)]
pub(super) struct SourceMetadata {
    pub(super) modified_ns: u64,
    pub(super) size: u64,
    pub(super) file_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) struct CumulativeTotals {
    pub(super) prompt: u64,
    pub(super) cached: u64,
    pub(super) completion: u64,
}

impl CumulativeTotals {
    pub(super) fn at_least(self, previous: Self) -> bool {
        self.prompt >= previous.prompt
            && self.cached >= previous.cached
            && self.completion >= previous.completion
    }

    pub(super) fn delta(self, previous: Self) -> Self {
        Self {
            prompt: self.prompt.saturating_sub(previous.prompt),
            cached: self.cached.saturating_sub(previous.cached),
            completion: self.completion.saturating_sub(previous.completion),
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(super) struct CachedSource {
    pub(super) modified_ns: u64,
    pub(super) size: u64,
    pub(super) file_id: Option<String>,
    pub(super) parsed_bytes: u64,
    pub(super) append_guard: String,
    pub(super) session_count: u64,
    pub(super) sealed: bool,
}

#[derive(Clone, Debug)]
pub(super) struct CumulativeSnapshot {
    pub(super) usage_key: String,
    pub(super) session_key: String,
    pub(super) model: Option<String>,
    pub(super) first_day: String,
    pub(super) observed_day: String,
    pub(super) totals: CumulativeTotals,
    pub(super) projects_usage: bool,
}

#[derive(Clone, Debug, Default)]
pub(super) struct ParseResult {
    pub(super) summary: HistoryUsageSummary,
    pub(super) parsed_bytes: u64,
    pub(super) cumulative_snapshots: Vec<CumulativeSnapshot>,
    pub(super) session_increment: u64,
}

#[derive(Clone, Debug, Default)]
pub(super) struct ScanStats {
    pub(super) discovered_sources: u64,
    pub(super) reused_sources: u64,
    pub(super) appended_sources: u64,
    pub(super) replaced_sources: u64,
    pub(super) sealed_sources: u64,
    pub(super) compacted_days: u64,
    pub(super) parsed_bytes: u64,
    pub(super) cache_fresh: bool,
    pub(super) rebuilt: bool,
}

impl ScanStats {
    pub(super) fn to_json(&self) -> Value {
        json!({
            "schemaVersion": super::cache::CACHE_SCHEMA_VERSION,
            "parserRevision": super::PARSER_REVISION,
            "fresh": self.cache_fresh,
            "discoveredSources": self.discovered_sources,
            "reusedSources": self.reused_sources,
            "appendedSources": self.appended_sources,
            "replacedSources": self.replaced_sources,
            "sealedSources": self.sealed_sources,
            "compactedDays": self.compacted_days,
            "parsedBytes": self.parsed_bytes,
            "rebuilt": self.rebuilt
        })
    }
}
