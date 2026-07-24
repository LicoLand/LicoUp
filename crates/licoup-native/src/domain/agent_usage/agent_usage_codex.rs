mod aggregation;
mod append_guard;
mod cache;
mod cache_batch;
mod cache_cleanup;
mod constants;
mod event_hash;
mod file_collection;
mod lineage;
mod model_backfill;
mod models;
mod parser;
mod rollup;
mod scan;
mod scan_params;
mod utils;

#[cfg(test)]
mod tests;

use super::contract::HistoryUsageSummary;
use super::window::UsageWindow;
use serde_json::Value;

pub(super) fn summarize(
    scan_params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> Option<HistoryUsageSummary> {
    scan::summarize(scan_params, window, warnings)
}
