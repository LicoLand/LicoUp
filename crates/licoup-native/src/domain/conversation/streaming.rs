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

const CODEX_PROGRESSIVE_MILESTONES: [usize; 3] = [3, 10, 20];

pub(crate) fn conversation_stream(params: &Value) -> Result<()> {
    let stdout = std::io::stdout();
    let mut writer = stdout.lock();
    stream_to_writer(params, &mut writer)
}

fn stream_to_writer<W: Write>(params: &Value, writer: &mut W) -> Result<()> {
    if crate::platform::remote_acp_history::has_runtime_connection(params) {
        return stream_remote_acp(params, writer);
    }
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

fn stream_remote_acp<W: Write>(params: &Value, writer: &mut W) -> Result<()> {
    let listed = crate::platform::remote_acp_history::conversation_list(params)?;
    let agent_id = listed
        .get("agentId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("remote_acp_history_projection_invalid"))?;
    let page = listed
        .get("page")
        .cloned()
        .ok_or_else(|| anyhow!("remote_acp_history_projection_invalid"))?;
    write_json_line(
        writer,
        &json!({
            "event": "start",
            "ok": true,
            "schemaVersion": CONVERSATION_SCHEMA_VERSION,
            "mode": "native-history",
            "scanMode": "browse",
            "importMode": "precise-adapter",
            "readOnly": true,
            "agentId": agent_id,
            "adapterId": listed.get("adapterId"),
            "adapterLabel": listed.get("adapterLabel"),
            "sources": listed.get("sources"),
            "page": page
        }),
    )?;
    let sessions = listed
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("remote_acp_history_projection_invalid"))?;
    for session in sessions {
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
    write_json_line(
        writer,
        &json!({
            "event": "done",
            "ok": true,
            "schemaVersion": CONVERSATION_SCHEMA_VERSION,
            "agentId": agent_id,
            "page": page
        }),
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
    let mut candidates = discovery.candidates;
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

    let progressive_enabled = !scan_config.has_single_session_filter()
        && scan_config.page.offset == 0
        && !scan_config.archive_mode;
    let progressive_limit = scan_config.page.limit.unwrap_or(usize::MAX);
    let mut next_milestone = 0usize;
    let mut progressive_emitted = 0usize;
    let mut raw_sessions = Vec::<Value>::new();
    for candidate in candidates {
        let metadata = match fs::metadata(&candidate.path) {
            Ok(metadata) => metadata,
            Err(_) => {
                skipped_count = skipped_count.saturating_add(1);
                continue;
            }
        };
        raw_sessions.extend(parse_history_file(
            adapter,
            &candidate.path,
            &candidate.source_kind,
            &metadata,
            scan_config.clone(),
        ));
        while progressive_enabled && next_milestone < CODEX_PROGRESSIVE_MILESTONES.len() {
            let milestone = CODEX_PROGRESSIVE_MILESTONES[next_milestone];
            if milestone > progressive_limit {
                next_milestone = CODEX_PROGRESSIVE_MILESTONES.len();
                break;
            }
            let snapshot = finalized_codex_sessions(params, &raw_sessions, scan_config);
            if snapshot.len() < milestone {
                break;
            }
            write_session_events(
                writer,
                agent_id,
                snapshot
                    .into_iter()
                    .skip(progressive_emitted)
                    .take(milestone.saturating_sub(progressive_emitted)),
                "session-preview",
                Some(milestone),
            )?;
            progressive_emitted = milestone;
            next_milestone += 1;
        }
    }
    let sessions = finalized_codex_sessions(params, &raw_sessions, scan_config);
    let total_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);
    let page = paged_history_sessions(sessions, &scan_config.page);
    let returned_sessions = page.len();
    write_session_events(writer, agent_id, page, "session", None)?;
    write_done(
        writer,
        agent_id,
        scan_config,
        returned_sessions,
        total_sessions,
        has_more,
    )
}

fn finalized_codex_sessions(
    params: &Value,
    raw_sessions: &[Value],
    scan_config: &HistoryScanConfig,
) -> Vec<Value> {
    let mut sessions = raw_sessions.to_vec();
    if !scan_config.has_single_session_filter() {
        apply_codex_session_index_titles(params, &mut sessions);
    }
    let mut sessions = dedupe_history_sessions(finalize_history_sessions(sessions, scan_config));
    sort_sessions_by_updated_at(&mut sessions);
    sessions
}

fn write_session_events<W, I>(
    writer: &mut W,
    agent_id: &str,
    sessions: I,
    event: &str,
    milestone: Option<usize>,
) -> Result<()>
where
    W: Write,
    I: IntoIterator<Item = Value>,
{
    for session in sessions {
        write_json_line(
            writer,
            &json!({
                "event": event,
                "ok": true,
                "agentId": agent_id,
                "session": session,
                "milestone": milestone
            }),
        )?;
    }
    Ok(())
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

    #[test]
    fn codex_stream_emits_three_ten_twenty_previews_before_final_catalog() {
        let root = temp_root();
        fs::create_dir_all(&root).unwrap();
        for index in 0..20 {
            let session_id = format!("progressive-session-{index:02}");
            let body = [
                json!({
                    "timestamp": format!("2026-07-20T00:00:{index:02}.000Z"),
                    "type": "session_meta",
                    "payload": {"id": session_id, "cwd": "/synthetic/workspace"}
                }),
                json!({
                    "timestamp": format!("2026-07-20T00:01:{index:02}.000Z"),
                    "type": "response_item",
                    "payload": {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": format!("Prompt {index}")}]
                    }
                }),
            ]
            .into_iter()
            .map(|line| line.to_string())
            .collect::<Vec<_>>()
            .join("\n");
            fs::write(root.join(format!("rollout-{index:02}.jsonl")), body).unwrap();
        }

        let mut output = Vec::<u8>::new();
        stream_to_writer(
            &json!({
                "agent": "codex",
                "root": root.to_string_lossy(),
                "limit": 21
            }),
            &mut output,
        )
        .unwrap();
        let frames = String::from_utf8(output)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        let previews = frames
            .iter()
            .filter(|frame| frame["event"] == "session-preview")
            .collect::<Vec<_>>();
        let sessions = frames
            .iter()
            .filter(|frame| frame["event"] == "session")
            .collect::<Vec<_>>();

        assert_eq!(previews.len(), 20);
        assert_eq!(previews[2]["milestone"], 3);
        assert_eq!(previews[9]["milestone"], 10);
        assert_eq!(previews[19]["milestone"], 20);
        assert_eq!(sessions.len(), 20);
        assert_eq!(frames.first().unwrap()["event"], "start");
        assert_eq!(frames.last().unwrap()["event"], "done");
        assert!(
            frames
                .iter()
                .position(|frame| frame["event"] == "session-preview")
                .unwrap()
                < frames
                    .iter()
                    .position(|frame| frame["event"] == "session")
                    .unwrap()
        );
        fs::remove_dir_all(root).unwrap();
    }
}
