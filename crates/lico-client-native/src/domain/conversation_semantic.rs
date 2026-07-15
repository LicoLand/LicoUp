//! Canonical semantic conversation model for native agent history.
//!
//! Authority: `packages/contracts/client/semantic-conversation.schema.json`
//! Docs: `docs/contracts/semantic-conversation.md`
//!
//! Native source histories remain read-only. This module assembles and validates
//! the shared semantic document; it does not create a LicoLite-local conversation store.

use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

pub const SEMANTIC_SCHEMA_VERSION: u64 = 1;
pub const SEMANTIC_KIND: &str = "semantic-conversation";
pub const SEMANTIC_JSON: &str = "semantic.json";
pub const SEMANTIC_MD: &str = "semantic.md";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SemanticLayer {
    Thread,
    Execution,
    Artifacts,
    Audit,
    Raw,
}

impl SemanticLayer {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Thread => "thread",
            Self::Execution => "execution",
            Self::Artifacts => "artifacts",
            Self::Audit => "audit",
            Self::Raw => "raw",
        }
    }
}

pub fn privacy_defaults() -> Value {
    json!({
        "defaultView": "thread",
        "hideRawInDefaultView": true,
        "hideAuditInDefaultView": true,
        "redactPaths": true,
        "redactTokens": true,
        "redactFullCommandPayloads": true
    })
}

pub fn layer_for_history_kind(kind: &str) -> SemanticLayer {
    match kind {
        "tool_call" | "tool-call" | "tool_result" | "tool-result" | "reasoning" | "metadata"
        | "error" | "event" | "terminal" | "plan" | "progress" | "retry" => {
            SemanticLayer::Execution
        }
        "artifact" | "file" | "diff" | "document" => SemanticLayer::Artifacts,
        "audit" => SemanticLayer::Audit,
        "raw" => SemanticLayer::Raw,
        _ => SemanticLayer::Thread,
    }
}

pub fn execution_event_kind(card_type: &str, source_item_type: &str) -> &'static str {
    let semantic = if !source_item_type.trim().is_empty() {
        source_item_type
    } else {
        card_type
    };
    let normalized = normalize_token(semantic);
    if normalized.contains("terminal")
        || normalized.contains("run-command")
        || normalized.contains("shell")
        || normalized.contains("bash")
    {
        return "terminal";
    }
    if normalized.contains("plan") {
        return "plan";
    }
    if normalized.contains("progress") || normalized.contains("status") {
        return "progress";
    }
    if normalized.contains("retry") {
        return "retry";
    }
    if normalized.contains("error") || normalized.contains("failure") {
        return "error";
    }
    if normalized.contains("reasoning") || normalized.contains("thinking") {
        return "reasoning";
    }
    if normalized.contains("tool-result")
        || normalized.contains("tool_result")
        || normalized.contains("function-call-output")
        || normalized.contains("function-result")
    {
        return "tool-result";
    }
    if normalized.contains("tool") || normalized.contains("function") {
        return "tool-call";
    }
    "event"
}

pub fn evidence_kind_from_source(source_kind: &str) -> &'static str {
    match source_kind.trim().to_ascii_lowercase().as_str() {
        "jsonl" => "jsonl",
        "json" => "json",
        "sqlite" | "sqlite-row" | "db" => "sqlite-row",
        "md" | "markdown" => "markdown",
        "txt" | "text" => "text",
        _ => "unknown",
    }
}

pub fn hash_text(content: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    format!("{:x}", hasher.finalize())
}

pub fn synthetic_path_ref(adapter_id: &str, native_session_id: &str, source_kind: &str) -> String {
    format!(
        "fixture://{}/{}.{}",
        sanitize_ref_token(adapter_id),
        sanitize_ref_token(native_session_id),
        match evidence_kind_from_source(source_kind) {
            "jsonl" => "jsonl",
            "json" => "json",
            "sqlite-row" => "sqlite",
            "markdown" => "md",
            "text" => "txt",
            _ => "bin",
        }
    )
}

/// Build the canonical semantic document from tagged timeline messages.
///
/// `messages` are the adapter-emitted timeline events (already privacy-cleaned).
/// Metadata-only / environment-context records must already be excluded from thread.
pub fn build_semantic_conversation(
    messages: &[Value],
    audit: SemanticAuditInput<'_>,
) -> Result<Value> {
    let mut thread = Vec::new();
    let mut execution = Vec::new();
    let mut artifacts = Vec::new();
    let mut parse_warnings = audit.parse_warnings.to_vec();

    for message in messages {
        let layer = message
            .get("layer")
            .and_then(Value::as_str)
            .unwrap_or_else(|| infer_layer_from_message(message));
        match layer {
            "thread" => {
                if let Some(mut event) = thread_event_from_message(message) {
                    if let Some(object) = event.as_object_mut()
                        && let Some(text) = object.get("text").and_then(Value::as_str)
                    {
                        object.insert("text".to_string(), json!(sanitize_default_view_text(text)));
                    }
                    if event
                        .get("text")
                        .and_then(Value::as_str)
                        .is_some_and(|text| !text.trim().is_empty())
                    {
                        thread.push(event);
                    } else {
                        parse_warnings
                            .push("thread candidate dropped after privacy filter".to_string());
                    }
                } else {
                    parse_warnings
                        .push("thread candidate dropped after privacy filter".to_string());
                }
            }
            "execution" => {
                if let Some(mut event) = execution_event_from_message(message) {
                    if let Some(object) = event.as_object_mut()
                        && let Some(text) = object.get("summary").and_then(Value::as_str)
                    {
                        object.insert(
                            "summary".to_string(),
                            json!(sanitize_default_view_text(text)),
                        );
                    }
                    execution.push(event);
                }
            }
            "artifacts" => {
                if let Some(mut event) = artifact_from_message(message) {
                    if let Some(object) = event.as_object_mut()
                        && let Some(reference) = object.get("ref").and_then(Value::as_str)
                    {
                        object.insert("ref".to_string(), json!(redact_path_ref(reference)));
                    }
                    artifacts.push(event);
                }
            }
            "audit" | "raw" => {
                parse_warnings.push(format!(
                    "{}-layer message excluded from default timeline projection",
                    layer
                ));
            }
            other => {
                parse_warnings.push(format!("unknown layer `{other}` ignored"));
            }
        }
    }

    let path_ref = if audit.path_ref.trim().is_empty() {
        synthetic_path_ref(audit.adapter_id, audit.native_session_id, audit.source_kind)
    } else {
        redact_path_ref(audit.path_ref)
    };
    let content_hash = if audit.content_hash.trim().is_empty() {
        hash_text(&format!(
            "{}|{}|{}",
            audit.adapter_id, audit.native_session_id, path_ref
        ))
    } else {
        audit.content_hash.to_string()
    };
    let evidence = json!({
        "kind": evidence_kind_from_source(audit.source_kind),
        "pathRef": path_ref,
        "contentHash": content_hash,
        "byteLength": audit.byte_length
    });

    let semantic = json!({
        "schemaVersion": SEMANTIC_SCHEMA_VERSION,
        "kind": SEMANTIC_KIND,
        "readOnly": true,
        "privacyDefaults": privacy_defaults(),
        "thread": thread,
        "execution": execution,
        "artifacts": artifacts,
        "audit": {
            "adapterId": audit.adapter_id,
            "adapterLabel": audit.adapter_label,
            "hostApp": audit.host_app,
            "hostAppLabel": audit.host_app_label,
            "sourceClient": audit.source_client,
            "sourceKind": audit.source_kind,
            "nativeSessionId": audit.native_session_id,
            "importMode": "precise-adapter",
            "sourceEvidence": evidence.clone(),
            "parseWarnings": parse_warnings,
            "redactionStatus": audit.redaction_status,
            "validationStatus": audit.validation_status,
            "createdAt": audit.created_at,
            "updatedAt": audit.updated_at
        },
        "raw": {
            "evidenceRefs": [evidence]
        }
    });
    validate_semantic_conversation(&semantic)?;
    Ok(semantic)
}

pub struct SemanticAuditInput<'a> {
    pub adapter_id: &'a str,
    pub adapter_label: &'a str,
    pub host_app: &'a str,
    pub host_app_label: &'a str,
    pub source_client: &'a str,
    pub source_kind: &'a str,
    pub native_session_id: &'a str,
    pub path_ref: &'a str,
    pub content_hash: &'a str,
    pub byte_length: u64,
    pub parse_warnings: &'a [String],
    pub redaction_status: &'a str,
    pub validation_status: &'a str,
    pub created_at: &'a str,
    pub updated_at: &'a str,
}

/// Project thread + execution into the timeline `messages` array consumed by desktop UI.
/// Audit and raw layers are never projected into default messages.
pub fn timeline_messages_from_semantic(semantic: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    if let Some(thread) = semantic.get("thread").and_then(Value::as_array) {
        for event in thread {
            let role = event
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("assistant");
            // Preserve historical native wire role `agent` for assistant turns.
            let wire_role = if role == "assistant" { "agent" } else { role };
            out.push(json!({
                "id": event.get("id").cloned().unwrap_or_else(|| json!("")),
                "layer": "thread",
                "role": wire_role,
                "text": event.get("text").cloned().unwrap_or_else(|| json!("")),
                "createdAt": event.get("createdAt").cloned().unwrap_or_else(|| json!("")),
                "eventKind": event.get("eventKind").cloned().unwrap_or_else(|| json!(""))
            }));
        }
    }
    if let Some(execution) = semantic.get("execution").and_then(Value::as_array) {
        for event in execution {
            let event_kind = event
                .get("eventKind")
                .and_then(Value::as_str)
                .unwrap_or("event");
            let source_item_type = event
                .get("sourceItemType")
                .and_then(Value::as_str)
                .unwrap_or("");
            let (role, card_type) = match (event_kind, source_item_type) {
                (_, "metadata") => ("metadata", "metadata"),
                ("tool-call", _) => ("tool_call", "tool-call"),
                ("tool-result", _) => ("tool_result", "tool-result"),
                ("terminal", _) => ("tool_call", "tool-call"),
                ("reasoning", _) => ("reasoning", "reasoning"),
                ("error", _) => ("error", "error"),
                ("plan" | "progress" | "retry", _) => ("event", "event"),
                _ if source_item_type == "metadata" || event_kind == "metadata" => {
                    ("metadata", "metadata")
                }
                _ => ("event", "event"),
            };
            let mut message = json!({
                "id": event.get("id").cloned().unwrap_or_else(|| json!("")),
                "layer": "execution",
                "role": role,
                "text": event.get("summary").cloned().unwrap_or_else(|| json!("")),
                "createdAt": event.get("createdAt").cloned().unwrap_or_else(|| json!("")),
                "cardType": card_type,
                "cardTitle": event.get("title").cloned().unwrap_or_else(|| json!("")),
                "cardSubtitle": if role == "metadata" {
                    "Sensitive details hidden"
                } else if role == "reasoning" {
                    "Sensitive details hidden"
                } else {
                    "Native agent activity"
                },
                "collapsed": event.get("collapsed").cloned().unwrap_or_else(|| json!(true)),
                "eventKind": event_kind,
                "sourceItemType": source_item_type
            });
            if event.get("providerSummary") == Some(&json!(true))
                && let Some(object) = message.as_object_mut()
            {
                object.insert("providerSummary".to_string(), json!(true));
                object.insert("cardSubtitle".to_string(), json!("Reasoning summary"));
            }
            out.push(message);
        }
    }
    out
}

pub fn annotate_message_layer(message: &mut Value, layer: SemanticLayer) {
    if let Some(object) = message.as_object_mut() {
        object.insert("layer".to_string(), json!(layer.as_str()));
    }
}

pub fn validate_semantic_conversation(value: &Value) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("semantic conversation must be an object"))?;
    require_const_u64(object, "schemaVersion", SEMANTIC_SCHEMA_VERSION)?;
    require_const_str(object, "kind", SEMANTIC_KIND)?;
    require_const_bool(object, "readOnly", true)?;
    validate_privacy_defaults(object.get("privacyDefaults"))?;
    validate_thread(object.get("thread"))?;
    validate_execution(object.get("execution"))?;
    validate_artifacts(object.get("artifacts"))?;
    validate_audit(object.get("audit"))?;
    validate_raw(object.get("raw"))?;
    assert_no_default_view_leakage(value)?;
    Ok(())
}

pub fn render_semantic_markdown(semantic: &Value) -> String {
    let mut out = String::new();
    out.push_str("# Semantic Conversation\n\n");
    out.push_str("Default view: **thread**. Execution is collapsible. Audit and raw evidence are diagnostic-only.\n\n");

    out.push_str("## Thread\n\n");
    if let Some(thread) = semantic.get("thread").and_then(Value::as_array) {
        if thread.is_empty() {
            out.push_str("_No thread messages._\n\n");
        }
        for event in thread {
            let role = event
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("assistant");
            let text = event.get("text").and_then(Value::as_str).unwrap_or("");
            out.push_str(&format!("### {}\n\n{}\n\n", role_heading(role), text));
        }
    }

    out.push_str(
        "## Execution\n\n<details>\n<summary>Execution trace (collapsed by default)</summary>\n\n",
    );
    if let Some(execution) = semantic.get("execution").and_then(Value::as_array) {
        if execution.is_empty() {
            out.push_str("_No execution events._\n\n");
        }
        for event in execution {
            out.push_str(&format!(
                "- **{}** (`{}`): {}\n",
                event
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("Event"),
                event
                    .get("eventKind")
                    .and_then(Value::as_str)
                    .unwrap_or("event"),
                event.get("summary").and_then(Value::as_str).unwrap_or("")
            ));
        }
        out.push('\n');
    }
    out.push_str("</details>\n\n");

    out.push_str("## Artifacts\n\n");
    if let Some(artifacts) = semantic.get("artifacts").and_then(Value::as_array) {
        if artifacts.is_empty() {
            out.push_str("_No artifacts._\n\n");
        }
        for artifact in artifacts {
            out.push_str(&format!(
                "- `{}` ({}) → `{}`\n",
                artifact
                    .get("label")
                    .and_then(Value::as_str)
                    .unwrap_or("artifact"),
                artifact
                    .get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or("document"),
                artifact
                    .get("ref")
                    .and_then(Value::as_str)
                    .unwrap_or("(ref)")
            ));
        }
        out.push('\n');
    }

    out.push_str("## Audit (diagnostics)\n\n");
    if let Some(audit) = semantic.get("audit") {
        out.push_str(&format!(
            "- Adapter: `{}`\n- Host: `{}`\n- Source kind: `{}`\n- Native session: `{}`\n- Redaction: `{}`\n- Validation: `{}`\n",
            audit.get("adapterId").and_then(Value::as_str).unwrap_or(""),
            audit.get("hostApp").and_then(Value::as_str).unwrap_or(""),
            audit.get("sourceKind").and_then(Value::as_str).unwrap_or(""),
            audit.get("nativeSessionId").and_then(Value::as_str).unwrap_or(""),
            audit.get("redactionStatus").and_then(Value::as_str).unwrap_or(""),
            audit.get("validationStatus").and_then(Value::as_str).unwrap_or("")
        ));
        if let Some(evidence) = audit.get("sourceEvidence") {
            out.push_str(&format!(
                "- Evidence: `{}` hash=`{}`\n",
                evidence
                    .get("pathRef")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                evidence
                    .get("contentHash")
                    .and_then(Value::as_str)
                    .unwrap_or("")
            ));
        }
        if let Some(warnings) = audit.get("parseWarnings").and_then(Value::as_array)
            && !warnings.is_empty()
        {
            out.push_str("- Parse warnings:\n");
            for warning in warnings {
                if let Some(text) = warning.as_str() {
                    out.push_str(&format!("  - {}\n", text));
                }
            }
        }
        out.push('\n');
    }

    out.push_str("## Raw evidence (diagnostics)\n\n");
    if let Some(refs) = semantic
        .get("raw")
        .and_then(|raw| raw.get("evidenceRefs"))
        .and_then(Value::as_array)
    {
        for evidence in refs {
            out.push_str(&format!(
                "- `{}` (`{}`) hash=`{}`\n",
                evidence
                    .get("pathRef")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
                evidence
                    .get("kind")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
                evidence
                    .get("contentHash")
                    .and_then(Value::as_str)
                    .unwrap_or("")
            ));
        }
    }
    out
}

pub fn materialize_semantic_documents(
    conversation_dir: &Path,
    semantic: &Value,
) -> Result<(PathBuf, PathBuf, String)> {
    let json_path = conversation_dir.join(SEMANTIC_JSON);
    let md_path = conversation_dir.join(SEMANTIC_MD);
    let json_text = serde_json::to_string_pretty(semantic)?;
    fs::write(&json_path, format!("{}\n", json_text))?;
    fs::write(&md_path, render_semantic_markdown(semantic))?;
    Ok((json_path, md_path, hash_text(&json_text)))
}

pub fn load_and_validate_fixture(path: &Path) -> Result<Value> {
    let text = fs::read_to_string(path)?;
    let value: Value = serde_json::from_str(&text)?;
    validate_semantic_conversation(&value)?;
    Ok(value)
}

/// Project a tagged adapter message into the wire timeline while preserving order.
pub fn thread_wire_message_from_tagged(message: &Value) -> Option<Value> {
    let event = thread_event_from_message(message)?;
    let role = event
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("assistant");
    let wire_role = if role == "assistant" { "agent" } else { role };
    // Preserve transcript/record roles for legacy session filters when source used them.
    let original_role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let wire_role = if matches!(original_role, "transcript" | "record") {
        original_role
    } else {
        wire_role
    };
    let mut out = json!({
        "id": event.get("id").cloned().unwrap_or_else(|| json!("")),
        "layer": "thread",
        "role": wire_role,
        "text": event.get("text").cloned().unwrap_or_else(|| json!("")),
        "createdAt": event.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "eventKind": event.get("eventKind").cloned().unwrap_or_else(|| json!("")),
        "sourcePath": message.get("sourcePath").cloned().unwrap_or_else(|| json!(""))
    });
    if let Some(object) = out.as_object_mut() {
        for key in [
            "usage",
            "usageScope",
            "model",
            "sourceEventType",
            "sourceTable",
            "sourceKey",
            "sourceFields",
            "sourceMessageId",
        ] {
            if let Some(value) = message.get(key) {
                object.insert(key.to_string(), value.clone());
            }
        }
    }
    Some(out)
}

pub fn execution_wire_message_from_tagged(message: &Value) -> Option<Value> {
    let event = execution_event_from_message(message)?;
    let event_kind = event
        .get("eventKind")
        .and_then(Value::as_str)
        .unwrap_or("event");
    let source_item_type = event
        .get("sourceItemType")
        .and_then(Value::as_str)
        .unwrap_or("");
    let original_role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let original_card = message
        .get("cardType")
        .and_then(Value::as_str)
        .unwrap_or("");
    let (role, card_type) = if original_card == "metadata" || original_role == "metadata" {
        ("metadata", "metadata")
    } else if !original_card.is_empty() {
        (original_role, original_card)
    } else {
        match event_kind {
            "tool-call" => ("tool_call", "tool-call"),
            "tool-result" => ("tool_result", "tool-result"),
            "terminal" => ("tool_call", "tool-call"),
            "reasoning" => ("reasoning", "reasoning"),
            "error" => ("error", "error"),
            _ => ("event", "event"),
        }
    };
    let subtitle = if role == "metadata" || role == "reasoning" {
        message
            .get("cardSubtitle")
            .and_then(Value::as_str)
            .unwrap_or("Sensitive details hidden")
    } else {
        message
            .get("cardSubtitle")
            .and_then(Value::as_str)
            .unwrap_or("Native agent activity")
    };
    let mut out = json!({
        "id": event.get("id").cloned().unwrap_or_else(|| json!("")),
        "layer": "execution",
        "role": role,
        "text": event.get("summary").cloned().unwrap_or_else(|| json!("")),
        "createdAt": event.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "cardType": card_type,
        "cardTitle": message.get("cardTitle").cloned().unwrap_or_else(|| event.get("title").cloned().unwrap_or_else(|| json!(""))),
        "cardSubtitle": subtitle,
        "collapsed": message.get("collapsed").cloned().unwrap_or_else(|| event.get("collapsed").cloned().unwrap_or_else(|| json!(true))),
        "eventKind": event_kind,
        "sourceItemType": source_item_type,
        "sourcePath": message.get("sourcePath").cloned().unwrap_or_else(|| json!(""))
    });
    if let Some(object) = out.as_object_mut() {
        for key in [
            "providerSummary",
            "usage",
            "usageScope",
            "model",
            "sourceEventType",
            "sourceTable",
            "sourceKey",
            "sourceFields",
            "sourceMessageId",
            "subagentPrompt",
            "subagentTitle",
        ] {
            if let Some(value) = message.get(key) {
                object.insert(key.to_string(), value.clone());
            }
        }
        if message.get("providerSummary") == Some(&json!(true)) {
            object.insert("cardSubtitle".to_string(), json!("Reasoning summary"));
        }
        if let Some(children) = message.get("messages") {
            object.insert("messages".to_string(), children.clone());
        }
    }
    Some(out)
}

fn thread_event_from_message(message: &Value) -> Option<Value> {
    let raw_role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let role = if matches!(raw_role, "transcript" | "record") {
        "user"
    } else {
        normalize_thread_role(raw_role)?
    };
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return None;
    }
    Some(json!({
        "id": message.get("id").cloned().unwrap_or_else(|| json!("")),
        "layer": "thread",
        "role": role,
        "eventKind": if role == "user" { "user-message" } else { "assistant-message" },
        "text": text,
        "createdAt": message.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "sourceEventId": message.get("id").cloned().unwrap_or_else(|| json!(""))
    }))
}

fn execution_event_from_message(message: &Value) -> Option<Value> {
    let card_type = message
        .get("cardType")
        .and_then(Value::as_str)
        .unwrap_or("");
    let source_item_type = message
        .get("sourceItemType")
        .and_then(Value::as_str)
        .unwrap_or("");
    let role = message.get("role").and_then(Value::as_str).unwrap_or("");
    let event_kind =
        if card_type == "metadata" || role == "metadata" || source_item_type == "metadata" {
            "event"
        } else {
            execution_event_kind(card_type, source_item_type)
        };
    let effective_source = if source_item_type.trim().is_empty() {
        if card_type == "metadata" || role == "metadata" {
            "metadata"
        } else if !card_type.is_empty() {
            card_type
        } else {
            role
        }
    } else {
        source_item_type
    };
    let title = message
        .get("cardTitle")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(if effective_source == "metadata" {
            "Metadata"
        } else {
            "Native event"
        });
    let summary = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or("Native event details are hidden.");
    Some(json!({
        "id": message.get("id").cloned().unwrap_or_else(|| json!("")),
        "layer": "execution",
        "eventKind": event_kind,
        "title": title,
        "summary": summary,
        "createdAt": message.get("createdAt").cloned().unwrap_or_else(|| json!("")),
        "collapsed": message.get("collapsed").cloned().unwrap_or_else(|| json!(true)),
        "sourceItemType": effective_source,
        "providerSummary": message.get("providerSummary").cloned().unwrap_or_else(|| json!(false))
    }))
}

fn artifact_from_message(message: &Value) -> Option<Value> {
    let label = message
        .get("cardTitle")
        .or_else(|| message.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("Artifact");
    Some(json!({
        "id": message.get("id").cloned().unwrap_or_else(|| json!("")),
        "layer": "artifacts",
        "kind": "document",
        "label": label,
        "ref": message.get("sourcePath").and_then(Value::as_str).unwrap_or("artifact"),
        "contentHash": message.get("contentHash").cloned().unwrap_or_else(|| json!(""))
    }))
}

fn infer_layer_from_message(message: &Value) -> &'static str {
    if message
        .get("cardType")
        .and_then(Value::as_str)
        .is_some_and(|v| !v.is_empty())
    {
        return SemanticLayer::Execution.as_str();
    }
    let role = message.get("role").and_then(Value::as_str).unwrap_or("");
    match role {
        "user" | "human" | "assistant" | "agent" | "model" | "ai" => SemanticLayer::Thread.as_str(),
        "tool_call" | "tool_result" | "reasoning" | "metadata" | "error" | "event" => {
            SemanticLayer::Execution.as_str()
        }
        _ => SemanticLayer::Execution.as_str(),
    }
}

fn normalize_thread_role(role: &str) -> Option<&'static str> {
    match role.trim().to_ascii_lowercase().as_str() {
        "user" | "human" => Some("user"),
        "assistant" | "agent" | "model" | "ai" | "planner-response" | "planner_response"
        | "generic" => Some("assistant"),
        _ => None,
    }
}

fn validate_privacy_defaults(value: Option<&Value>) -> Result<()> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("privacyDefaults required"))?;
    require_const_str(object, "defaultView", "thread")?;
    require_const_bool(object, "hideRawInDefaultView", true)?;
    require_const_bool(object, "hideAuditInDefaultView", true)?;
    require_const_bool(object, "redactPaths", true)?;
    require_const_bool(object, "redactTokens", true)?;
    require_const_bool(object, "redactFullCommandPayloads", true)?;
    Ok(())
}

fn validate_thread(value: Option<&Value>) -> Result<()> {
    let items = value
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("thread must be an array"))?;
    for item in items {
        let object = item
            .as_object()
            .ok_or_else(|| anyhow!("thread event must be an object"))?;
        require_const_str(object, "layer", "thread")?;
        require_non_empty(object, "id")?;
        require_enum(object, "role", &["user", "assistant"])?;
        require_enum(object, "eventKind", &["user-message", "assistant-message"])?;
        require_non_empty(object, "text")?;
        require_string(object, "createdAt")?;
    }
    Ok(())
}

fn validate_execution(value: Option<&Value>) -> Result<()> {
    let items = value
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("execution must be an array"))?;
    for item in items {
        let object = item
            .as_object()
            .ok_or_else(|| anyhow!("execution event must be an object"))?;
        require_const_str(object, "layer", "execution")?;
        require_non_empty(object, "id")?;
        require_enum(
            object,
            "eventKind",
            &[
                "tool-call",
                "tool-result",
                "terminal",
                "plan",
                "progress",
                "retry",
                "error",
                "reasoning",
                "event",
            ],
        )?;
        require_string(object, "title")?;
        require_string(object, "summary")?;
        require_string(object, "createdAt")?;
        if !object.get("collapsed").and_then(Value::as_bool).is_some() {
            return Err(anyhow!("execution.collapsed must be boolean"));
        }
    }
    Ok(())
}

fn validate_artifacts(value: Option<&Value>) -> Result<()> {
    let items = value
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("artifacts must be an array"))?;
    for item in items {
        let object = item
            .as_object()
            .ok_or_else(|| anyhow!("artifact must be an object"))?;
        require_const_str(object, "layer", "artifacts")?;
        require_non_empty(object, "id")?;
        require_enum(
            object,
            "kind",
            &[
                "file",
                "diff",
                "document",
                "summary",
                "index",
                "validation",
                "archive-path",
            ],
        )?;
        require_string(object, "label")?;
    }
    Ok(())
}

fn validate_audit(value: Option<&Value>) -> Result<()> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("audit required"))?;
    for key in [
        "adapterId",
        "hostApp",
        "sourceKind",
        "nativeSessionId",
        "createdAt",
        "updatedAt",
    ] {
        require_string(object, key)?;
    }
    require_enum(object, "redactionStatus", &["applied", "partial", "none"])?;
    require_enum(object, "validationStatus", &["unchecked", "ok", "failed"])?;
    if object
        .get("parseWarnings")
        .and_then(Value::as_array)
        .is_none()
    {
        return Err(anyhow!("audit.parseWarnings must be an array"));
    }
    validate_evidence(object.get("sourceEvidence"))?;
    Ok(())
}

fn validate_raw(value: Option<&Value>) -> Result<()> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("raw required"))?;
    let refs = object
        .get("evidenceRefs")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("raw.evidenceRefs must be an array"))?;
    if refs.is_empty() {
        return Err(anyhow!("raw.evidenceRefs must be non-empty"));
    }
    for evidence in refs {
        validate_evidence(Some(evidence))?;
    }
    Ok(())
}

fn validate_evidence(value: Option<&Value>) -> Result<()> {
    let object = value
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("evidence ref required"))?;
    require_enum(
        object,
        "kind",
        &["jsonl", "json", "sqlite-row", "markdown", "text", "unknown"],
    )?;
    require_non_empty(object, "pathRef")?;
    require_non_empty(object, "contentHash")?;
    Ok(())
}

fn assert_no_default_view_leakage(value: &Value) -> Result<()> {
    let mut haystack = String::new();
    if let Some(thread) = value.get("thread").and_then(Value::as_array) {
        for event in thread {
            if let Some(text) = event.get("text").and_then(Value::as_str) {
                haystack.push_str(text);
                haystack.push('\n');
            }
        }
    }
    if let Some(execution) = value.get("execution").and_then(Value::as_array) {
        for event in execution {
            if let Some(text) = event.get("summary").and_then(Value::as_str) {
                haystack.push_str(text);
                haystack.push('\n');
            }
        }
    }
    let lower = haystack.to_ascii_lowercase();
    for needle in [
        "sk-",
        "api_key",
        "authorization: bearer",
        "/users/",
        concat!("/", "home", "/"),
        "c:\\users\\",
        "<system>",
        "<apps_instructions>",
    ] {
        if lower.contains(needle) {
            return Err(anyhow!(
                "semantic default layers must not expose sensitive marker `{needle}`"
            ));
        }
    }
    // Raw JSON tool payloads should not appear in default layers.
    if lower.contains("\"arguments\":{")
        || lower.contains("\"tool_input\":{")
        || lower.contains("\"arguments\": [")
    {
        return Err(anyhow!(
            "semantic default layers must not expose full command/tool payloads"
        ));
    }
    Ok(())
}

fn require_const_u64(object: &Map<String, Value>, key: &str, expected: u64) -> Result<()> {
    match object.get(key).and_then(Value::as_u64) {
        Some(value) if value == expected => Ok(()),
        _ => Err(anyhow!("{key} must be {expected}")),
    }
}

fn require_const_str(object: &Map<String, Value>, key: &str, expected: &str) -> Result<()> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if value == expected => Ok(()),
        _ => Err(anyhow!("{key} must be `{expected}`")),
    }
}

fn require_const_bool(object: &Map<String, Value>, key: &str, expected: bool) -> Result<()> {
    match object.get(key).and_then(Value::as_bool) {
        Some(value) if value == expected => Ok(()),
        _ => Err(anyhow!("{key} must be {expected}")),
    }
}

fn require_string(object: &Map<String, Value>, key: &str) -> Result<()> {
    match object.get(key).and_then(Value::as_str) {
        Some(_) => Ok(()),
        None => Err(anyhow!("{key} must be a string")),
    }
}

fn require_non_empty(object: &Map<String, Value>, key: &str) -> Result<()> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if !value.trim().is_empty() => Ok(()),
        _ => Err(anyhow!("{key} must be a non-empty string")),
    }
}

fn require_enum(object: &Map<String, Value>, key: &str, allowed: &[&str]) -> Result<()> {
    match object.get(key).and_then(Value::as_str) {
        Some(value) if allowed.contains(&value) => Ok(()),
        Some(value) => Err(anyhow!("{key} has unsupported value `{value}`")),
        None => Err(anyhow!("{key} must be a string enum")),
    }
}

fn normalize_token(value: &str) -> String {
    let mut normalized = String::new();
    let mut separator = false;
    for character in value.trim().chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !normalized.is_empty() {
                normalized.push('-');
            }
            separator = false;
            normalized.push(character.to_ascii_lowercase());
        } else {
            separator = true;
        }
    }
    normalized
}

fn sanitize_ref_token(value: &str) -> String {
    let mut out = String::new();
    for character in value.chars() {
        if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
            out.push(character.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    if out.is_empty() {
        "unknown".to_string()
    } else {
        out.trim_matches('-').to_string()
    }
}

fn redact_path_ref(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.starts_with("fixture://") || !trimmed.contains('/') && !trimmed.contains('\\') {
        return trimmed.to_string();
    }
    // Keep only the final path segment for archive-relative or display refs.
    Path::new(trimmed)
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.to_string())
        .unwrap_or_else(|| "source.bin".to_string())
}

fn sanitize_default_view_text(text: &str) -> String {
    let mut out = text.to_string();
    let replacements = [
        ("sk-", "[redacted-token]"),
        ("api_key", "[redacted-secret]"),
        ("Authorization: Bearer", "[redacted-auth]"),
        ("authorization: bearer", "[redacted-auth]"),
        (concat!("/", "Users", "/"), "[user-home]/"),
        (concat!("/", "home", "/"), "[user-home]/"),
        ("C:\\Users\\", "[user-home]/"),
        ("c:\\users\\", "[user-home]/"),
        ("<system>", "[system-context]"),
        ("<apps_instructions>", "[apps-instructions]"),
        ("\"arguments\":{", "[redacted-tool-args]{"),
        ("\"tool_input\":{", "[redacted-tool-input]{"),
    ];
    for (needle, replacement) in replacements {
        let needle_lower = needle.to_ascii_lowercase();
        loop {
            let lower = out.to_ascii_lowercase();
            let Some(index) = lower.find(&needle_lower) else {
                break;
            };
            let end = index + needle.len().min(out.len().saturating_sub(index));
            out.replace_range(index..end, replacement);
        }
    }
    out
}

fn role_heading(role: &str) -> &'static str {
    match role {
        "user" => "User",
        _ => "Assistant",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../packages/contracts/client/fixtures/semantic-conversation")
    }

    #[test]
    fn fixtures_conform_to_semantic_contract() {
        for name in ["complete-layers.json", "metadata-filtered.json"] {
            let path = fixture_dir().join(name);
            load_and_validate_fixture(&path)
                .unwrap_or_else(|error| panic!("fixture {name} failed: {error}"));
        }
    }

    #[test]
    fn build_semantic_separates_thread_and_execution() {
        let messages = vec![
            json!({
                "id": "m1",
                "layer": "thread",
                "role": "user",
                "text": "Hello",
                "createdAt": "2026-01-01T00:00:00Z"
            }),
            json!({
                "id": "m2",
                "layer": "execution",
                "role": "tool_call",
                "cardType": "tool-call",
                "cardTitle": "Read file",
                "text": "Invocation details are hidden.",
                "createdAt": "2026-01-01T00:00:01Z",
                "collapsed": true,
                "sourceItemType": "tool-use"
            }),
        ];
        let semantic = build_semantic_conversation(
            &messages,
            SemanticAuditInput {
                adapter_id: "codex",
                adapter_label: "Codex",
                host_app: "codex",
                host_app_label: "Codex",
                source_client: "codex",
                source_kind: "jsonl",
                native_session_id: "sess-1",
                path_ref: "fixture://codex/sess-1.jsonl",
                content_hash: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                byte_length: 128,
                parse_warnings: &[],
                redaction_status: "applied",
                validation_status: "ok",
                created_at: "2026-01-01T00:00:00Z",
                updated_at: "2026-01-01T00:00:01Z",
            },
        )
        .expect("semantic build");
        assert_eq!(semantic["thread"].as_array().unwrap().len(), 1);
        assert_eq!(semantic["execution"].as_array().unwrap().len(), 1);
        let projected = timeline_messages_from_semantic(&semantic);
        assert_eq!(projected.len(), 2);
        assert_eq!(projected[0]["layer"], "thread");
        assert_eq!(projected[1]["layer"], "execution");
    }

    #[test]
    fn validator_rejects_thread_path_leakage() {
        let mut value = load_and_validate_fixture(&fixture_dir().join("complete-layers.json"))
            .expect("fixture");
        // Assemble the synthetic path so privacy scanners do not mistake the
        // test fixture itself for captured machine identity.
        value["thread"][0]["text"] = json!(format!("see {}/{}", "/Users", "someone/secret"));
        assert!(validate_semantic_conversation(&value).is_err());
    }
}
