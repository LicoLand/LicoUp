use super::super::contract::text_field;
use super::super::window::UsageWindow;
use super::event_hash::advance_event_chain;
use super::models::{ParserState, TokenTotals};
use super::utils::{to_i64, turn_id};
use anyhow::{Context, Result};
use rusqlite::{Statement, Transaction, params};
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;

pub(super) struct ParserBatch<'connection> {
    insert_usage: Statement<'connection>,
}

impl<'connection> ParserBatch<'connection> {
    pub(super) fn new(transaction: &'connection Transaction<'_>) -> Result<Self> {
        Ok(Self {
            insert_usage: transaction.prepare(
                "INSERT OR REPLACE INTO usage_rows(
                   root_key, source_key, event_index, session_id, turn_id, day, model,
                   input_tokens, cached_input_tokens, output_tokens, event_identity
                 ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            )?,
        })
    }

    pub(super) fn parse_file(
        &mut self,
        root_key: &str,
        source_key: &str,
        path: &Path,
        start_offset: u64,
        window: &UsageWindow,
        state: &mut ParserState,
    ) -> Result<u64> {
        let mut file = fs::File::open(path).context("Codex usage file open failed")?;
        file.seek(SeekFrom::Start(start_offset))?;
        let mut reader = BufReader::new(file);
        let mut line = String::new();
        let mut parsed_bytes = start_offset;
        loop {
            line.clear();
            let line_start = reader.stream_position()?;
            let read = reader.read_line(&mut line)?;
            if read == 0 {
                break;
            }
            let complete_line =
                line.ends_with('\n') || serde_json::from_str::<Value>(line.trim()).is_ok();
            if !complete_line {
                return Ok(line_start);
            }
            self.parse_line(root_key, source_key, &line, window, state)?;
            parsed_bytes = reader.stream_position()?;
        }
        Ok(parsed_bytes)
    }

    fn parse_line(
        &mut self,
        root_key: &str,
        source_key: &str,
        line: &str,
        window: &UsageWindow,
        state: &mut ParserState,
    ) -> Result<()> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            return Ok(());
        };
        let event_type = value
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let payload = value.get("payload").unwrap_or(&Value::Null);
        if event_type == "session_meta" {
            if state.session_id.is_none() {
                state.session_id = text_field(payload, &["session_id", "sessionId", "id"])
                    .or_else(|| text_field(&value, &["session_id", "sessionId", "id"]));
            }
            if state.forked_from_id.is_none() {
                state.forked_from_id = text_field(
                    payload,
                    &[
                        "forked_from_id",
                        "forkedFromId",
                        "parent_session_id",
                        "parentSessionId",
                    ],
                );
            }
            return Ok(());
        }
        match event_type {
            "turn_context" => {
                if let Some(model) = text_field(
                    payload,
                    &["model", "model_name", "modelName", "model_id", "modelId"],
                ) {
                    state.current_model = Some(model);
                }
                return Ok(());
            }
            "event_msg" => {}
            _ => return Ok(()),
        }
        let payload_type = payload
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if payload_type == "task_started" {
            state.current_turn_id = turn_id(payload);
            return Ok(());
        }
        if payload_type != "token_count" {
            return Ok(());
        }
        let Some(info) = payload.get("info") else {
            return Ok(());
        };
        let total = info
            .get("total_token_usage")
            .and_then(TokenTotals::from_value);
        let last = info
            .get("last_token_usage")
            .and_then(TokenTotals::from_value);
        if total.is_none() && last.is_none() {
            return Ok(());
        }
        let Some(day) = text_field(&value, &["timestamp", "createdAt", "created_at"])
            .or_else(|| text_field(payload, &["timestamp", "createdAt", "created_at"]))
            .and_then(|value| window.date_key(&value))
        else {
            return Ok(());
        };
        let model = state
            .current_model
            .clone()
            .or_else(|| text_field(info, &["model", "model_name", "modelName"]))
            .or_else(|| text_field(payload, &["model", "model_name", "modelName"]));
        let raw_baseline = state.raw_totals;
        let counted_baseline = state.counted_totals.unwrap_or_default();
        let delta = match (last, total) {
            (Some(last), Some(total)) => {
                if raw_baseline.is_none() && state.forked_from_id.is_some() && total == last {
                    TokenTotals::default()
                } else {
                    let total_delta = total.saturating_delta(raw_baseline.unwrap_or_default());
                    if raw_baseline == Some(total) {
                        TokenTotals::default()
                    } else if raw_baseline.is_some()
                        && !state.has_divergent_totals
                        && total.at_least(raw_baseline.unwrap_or_default())
                        && total_delta.at_most(last)
                    {
                        total_delta
                    } else {
                        last
                    }
                }
            }
            (Some(last), None) => last,
            (None, Some(total)) => {
                if let Some(raw_baseline) = raw_baseline {
                    total.saturating_delta(raw_baseline)
                } else if state.forked_from_id.is_some() {
                    TokenTotals::default()
                } else {
                    total
                }
            }
            (None, None) => TokenTotals::default(),
        };
        if let Some(total) = total {
            state.raw_totals = Some(total);
        } else {
            state.raw_totals = Some(counted_baseline.add(delta));
        }
        state.counted_totals = Some(counted_baseline.add(delta));
        state.has_divergent_totals = state.raw_totals != state.counted_totals;
        if delta.is_zero() {
            return Ok(());
        }
        let event_index = state.next_event_index;
        state.next_event_index = state.next_event_index.saturating_add(1);
        let event_identity = advance_event_chain(
            &mut state.token_chain_hash,
            b"codex-token-chain-v1\0",
            &value,
        );
        if !window.contains(&day) {
            return Ok(());
        }
        let session_id = state.session_id.clone();
        let turn_id = turn_id(payload).or_else(|| state.current_turn_id.clone());
        self.insert_usage.execute(params![
            root_key,
            source_key,
            to_i64(event_index),
            session_id,
            turn_id,
            day,
            model,
            to_i64(delta.input),
            to_i64(delta.cached.min(delta.input)),
            to_i64(delta.output),
            event_identity,
        ])?;
        Ok(())
    }
}
