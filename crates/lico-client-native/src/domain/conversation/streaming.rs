//! JSON-lines streaming projection for native conversation history.

use super::adapter_dispatch::parse_history_file;
use super::history::{
    CONVERSATION_SCHEMA_VERSION, HistoryScanConfig, apply_codex_session_index_titles,
    dedupe_history_sessions, finalize_history_sessions, history_session_dedupe_key,
    paged_history_sessions, sort_sessions_by_updated_at,
};
use super::history_discovery::discover_history_files;
use super::parameters::agent_param;
use super::source_catalog::{HistoryAdapter, adapter_for_agent, history_roots};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs;
use std::io::Write;

pub(crate) fn conversation_stream(params: &Value) -> Result<()> {
    let stdout = std::io::stdout();
    let mut writer = stdout.lock();
    stream_to_writer(params, &mut writer)
}

fn stream_to_writer<W: Write>(params: &Value, writer: &mut W) -> Result<()> {
    let agent_id = agent_param(params)?;
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported native history adapter: {}", agent_id))?;
    let scan_config = HistoryScanConfig::from_params(params);
    if adapter == HistoryAdapter::Codex {
        return stream_codex_finalized(params, writer, &agent_id, adapter, &scan_config);
    }
    let roots = history_roots(adapter, params);
    let discovery = discover_history_files(adapter, &roots, scan_config.discovery_options());
    let mut candidates = discovery.candidates;
    let skipped_count = discovery.skipped.len();
    let files_seen = discovery.files_seen;
    let candidate_files = candidates.len();
    candidates.sort_by(|left, right| {
        right
            .modified_at
            .cmp(&left.modified_at)
            .then_with(|| left.path.cmp(&right.path))
    });

    write_json_line(
        writer,
        &json!({
            "event": "start",
            "ok": true,
            "schemaVersion": CONVERSATION_SCHEMA_VERSION,
            "mode": "native-history",
            "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
            "importMode": "precise-adapter",
            "readOnly": true,
            "agentId": agent_id,
            "adapterId": adapter.id(),
            "adapterLabel": adapter.label(),
            "sources": {
                "filesSeen": files_seen,
                "candidateFiles": candidate_files,
                "skippedCount": skipped_count
            },
            "page": {
                "offset": scan_config.page.offset,
                "limit": scan_config.page.limit
            }
        }),
    )?;

    let mut emitted_session_keys = BTreeSet::<String>::new();
    let mut matched_sessions = 0usize;
    let mut returned_sessions = 0usize;
    let mut has_more = false;
    'candidate_loop: for candidate in candidates {
        let metadata = match fs::metadata(&candidate.path) {
            Ok(metadata) => metadata,
            Err(_) => {
                write_json_line(
                    writer,
                    &json!({
                        "event": "skip",
                        "ok": true,
                        "reason": "metadata_failed"
                    }),
                )?;
                continue;
            }
        };
        let sessions = parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        );
        let mut sessions = finalize_history_sessions(sessions, &scan_config);
        sort_sessions_by_updated_at(&mut sessions);
        for session in sessions {
            if !emitted_session_keys.insert(history_session_dedupe_key(&session)) {
                continue;
            }
            let current_index = matched_sessions;
            matched_sessions = matched_sessions.saturating_add(1);
            if current_index < scan_config.page.offset {
                continue;
            }
            if let Some(end) = scan_config.page.end()
                && current_index >= end
            {
                has_more = true;
                break 'candidate_loop;
            }
            write_json_line(
                writer,
                &json!({
                    "event": "session",
                    "ok": true,
                    "agentId": agent_id,
                    "session": session
                }),
            )?;
            returned_sessions = returned_sessions.saturating_add(1);
            if scan_config.has_single_session_filter() {
                break 'candidate_loop;
            }
        }
    }

    write_done(
        writer,
        &agent_id,
        &scan_config,
        returned_sessions,
        matched_sessions,
        has_more,
    )
}

fn stream_codex_finalized<W: Write>(
    params: &Value,
    writer: &mut W,
    agent_id: &str,
    adapter: HistoryAdapter,
    scan_config: &HistoryScanConfig,
) -> Result<()> {
    let roots = history_roots(adapter, params);
    let discovery = discover_history_files(adapter, &roots, scan_config.discovery_options());
    let files_seen = discovery.files_seen;
    let directory_entries_seen = discovery.directory_entries_seen;
    let candidate_files = discovery.candidates.len();
    let mut skipped_count = discovery.skipped.len();
    let mut sessions = Vec::<Value>::new();
    for candidate in discovery.candidates {
        let metadata = match fs::metadata(&candidate.path) {
            Ok(metadata) => metadata,
            Err(_) => {
                skipped_count = skipped_count.saturating_add(1);
                continue;
            }
        };
        sessions.extend(parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        ));
    }
    if !scan_config.has_single_session_filter() {
        apply_codex_session_index_titles(params, &mut sessions);
    }
    let mut sessions = dedupe_history_sessions(finalize_history_sessions(sessions, scan_config));
    sort_sessions_by_updated_at(&mut sessions);
    let total_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);
    let page = paged_history_sessions(sessions, &scan_config.page);
    let returned_sessions = page.len();

    write_json_line(
        writer,
        &json!({
            "event": "start",
            "ok": true,
            "schemaVersion": CONVERSATION_SCHEMA_VERSION,
            "mode": "native-history",
            "scanMode": if scan_config.archive_mode { "archive" } else { "browse" },
            "importMode": "precise-adapter",
            "readOnly": true,
            "agentId": agent_id,
            "adapterId": adapter.id(),
            "adapterLabel": adapter.label(),
            "sources": {
                "filesSeen": files_seen,
                "directoryEntriesSeen": directory_entries_seen,
                "candidateFiles": candidate_files,
                "skippedCount": skipped_count
            },
            "page": {
                "offset": scan_config.page.offset,
                "limit": scan_config.page.limit
            }
        }),
    )?;
    for session in page {
        write_json_line(
            writer,
            &json!({
                "event": "session",
                "ok": true,
                "agentId": agent_id,
                "session": session
            }),
        )?;
    }
    write_done(
        writer,
        agent_id,
        scan_config,
        returned_sessions,
        total_sessions,
        has_more,
    )
}

fn write_done<W: Write>(
    writer: &mut W,
    agent_id: &str,
    scan_config: &HistoryScanConfig,
    returned_sessions: usize,
    scanned_sessions: usize,
    has_more: bool,
) -> Result<()> {
    write_json_line(
        writer,
        &json!({
            "event": "done",
            "ok": true,
            "schemaVersion": CONVERSATION_SCHEMA_VERSION,
            "agentId": agent_id,
            "page": {
                "offset": scan_config.page.offset,
                "limit": scan_config.page.limit,
                "returned": returned_sessions,
                "scannedSessions": scanned_sessions,
                "hasMore": has_more
            }
        }),
    )
}

fn write_json_line<W: Write>(writer: &mut W, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *writer, value)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        std::env::temp_dir().join(format!("lico-conversation-stream-{nonce}"))
    }

    #[test]
    fn stream_has_start_session_done_frames_and_bounded_page() {
        let root = temp_root();
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("sessions.json"),
            br#"{"sessions":[{"sessionId":"one","messages":[{"role":"user","text":"one"}]},{"sessionId":"two","messages":[{"role":"user","text":"two"}]}]}"#,
        )
        .unwrap();
        let mut output = Vec::<u8>::new();
        stream_to_writer(
            &json!({
                "agent": "opencode",
                "root": root.to_string_lossy(),
                "limit": 1
            }),
            &mut output,
        )
        .unwrap();
        let frames = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(frames.len(), 3);
        assert_eq!(frames[0]["event"], "start");
        assert_eq!(frames[1]["event"], "session");
        assert_eq!(frames[2]["event"], "done");
        assert_eq!(frames[2]["page"]["returned"], 1);
        assert_eq!(frames[2]["page"]["hasMore"], true);
        fs::remove_dir_all(root).unwrap();
    }
}
