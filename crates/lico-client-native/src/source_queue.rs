use crate::client_state::{ActivityLog, ClientStateStore};
use crate::file_security::harden_private_path;
use crate::url_security::is_https_or_loopback_http_url;
use anyhow::{Context, Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const SOURCE_QUEUE_SCHEMA_VERSION: &str = "v0.0.1:source-queue-1";
const SOURCE_QUEUE_DIR: &str = "source-queue";
const SOURCE_QUEUE_DB: &str = "source-queue.sqlite";
const SOURCE_QUEUE_AUDIT: &str = "source-queue.audit.jsonl";

#[derive(Debug, Clone)]
struct QueueItem {
    item_id: String,
    state: String,
    source_type: String,
    provider_id: String,
    external_id: String,
    payload: Value,
    server_url: String,
    upload_session_id: String,
    job_id: String,
    attempt: u64,
    created_at: String,
    updated_at: String,
    last_error: String,
}

#[derive(Debug)]
struct UploadFile {
    name: String,
    relative_path: String,
    media_type: String,
    sha256: String,
    byte_size: u64,
    source_metadata: Value,
    body: UploadBody,
}

#[derive(Debug)]
enum UploadBody {
    Path(PathBuf),
    Bytes(Vec<u8>),
}

#[derive(Debug)]
enum DrainOutcome {
    Submitted {
        upload_session_id: String,
        job_id: String,
        session: Value,
        job: Value,
    },
    Deferred {
        reason: String,
    },
}

struct SourceQueueStore {
    root: PathBuf,
    db_path: PathBuf,
    audit_path: PathBuf,
}

pub fn add(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    let item = normalize_item(params)?;
    store.enqueue(item)
}

pub fn list(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.list(params)
}

pub fn status(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.status()
}

pub fn pause(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.set_paused(
        true,
        text_param(params, &["reason"]).unwrap_or_else(|| "operator_pause".into()),
    )
}

pub fn resume(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.set_paused(
        false,
        text_param(params, &["reason"]).unwrap_or_else(|| "operator_resume".into()),
    )
}

pub fn retry(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.retry(params)
}

pub fn cancel(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.cancel(params)
}

pub fn drain(params: &Value) -> Result<Value> {
    let store = SourceQueueStore::from_params(params)?;
    store.drain(params)
}

impl SourceQueueStore {
    fn from_params(params: &Value) -> Result<Self> {
        let root = if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
            PathBuf::from(state_root).join(SOURCE_QUEUE_DIR)
        } else {
            ClientStateStore::portable()?.root().join(SOURCE_QUEUE_DIR)
        };
        Self::new(root)
    }

    fn new(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let store = Self {
            db_path: root.join(SOURCE_QUEUE_DB),
            audit_path: root.join(SOURCE_QUEUE_AUDIT),
            root,
        };
        store.ensure_schema()?;
        Ok(store)
    }

    fn conn(&self) -> Result<Connection> {
        let conn = Connection::open(&self.db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Ok(conn)
    }

    fn ensure_schema(&self) -> Result<()> {
        let conn = self.conn()?;
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS source_queue_items (
              item_id TEXT PRIMARY KEY,
              state TEXT NOT NULL,
              source_type TEXT NOT NULL,
              provider_id TEXT NOT NULL,
              external_id TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              server_url TEXT NOT NULL DEFAULT '',
              upload_session_id TEXT NOT NULL DEFAULT '',
              job_id TEXT NOT NULL DEFAULT '',
              attempt INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              last_error TEXT NOT NULL DEFAULT ''
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_source_queue_source_identity
              ON source_queue_items(source_type, provider_id, external_id);
            CREATE INDEX IF NOT EXISTS idx_source_queue_state
              ON source_queue_items(state, updated_at);
            CREATE TABLE IF NOT EXISTS source_queue_control (
              scope TEXT PRIMARY KEY,
              paused INTEGER NOT NULL DEFAULT 0,
              reason TEXT NOT NULL DEFAULT '',
              updated_at TEXT NOT NULL
            );
            INSERT OR IGNORE INTO source_queue_control(scope, paused, reason, updated_at)
              VALUES('default', 0, '', '');
            ",
        )?;
        Ok(())
    }

    fn enqueue(&self, item: QueueItem) -> Result<Value> {
        let conn = self.conn()?;
        if let Some(existing) = self.find_by_identity(
            &conn,
            &item.source_type,
            &item.provider_id,
            &item.external_id,
        )? {
            self.audit("source_queue.deduped", &existing.item_id, json!({}))?;
            return Ok(json!({
                "ok": true,
                "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
                "status": "deduped",
                "item": item_to_json(existing)
            }));
        }
        conn.execute(
            "
            INSERT INTO source_queue_items (
              item_id, state, source_type, provider_id, external_id, payload_json,
              server_url, upload_session_id, job_id, attempt, created_at, updated_at, last_error
            )
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, '', '', 0, ?8, ?8, '')
            ",
            params![
                item.item_id,
                item.state,
                item.source_type,
                item.provider_id,
                item.external_id,
                serde_json::to_string(&item.payload)?,
                item.server_url,
                item.created_at,
            ],
        )?;
        let saved = self
            .get_item(&conn, &item.item_id)?
            .ok_or_else(|| anyhow!("source queue insert failed"))?;
        self.audit(
            "source_queue.enqueued",
            &saved.item_id,
            item_to_json(saved.clone()),
        )?;
        append_activity(
            "source_queue.enqueued",
            json!({
                "target": "source-queue",
                "itemId": saved.item_id,
                "sourceType": saved.source_type,
                "providerId": saved.provider_id
            }),
        );
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": "enqueued",
            "item": item_to_json(saved)
        }))
    }

    fn list(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let state = text_param(params, &["state"]).unwrap_or_default();
        let source_type = text_param(params, &["sourceType"]).unwrap_or_default();
        let limit = number_param(params, &["limit"])
            .unwrap_or(100)
            .clamp(1, 1000);
        let mut stmt = conn.prepare(
            "
            SELECT * FROM source_queue_items
            WHERE (?1 = '' OR state = ?1)
              AND (?2 = '' OR source_type = ?2)
            ORDER BY created_at DESC
            LIMIT ?3
            ",
        )?;
        let rows = stmt.query_map(params![state, source_type, limit as i64], row_to_item)?;
        let mut items = Vec::new();
        for row in rows {
            items.push(item_to_json(row?));
        }
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "items": items,
            "queueRoot": display_path(&self.root)
        }))
    }

    fn status(&self) -> Result<Value> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT state, COUNT(*) FROM source_queue_items GROUP BY state")?;
        let mut counts = Map::new();
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, u64>(1)?))
        })?;
        for row in rows {
            let (state, count) = row?;
            counts.insert(state, json!(count));
        }
        let (paused, reason, updated_at) = self.control(&conn)?;
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": if paused { "paused" } else { "ready" },
            "paused": paused,
            "pauseReason": reason,
            "pauseUpdatedAt": updated_at,
            "counts": Value::Object(counts),
            "queueRoot": display_path(&self.root),
            "auditPath": display_path(&self.audit_path),
            "dbPath": display_path(&self.db_path)
        }))
    }

    fn set_paused(&self, paused: bool, reason: String) -> Result<Value> {
        let conn = self.conn()?;
        let now = timestamp();
        conn.execute(
            "
            INSERT INTO source_queue_control(scope, paused, reason, updated_at)
            VALUES('default', ?1, ?2, ?3)
            ON CONFLICT(scope) DO UPDATE SET
              paused = excluded.paused,
              reason = excluded.reason,
              updated_at = excluded.updated_at
            ",
            params![if paused { 1 } else { 0 }, reason, now],
        )?;
        self.audit(
            if paused {
                "source_queue.paused"
            } else {
                "source_queue.resumed"
            },
            "",
            json!({ "reason": reason }),
        )?;
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": if paused { "paused" } else { "ready" },
            "paused": paused,
            "reason": reason
        }))
    }

    fn retry(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let now = timestamp();
        let item_id = text_param(params, &["itemId", "target"]).unwrap_or_default();
        let changed = if item_id.is_empty() {
            conn.execute(
                "
                UPDATE source_queue_items
                SET state = 'pending', last_error = '', updated_at = ?1
                WHERE state IN ('failed', 'cancelled')
                ",
                params![now],
            )?
        } else {
            conn.execute(
                "
                UPDATE source_queue_items
                SET state = 'pending', last_error = '', updated_at = ?1
                WHERE item_id = ?2 AND state IN ('failed', 'cancelled', 'pending')
                ",
                params![now, item_id],
            )?
        };
        self.audit(
            "source_queue.retry_requested",
            &item_id,
            json!({ "changed": changed }),
        )?;
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": "retry_requested",
            "itemId": item_id,
            "changed": changed
        }))
    }

    fn cancel(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let now = timestamp();
        let item_id = text_param(params, &["itemId", "target"]).unwrap_or_default();
        let all = bool_param(params, &["all"]).unwrap_or(false);
        if item_id.is_empty() && !all {
            return Err(anyhow!(
                "source-queue cancel requires --item-id or --all true"
            ));
        }
        let changed = if all {
            conn.execute(
                "
                UPDATE source_queue_items
                SET state = 'cancelled', updated_at = ?1, last_error = 'operator_cancelled'
                WHERE state IN ('pending', 'uploading', 'failed')
                ",
                params![now],
            )?
        } else {
            conn.execute(
                "
                UPDATE source_queue_items
                SET state = 'cancelled', updated_at = ?1, last_error = 'operator_cancelled'
                WHERE item_id = ?2 AND state IN ('pending', 'uploading', 'failed')
                ",
                params![now, item_id],
            )?
        };
        self.audit(
            "source_queue.cancelled",
            &item_id,
            json!({ "changed": changed, "all": all }),
        )?;
        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": "cancelled",
            "itemId": item_id,
            "all": all,
            "changed": changed
        }))
    }

    fn drain(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let (paused, reason, _) = self.control(&conn)?;
        if paused {
            return Ok(json!({
                "ok": true,
                "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
                "status": "paused",
                "paused": true,
                "reason": reason,
                "submitted": 0,
                "failed": 0,
                "deferred": 0
            }));
        }
        let limit = number_param(params, &["limit"]).unwrap_or(10).clamp(1, 100) as i64;
        let token = text_param(params, &["token", "authorization"]).unwrap_or_default();
        let server_url_override = text_param(params, &["serverUrl"]);
        let stop_on_error = bool_param(params, &["stopOnError"]).unwrap_or(false);
        let mut stmt = conn.prepare(
            "
            SELECT * FROM source_queue_items
            WHERE state = 'pending'
            ORDER BY created_at ASC
            LIMIT ?1
            ",
        )?;
        let rows = stmt.query_map(params![limit], row_to_item)?;
        let mut items = Vec::new();
        for row in rows {
            items.push(row?);
        }
        drop(stmt);

        let mut submitted = Vec::new();
        let mut failed = Vec::new();
        let mut deferred = Vec::new();
        for mut item in items {
            let now = timestamp();
            conn.execute(
                "
                UPDATE source_queue_items
                SET state = 'uploading', attempt = attempt + 1, updated_at = ?1, last_error = ''
                WHERE item_id = ?2 AND state = 'pending'
                ",
                params![now, item.item_id],
            )?;
            item.attempt += 1;
            item.state = "uploading".into();
            if let Some(server_url) = server_url_override.clone() {
                item.server_url = server_url;
            }
            self.audit(
                "source_queue.drain_started",
                &item.item_id,
                item_to_json(item.clone()),
            )?;
            match process_item(&item, &token) {
                Ok(DrainOutcome::Submitted {
                    upload_session_id,
                    job_id,
                    session,
                    job,
                }) => {
                    let now = timestamp();
                    conn.execute(
                        "
                        UPDATE source_queue_items
                        SET state = 'submitted', upload_session_id = ?1, job_id = ?2,
                            updated_at = ?3, last_error = ''
                        WHERE item_id = ?4
                        ",
                        params![upload_session_id, job_id, now, item.item_id],
                    )?;
                    self.audit(
                        "source_queue.submitted",
                        &item.item_id,
                        json!({
                            "uploadSessionId": upload_session_id,
                            "jobId": job_id,
                            "session": session,
                            "job": job
                        }),
                    )?;
                    submitted.push(json!({
                        "itemId": item.item_id,
                        "uploadSessionId": upload_session_id,
                        "jobId": job_id
                    }));
                }
                Ok(DrainOutcome::Deferred { reason }) => {
                    let now = timestamp();
                    conn.execute(
                        "
                        UPDATE source_queue_items
                        SET state = 'pending', updated_at = ?1, last_error = ?2
                        WHERE item_id = ?3
                        ",
                        params![now, reason, item.item_id],
                    )?;
                    self.audit(
                        "source_queue.deferred",
                        &item.item_id,
                        json!({ "reason": reason }),
                    )?;
                    deferred.push(json!({
                        "itemId": item.item_id,
                        "reason": reason
                    }));
                }
                Err(error) => {
                    let message = error.to_string();
                    let now = timestamp();
                    conn.execute(
                        "
                        UPDATE source_queue_items
                        SET state = 'failed', updated_at = ?1, last_error = ?2
                        WHERE item_id = ?3
                        ",
                        params![now, message, item.item_id],
                    )?;
                    self.audit(
                        "source_queue.failed",
                        &item.item_id,
                        json!({ "error": message }),
                    )?;
                    failed.push(json!({
                        "itemId": item.item_id,
                        "error": message
                    }));
                    if stop_on_error {
                        break;
                    }
                }
            }
        }

        Ok(json!({
            "ok": true,
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "status": "drained",
            "submitted": submitted.len(),
            "failed": failed.len(),
            "deferred": deferred.len(),
            "submittedItems": submitted,
            "failedItems": failed,
            "deferredItems": deferred
        }))
    }

    fn control(&self, conn: &Connection) -> Result<(bool, String, String)> {
        let row = conn
            .query_row(
                "SELECT paused, reason, updated_at FROM source_queue_control WHERE scope = 'default'",
                [],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)? != 0,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()?;
        Ok(row.unwrap_or((false, String::new(), String::new())))
    }

    fn get_item(&self, conn: &Connection, item_id: &str) -> Result<Option<QueueItem>> {
        conn.query_row(
            "SELECT * FROM source_queue_items WHERE item_id = ?1",
            params![item_id],
            row_to_item,
        )
        .optional()
        .map_err(Into::into)
    }

    fn find_by_identity(
        &self,
        conn: &Connection,
        source_type: &str,
        provider_id: &str,
        external_id: &str,
    ) -> Result<Option<QueueItem>> {
        conn.query_row(
            "
            SELECT * FROM source_queue_items
            WHERE source_type = ?1 AND provider_id = ?2 AND external_id = ?3
            ",
            params![source_type, provider_id, external_id],
            row_to_item,
        )
        .optional()
        .map_err(Into::into)
    }

    fn audit(&self, event_type: &str, item_id: &str, payload: Value) -> Result<()> {
        if let Some(parent) = self.audit_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let event = json!({
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "eventId": format!("source-queue-event-{}", timestamp()),
            "type": event_type,
            "itemId": item_id,
            "createdAt": timestamp(),
            "payload": payload
        });
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.audit_path)?;
        harden_private_path(&self.audit_path)?;
        writeln!(file, "{}", serde_json::to_string(&event)?)?;
        Ok(())
    }
}

fn normalize_item(params: &Value) -> Result<QueueItem> {
    let now = timestamp();
    let payload_override = json_param(params, "payloadJson");
    let path = text_param(params, &["path"]);
    let text = text_param(params, &["text"]);
    let mut payload = if let Some(payload) = payload_override {
        payload
    } else {
        let mut object = Map::new();
        if let Some(path) = path.clone() {
            let path = PathBuf::from(path);
            let metadata = fs::metadata(&path)
                .with_context(|| format!("source path does not exist: {}", path.display()))?;
            object.insert("path".into(), json!(path.display().to_string()));
            object.insert(
                "kind".into(),
                json!(if metadata.is_dir() {
                    "directory"
                } else {
                    "file"
                }),
            );
            object.insert("byteSize".into(), json!(metadata.len()));
        }
        if let Some(text) = text.clone() {
            object.insert("kind".into(), json!("text"));
            object.insert("text".into(), json!(text));
        }
        Value::Object(object)
    };
    if let Some(metadata) = json_param(params, "metadataJson") {
        ensure_object(&mut payload).insert("metadata".into(), metadata);
    }
    let source_type =
        text_param(params, &["sourceType"]).unwrap_or_else(|| infer_source_type(&payload).into());
    let provider_id = text_param(params, &["providerId"]).unwrap_or_else(|| "lico-client".into());
    let external_id = text_param(params, &["externalId"])
        .unwrap_or_else(|| external_id_for(&source_type, &provider_id, &payload));
    let item_id = text_param(params, &["itemId"]).unwrap_or_else(|| {
        let digest =
            sha256_hex(format!("{}:{}:{}", source_type, provider_id, external_id).as_bytes());
        format!("source_queue_{}", &digest[..24])
    });
    Ok(QueueItem {
        item_id,
        state: "pending".into(),
        source_type,
        provider_id,
        external_id,
        payload,
        server_url: text_param(params, &["serverUrl"]).unwrap_or_default(),
        upload_session_id: String::new(),
        job_id: String::new(),
        attempt: 0,
        created_at: now.clone(),
        updated_at: now,
        last_error: String::new(),
    })
}

fn process_item(item: &QueueItem, token: &str) -> Result<DrainOutcome> {
    if item.server_url.trim().is_empty() {
        return Ok(DrainOutcome::Deferred {
            reason: "server_url_required_for_upload_submission".into(),
        });
    }
    validate_server_url(&item.server_url)?;
    if item
        .payload
        .get("kind")
        .and_then(Value::as_str)
        .is_some_and(|kind| kind == "mail-scope")
    {
        return Ok(DrainOutcome::Deferred {
            reason: "mail_scope_requires_swift_helper_materialization".into(),
        });
    }

    let files = collect_upload_files(item)?;
    if files.is_empty() {
        return Ok(DrainOutcome::Deferred {
            reason: "source_item_has_no_materialized_files".into(),
        });
    }

    let file_records = files
        .iter()
        .map(|file| {
            json!({
                "name": file.name,
                "relativePath": file.relative_path,
                "mediaType": file.media_type,
                "sha256": file.sha256,
                "byteSize": file.byte_size,
                "sourceType": item.source_type,
                "providerId": item.provider_id,
                "externalId": item.external_id,
                "sourceMetadata": file.source_metadata
            })
        })
        .collect::<Vec<_>>();
    let total_bytes = files.iter().map(|file| file.byte_size).sum::<u64>();
    let manifest_doc = json!({
        "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
        "sourceType": item.source_type,
        "providerId": item.provider_id,
        "externalId": item.external_id,
        "fileCount": files.len(),
        "totalBytes": total_bytes,
        "files": file_records
    });
    let manifest_digest = sha256_hex(&serde_json::to_vec(&manifest_doc)?);
    let session_body = json!({
        "checkpoint": {
            "checkpointId": item.item_id,
            "clientUid": "lico-client",
            "sourceType": item.source_type,
            "providerId": item.provider_id,
            "externalId": item.external_id,
            "contentHash": manifest_digest,
            "capturedAt": item.created_at,
            "mode": "initial"
        },
        "manifest": {
            "schemaVersion": SOURCE_QUEUE_SCHEMA_VERSION,
            "manifestDigest": manifest_digest,
            "inputDigest": manifest_digest,
            "sourceType": item.source_type,
            "providerId": item.provider_id,
            "externalId": item.external_id,
            "fileCount": files.len(),
            "totalBytes": total_bytes,
            "fileRecords": file_records
        },
        "files": file_records
    });
    let session = post_json(
        &item.server_url,
        "/api/upload-sessions",
        token,
        session_body,
    )?;
    let session_id = session
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("upload session response did not include sessionId"))?
        .to_string();

    for (index, file) in files.iter().enumerate() {
        let received = session
            .get("files")
            .and_then(Value::as_array)
            .and_then(|items| items.get(index))
            .and_then(|entry| entry.get("receivedBytes"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if received >= file.byte_size {
            continue;
        }
        let bytes = read_upload_bytes(file, received)?;
        let path = format!(
            "/api/upload-sessions/{}/files/{}?offset={}",
            session_id, index, received
        );
        put_bytes(&item.server_url, &path, token, &bytes)?;
    }

    let job = post_json(
        &item.server_url,
        "/api/jobs",
        token,
        json!({
            "uploadSessionId": session_id,
            "checkpoint": {
                "checkpointId": item.item_id,
                "mode": "initial",
                "sourceType": item.source_type,
                "providerId": item.provider_id,
                "externalId": item.external_id
            },
            "settings": {
                "sourceQueueItemId": item.item_id
            }
        }),
    )?;
    let job_id = job
        .get("id")
        .or_else(|| job.get("jobId"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok(DrainOutcome::Submitted {
        upload_session_id: session_id,
        job_id,
        session,
        job,
    })
}

fn collect_upload_files(item: &QueueItem) -> Result<Vec<UploadFile>> {
    if let Some(text) = item.payload.get("text").and_then(Value::as_str) {
        let bytes = text.as_bytes().to_vec();
        return Ok(vec![UploadFile {
            name: "input.txt".into(),
            relative_path: "input.txt".into(),
            media_type: "text/plain; charset=utf-8".into(),
            sha256: sha256_hex(&bytes),
            byte_size: bytes.len() as u64,
            source_metadata: item
                .payload
                .get("metadata")
                .cloned()
                .unwrap_or_else(|| json!({})),
            body: UploadBody::Bytes(bytes),
        }]);
    }
    let path = match item.payload.get("path").and_then(Value::as_str) {
        Some(path) if !path.trim().is_empty() => PathBuf::from(path),
        _ => return Ok(Vec::new()),
    };
    let metadata = fs::metadata(&path)?;
    if metadata.is_file() {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("source-file")
            .to_string();
        return Ok(vec![upload_file_for_path(
            &path,
            name,
            item.payload
                .get("metadata")
                .cloned()
                .unwrap_or_else(|| json!({})),
        )?]);
    }
    if !metadata.is_dir() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::<PathBuf>::new();
    collect_files_recursively(&path, &mut paths)?;
    paths.sort();
    let mut files = Vec::new();
    for file_path in paths {
        let relative_path = file_path
            .strip_prefix(&path)
            .unwrap_or(&file_path)
            .to_string_lossy()
            .replace('\\', "/");
        files.push(upload_file_for_path(
            &file_path,
            if relative_path.trim().is_empty() {
                file_path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or("source-file")
                    .to_string()
            } else {
                relative_path
            },
            item.payload
                .get("metadata")
                .cloned()
                .unwrap_or_else(|| json!({})),
        )?);
    }
    Ok(files)
}

fn upload_file_for_path(
    path: &Path,
    relative_path: String,
    source_metadata: Value,
) -> Result<UploadFile> {
    let byte_size = fs::metadata(path)?.len();
    Ok(UploadFile {
        name: path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("source-file")
            .to_string(),
        relative_path: sanitize_relative_path(&relative_path),
        media_type: mime_guess::from_path(path)
            .first_or_octet_stream()
            .essence_str()
            .to_string(),
        sha256: sha256_file(path)?,
        byte_size,
        source_metadata,
        body: UploadBody::Path(path.to_path_buf()),
    })
}

fn collect_files_recursively(root: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = entry.metadata()?;
        if metadata.is_dir() {
            collect_files_recursively(&path, out)?;
        } else if metadata.is_file() {
            out.push(path);
        }
    }
    Ok(())
}

fn read_upload_bytes(file: &UploadFile, offset: u64) -> Result<Vec<u8>> {
    match &file.body {
        UploadBody::Bytes(bytes) => Ok(bytes.get(offset as usize..).unwrap_or(&[]).to_vec()),
        UploadBody::Path(path) => {
            let mut file = File::open(path)?;
            file.seek(SeekFrom::Start(offset))?;
            let mut bytes = Vec::new();
            file.read_to_end(&mut bytes)?;
            Ok(bytes)
        }
    }
}

fn post_json(base_url: &str, path: &str, token: &str, body: Value) -> Result<Value> {
    let url = join_url(base_url, path);
    let mut request = ureq::post(&url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    if !token.trim().is_empty() {
        request = request.set("authorization", &format!("Bearer {}", token.trim()));
    }
    match request.send_json(body) {
        Ok(response) => Ok(response.into_json::<Value>().unwrap_or_else(|_| json!({}))),
        Err(ureq::Error::Status(status, response)) => {
            let payload = response.into_json::<Value>().unwrap_or_else(|_| json!({}));
            Err(anyhow!(
                "request {} failed with status {}: {}",
                url,
                status,
                payload
            ))
        }
        Err(error) => Err(anyhow!("request {} failed: {}", url, error)),
    }
}

fn put_bytes(base_url: &str, path: &str, token: &str, bytes: &[u8]) -> Result<Value> {
    let url = join_url(base_url, path);
    let mut request = ureq::put(&url)
        .set("accept", "application/json")
        .set("content-type", "application/octet-stream");
    if !token.trim().is_empty() {
        request = request.set("authorization", &format!("Bearer {}", token.trim()));
    }
    match request.send_bytes(bytes) {
        Ok(response) => Ok(response.into_json::<Value>().unwrap_or_else(|_| json!({}))),
        Err(ureq::Error::Status(status, response)) => {
            let payload = response.into_json::<Value>().unwrap_or_else(|_| json!({}));
            Err(anyhow!(
                "request {} failed with status {}: {}",
                url,
                status,
                payload
            ))
        }
        Err(error) => Err(anyhow!("request {} failed: {}", url, error)),
    }
}

fn validate_server_url(url: &str) -> Result<()> {
    if is_https_or_loopback_http_url(url) {
        return Ok(());
    }
    Err(anyhow!(
        "source queue server URL must use https://, http://127.0.0.1, or http://localhost"
    ))
}

fn join_url(base: &str, path: &str) -> String {
    format!("{}{}", base.trim_end_matches('/'), path)
}

fn row_to_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<QueueItem> {
    let payload_json: String = row.get("payload_json")?;
    Ok(QueueItem {
        item_id: row.get("item_id")?,
        state: row.get("state")?,
        source_type: row.get("source_type")?,
        provider_id: row.get("provider_id")?,
        external_id: row.get("external_id")?,
        payload: serde_json::from_str(&payload_json).unwrap_or_else(|_| json!({})),
        server_url: row.get("server_url")?,
        upload_session_id: row.get("upload_session_id")?,
        job_id: row.get("job_id")?,
        attempt: row.get::<_, i64>("attempt")?.max(0) as u64,
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        last_error: row.get("last_error")?,
    })
}

fn item_to_json(item: QueueItem) -> Value {
    json!({
        "itemId": item.item_id,
        "state": item.state,
        "sourceType": item.source_type,
        "providerId": item.provider_id,
        "externalId": item.external_id,
        "payload": item.payload,
        "serverUrl": item.server_url,
        "uploadSessionId": item.upload_session_id,
        "jobId": item.job_id,
        "attempt": item.attempt,
        "createdAt": item.created_at,
        "updatedAt": item.updated_at,
        "lastError": item.last_error
    })
}

fn infer_source_type(payload: &Value) -> &'static str {
    match payload.get("kind").and_then(Value::as_str).unwrap_or("") {
        "directory" => "local-directory",
        "file" => "local-file",
        "text" => "manual-text",
        "mail-scope" => "macos-mail",
        _ => "source-item",
    }
}

fn external_id_for(source_type: &str, provider_id: &str, payload: &Value) -> String {
    if let Some(path) = payload.get("path").and_then(Value::as_str) {
        return format!("path:{}", sha256_hex(path.as_bytes()));
    }
    if let Some(text) = payload.get("text").and_then(Value::as_str) {
        return format!("text:{}", sha256_hex(text.as_bytes()));
    }
    format!(
        "generated:{}:{}:{}",
        source_type,
        provider_id,
        Uuid::new_v4()
    )
}

fn ensure_object(value: &mut Value) -> &mut Map<String, Value> {
    if !value.is_object() {
        *value = json!({});
    }
    value.as_object_mut().expect("object was just created")
}

fn sanitize_relative_path(value: &str) -> String {
    let cleaned = value
        .replace('\\', "/")
        .trim_start_matches('/')
        .split('/')
        .filter(|part| !part.is_empty() && *part != "." && *part != "..")
        .collect::<Vec<_>>()
        .join("/");
    if cleaned.is_empty() {
        "source-file".into()
    } else {
        cleaned
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

fn json_param(params: &Value, key: &str) -> Option<Value> {
    params.get(key).and_then(|value| {
        if value.is_object() || value.is_array() {
            Some(value.clone())
        } else {
            value
                .as_str()
                .and_then(|text| serde_json::from_str::<Value>(text).ok())
        }
    })
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
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

fn display_path(path: &Path) -> String {
    path.display().to_string()
}

fn append_activity(event_type: &str, payload: Value) {
    if let Ok(log) = ActivityLog::portable() {
        let _ = log.append(event_type, payload);
    }
}

#[cfg(unix)]
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_dedupes_by_source_identity() {
        let root = std::env::temp_dir().join(format!("source-queue-test-{}", timestamp()));
        let store = SourceQueueStore::new(root).unwrap();
        let params = json!({
            "text": "hello",
            "sourceType": "manual-text",
            "providerId": "test",
            "externalId": "same"
        });
        let first = store.enqueue(normalize_item(&params).unwrap()).unwrap();
        let second = store.enqueue(normalize_item(&params).unwrap()).unwrap();
        assert_eq!(first["status"], "enqueued");
        assert_eq!(second["status"], "deduped");
        assert_eq!(store.status().unwrap()["counts"]["pending"], 1);
    }

    #[test]
    fn drain_defers_without_server_url() {
        let root = std::env::temp_dir().join(format!("source-queue-defer-{}", timestamp()));
        let store = SourceQueueStore::new(root).unwrap();
        store
            .enqueue(normalize_item(&json!({"text": "hello"})).unwrap())
            .unwrap();
        let drained = store.drain(&json!({})).unwrap();
        assert_eq!(drained["status"], "drained");
        assert_eq!(drained["deferred"], 1);
        assert_eq!(store.status().unwrap()["counts"]["pending"], 1);
    }
}
