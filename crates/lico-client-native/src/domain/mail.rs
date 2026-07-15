use crate::domain::source_queue;
use crate::platform::client_state::ClientStateStore;
use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const MAIL_SCHEMA_VERSION: &str = "v0.0.1:macos-mail-helper-1";
const MAIL_IMPORT_DIR: &str = "mail-imports";
const HELPER_BINARY_NAME: &str = "lico-mail-helper";

pub fn preview(params: &Value) -> Result<Value> {
    let scope = explicit_scope(params)?;
    if let Some(helper_path) = resolve_helper_path(params) {
        let helper = run_helper(&helper_path, "preview", &scope, &[])?;
        return Ok(json!({
            "ok": true,
            "schemaVersion": MAIL_SCHEMA_VERSION,
            "status": "preview_ready",
            "requiresExplicitScope": true,
            "scope": scope,
            "stats": helper.get("stats").cloned().unwrap_or_else(|| json!({})),
            "helper": helper_record(&helper_path, true),
            "next": {
                "command": "lico-client mail enqueue",
                "handoff": "source-queue"
            }
        }));
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": MAIL_SCHEMA_VERSION,
        "status": "preview_ready",
        "requiresExplicitScope": true,
        "scope": scope,
        "stats": {
            "mode": "planned",
            "helperAvailable": false,
            "helperPath": requested_helper_path(params).map(|path| path.display().to_string()).unwrap_or_default()
        },
        "helper": helper_record_from_params(params, false),
        "next": {
            "command": "lico-client mail enqueue",
            "handoff": "source-queue"
        }
    }))
}

pub fn enqueue(params: &Value) -> Result<Value> {
    let scope = explicit_scope(params)?;
    let scope_digest = sha256_hex(serde_json::to_string(&scope)?.as_bytes());
    if let Some(helper_path) = resolve_helper_path(params) {
        let export_dir = export_directory(params, &scope_digest)?;
        if export_dir.exists() {
            fs::remove_dir_all(&export_dir).with_context(|| {
                format!(
                    "failed to clear mail export directory {}",
                    export_dir.display()
                )
            })?;
        }
        fs::create_dir_all(&export_dir)?;
        let helper = run_helper(
            &helper_path,
            "export",
            &scope,
            &[("output", export_dir.display().to_string())],
        )?;
        let exported_count = helper
            .get("exportedCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if exported_count == 0 {
            return Ok(json!({
                "ok": true,
                "schemaVersion": MAIL_SCHEMA_VERSION,
                "status": "no_matches",
                "requiresExplicitScope": true,
                "scopeDigest": scope_digest,
                "scope": scope,
                "helper": helper_record(&helper_path, true),
                "export": helper,
                "sourceQueue": null
            }));
        }
        let mut queue_params = json!({
            "path": export_dir.display().to_string(),
            "sourceType": "macos-mail",
            "providerId": "apple-mail",
            "externalId": format!("mail-export:{}", scope_digest),
            "metadataJson": {
                "kind": "mail-export",
                "scope": scope,
                "helper": helper_record(&helper_path, true),
                "export": helper,
                "materializedAt": timestamp()
            },
            "serverUrl": text_param(params, &["serverUrl"]).unwrap_or_default()
        });
        copy_state_root(params, &mut queue_params);
        let queue = source_queue::add(&queue_params)?;
        return Ok(json!({
            "ok": true,
            "schemaVersion": MAIL_SCHEMA_VERSION,
            "status": "enqueued",
            "materialized": true,
            "requiresExplicitScope": true,
            "scopeDigest": scope_digest,
            "scope": scope,
            "helper": helper_record(&helper_path, true),
            "exportDirectory": export_dir.display().to_string(),
            "exportedCount": exported_count,
            "sourceQueue": queue
        }));
    }
    let mut queue_params = json!({
        "sourceType": "macos-mail",
        "providerId": "apple-mail",
        "externalId": format!("mail-scope:{}", scope_digest),
        "payloadJson": {
            "kind": "mail-scope",
            "scope": scope,
            "helper": {
                "type": "swift-helper",
                "helperPath": text_param(params, &["helperPath", "helper"]).unwrap_or_default()
            },
            "enqueuedAt": timestamp()
        },
        "serverUrl": text_param(params, &["serverUrl"]).unwrap_or_default()
    });
    copy_state_root(params, &mut queue_params);
    let queue = source_queue::add(&queue_params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": MAIL_SCHEMA_VERSION,
        "status": "enqueued",
        "materialized": false,
        "requiresExplicitScope": true,
        "scopeDigest": scope_digest,
        "sourceQueue": queue
    }))
}

pub fn status(params: &Value) -> Result<Value> {
    let mut queue_params = params.clone();
    if let Some(object) = queue_params.as_object_mut() {
        object.insert("sourceType".into(), json!("macos-mail"));
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": MAIL_SCHEMA_VERSION,
        "status": "ready",
        "requiresExplicitScope": true,
        "sourceQueue": source_queue::list(&queue_params).unwrap_or_else(|_| json!({ "ok": false }))
    }))
}

pub fn cancel(params: &Value) -> Result<Value> {
    source_queue::cancel(params)
}

fn explicit_scope(params: &Value) -> Result<Value> {
    let mailbox = text_param(params, &["mailbox"]);
    let query = text_param(params, &["query", "q"]);
    let since = text_param(params, &["since", "from"]);
    let until = text_param(params, &["until", "to"]);
    if mailbox.is_none() && query.is_none() && since.is_none() && until.is_none() {
        return Err(anyhow!(
            "mail preview/enqueue requires explicit scope: --mailbox, --query, --since, or --until"
        ));
    }
    if since.is_none() && until.is_none() && query.is_none() {
        return Err(anyhow!(
            "mail scope must include --since/--until or --query; mailbox-only imports are intentionally rejected"
        ));
    }
    let mut scope = Map::new();
    if let Some(mailbox) = mailbox {
        scope.insert("mailbox".into(), json!(mailbox));
    }
    if let Some(query) = query {
        scope.insert("query".into(), json!(query));
    }
    if let Some(since) = since {
        scope.insert("since".into(), json!(since));
    }
    if let Some(until) = until {
        scope.insert("until".into(), json!(until));
    }
    if let Some(limit) = number_param(params, &["limit"]) {
        scope.insert("limit".into(), json!(limit));
    }
    if let Some(include_body) = bool_param(params, &["includeBody"]) {
        scope.insert("includeBody".into(), json!(include_body));
    }
    Ok(Value::Object(scope))
}

fn resolve_helper_path(params: &Value) -> Option<PathBuf> {
    let candidate = requested_helper_path(params)
        .or_else(|| env::var("LICO_MAIL_HELPER_PATH").ok().map(PathBuf::from))
        .or_else(sibling_helper_path);
    candidate.filter(|path| path.exists() && path.is_file())
}

fn requested_helper_path(params: &Value) -> Option<PathBuf> {
    text_param(params, &["helperPath", "helper"]).map(PathBuf::from)
}

fn sibling_helper_path() -> Option<PathBuf> {
    let executable = env::current_exe().ok()?;
    let parent = executable.parent()?;
    Some(parent.join(HELPER_BINARY_NAME))
}

fn helper_record(path: &Path, available: bool) -> Value {
    json!({
        "type": "swift-helper",
        "helperAvailable": available,
        "helperPath": path.display().to_string()
    })
}

fn helper_record_from_params(params: &Value, available: bool) -> Value {
    requested_helper_path(params)
        .map(|path| helper_record(&path, available))
        .unwrap_or_else(|| {
            json!({
                "type": "swift-helper",
                "helperAvailable": available,
                "helperPath": ""
            })
        })
}

fn run_helper(
    helper_path: &Path,
    command_name: &str,
    scope: &Value,
    extra: &[(&str, String)],
) -> Result<Value> {
    let mut command = Command::new(helper_path);
    command.arg(command_name);
    append_scope_args(&mut command, scope);
    for (key, value) in extra {
        command.arg(format!("--{}", key)).arg(value);
    }
    let output = command.output().with_context(|| {
        format!(
            "failed to start macOS Mail helper at {}",
            helper_path.display()
        )
    })?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let parsed = serde_json::from_str::<Value>(&stdout).unwrap_or_else(|_| json!({}));
    if !output.status.success() {
        let helper_error = parsed
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or_else(|| stderr.trim());
        return Err(anyhow!(
            "macOS Mail helper {} failed: {}",
            command_name,
            helper_error
        ));
    }
    if parsed.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(anyhow!(
            "macOS Mail helper {} returned non-ok response: {}",
            command_name,
            parsed
        ));
    }
    Ok(parsed)
}

fn append_scope_args(command: &mut Command, scope: &Value) {
    for (field, flag) in [
        ("mailbox", "mailbox"),
        ("query", "query"),
        ("since", "since"),
        ("until", "until"),
    ] {
        if let Some(value) = scope.get(field).and_then(Value::as_str) {
            command.arg(format!("--{}", flag)).arg(value);
        }
    }
    if let Some(limit) = scope.get("limit").and_then(Value::as_u64) {
        command.arg("--limit").arg(limit.to_string());
    }
}

fn export_directory(params: &Value, scope_digest: &str) -> Result<PathBuf> {
    if let Some(output) = text_param(params, &["output", "outputDirectory"]) {
        let raw = PathBuf::from(output);
        // Reject path traversal components in user-supplied export paths.
        ensure!(
            !raw.to_string_lossy().contains(".."),
            "export output path must not contain traversal components"
        );
        // Canonicalize if the path exists, otherwise canonicalize the parent.
        let canonical = if raw.exists() {
            raw.canonicalize()?
        } else if let Some(parent) = raw.parent() {
            if !parent.exists() {
                return Err(anyhow!(
                    "export output parent directory does not exist: {}",
                    parent.display()
                ));
            }
            let canonical_parent = parent.canonicalize()?;
            canonical_parent.join(
                raw.file_name()
                    .ok_or_else(|| anyhow!("export output path has no file name"))?,
            )
        } else {
            return Err(anyhow!(
                "export output path cannot be canonicalized: {}",
                raw.display()
            ));
        };
        crate::platform::file_security::validate_export_destination(&canonical)?;
        return Ok(canonical);
    }
    let root = if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
        PathBuf::from(state_root)
    } else {
        ClientStateStore::portable()?.root().to_path_buf()
    };
    Ok(root.join(MAIL_IMPORT_DIR).join(scope_digest))
}

fn copy_state_root(params: &Value, target: &mut Value) {
    if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
        target["stateRoot"] = json!(state_root);
    }
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn number_param(params: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<u64>().ok()))
        })
    })
}

fn bool_param(params: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value.as_bool().or_else(|| {
                value.as_str().map(|text| {
                    matches!(
                        text.trim().to_lowercase().as_str(),
                        "1" | "true" | "yes" | "on"
                    )
                })
            })
        })
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:09}Z", now.as_secs(), now.subsec_nanos())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use uuid::Uuid;

    #[test]
    fn mail_scope_enqueue_respects_state_root_without_helper() {
        let root = temp_dir("mail-state-root");
        let enqueued = enqueue(&json!({
            "mailbox": "Inbox",
            "since": "2026-06-15",
            "stateRoot": root.display().to_string()
        }))
        .unwrap();
        assert_eq!(enqueued["status"], "enqueued");
        assert_eq!(enqueued["materialized"], false);
        let status = source_queue::status(&json!({
            "stateRoot": root.display().to_string()
        }))
        .unwrap();
        assert_eq!(status["counts"]["pending"], 1);
    }

    #[cfg(unix)]
    #[test]
    fn helper_export_materializes_directory_before_enqueue() {
        let root = temp_dir("mail-helper-state-root");
        let helper = root.join("lico-mail-helper");
        fs::write(
            &helper,
            r#"#!/bin/sh
set -eu
cmd="$1"
shift
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$cmd" = "preview" ]; then
  printf '{"ok":true,"status":"preview_ready","stats":{"matchedCount":1}}\n'
  exit 0
fi
if [ "$cmd" = "export" ]; then
  mkdir -p "$output"
  printf 'Subject: LicoLite helper proof\n\nbody\n' > "$output/message-000001.eml"
  printf 'fileName\tmessageId\tdateReceived\nmessage-000001.eml\tmsg-1\t2026-06-15\n' > "$output/manifest.tsv"
  printf '{"ok":true,"status":"exported","exportedCount":1,"stats":{"matchedCount":1,"exportedCount":1}}\n'
  exit 0
fi
printf '{"ok":false,"error":"unsupported"}\n'
exit 1
"#,
        )
        .unwrap();
        let mut permissions = fs::metadata(&helper).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&helper, permissions).unwrap();

        let previewed = preview(&json!({
            "mailbox": "Inbox",
            "query": "proof",
            "stateRoot": root.display().to_string(),
            "helperPath": helper.display().to_string()
        }))
        .unwrap();
        assert_eq!(previewed["helper"]["helperAvailable"], true);
        assert_eq!(previewed["stats"]["matchedCount"], 1);

        let enqueued = enqueue(&json!({
            "mailbox": "Inbox",
            "query": "proof",
            "stateRoot": root.display().to_string(),
            "helperPath": helper.display().to_string()
        }))
        .unwrap();
        assert_eq!(enqueued["status"], "enqueued");
        assert_eq!(enqueued["materialized"], true);
        assert_eq!(enqueued["exportedCount"], 1);
        let item = &enqueued["sourceQueue"]["item"];
        assert_eq!(item["sourceType"], "macos-mail");
        assert_eq!(item["payload"]["kind"], "directory");
        let export_path = item["payload"]["path"].as_str().unwrap();
        assert!(export_path.starts_with(root.to_str().unwrap()));
        assert!(Path::new(export_path).join("message-000001.eml").exists());
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-client-{}-{}", name, Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
