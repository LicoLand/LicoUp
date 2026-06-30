use crate::client_state::ClientStateStore;
use anyhow::{Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const KNOWLEDGE_CACHE_SCHEMA_VERSION: &str = "v0.0.1:knowledge-cache-mirror-1";
const KNOWLEDGE_CACHE_DIR: &str = "knowledge-cache";
const KNOWLEDGE_CACHE_DB: &str = "knowledge-cache.sqlite";

struct KnowledgeCacheStore {
    root: PathBuf,
    db_path: PathBuf,
}

pub fn sync(params: &Value) -> Result<Value> {
    let store = KnowledgeCacheStore::from_params(params)?;
    store.sync(params)
}

pub fn search(params: &Value) -> Result<Value> {
    let store = KnowledgeCacheStore::from_params(params)?;
    store.search(params)
}

pub fn evidence(params: &Value) -> Result<Value> {
    get(params)
}

pub fn get(params: &Value) -> Result<Value> {
    let store = KnowledgeCacheStore::from_params(params)?;
    store.get(params)
}

pub fn status(params: &Value) -> Result<Value> {
    let store = KnowledgeCacheStore::from_params(params)?;
    store.status()
}

impl KnowledgeCacheStore {
    fn from_params(params: &Value) -> Result<Self> {
        let root = if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
            PathBuf::from(state_root).join(KNOWLEDGE_CACHE_DIR)
        } else {
            ClientStateStore::portable()?
                .root()
                .join(KNOWLEDGE_CACHE_DIR)
        };
        Self::new(root)
    }

    fn new(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let store = Self {
            db_path: root.join(KNOWLEDGE_CACHE_DB),
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
            CREATE TABLE IF NOT EXISTS knowledge_cache_evidence (
              evidence_id TEXT PRIMARY KEY,
              title TEXT NOT NULL DEFAULT '',
              body TEXT NOT NULL DEFAULT '',
              metadata_json TEXT NOT NULL DEFAULT '{}',
              server_url TEXT NOT NULL DEFAULT '',
              authorized_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              content_sha256 TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_knowledge_cache_updated
              ON knowledge_cache_evidence(updated_at);
            ",
        )?;
        let _ = conn.execute_batch(
            "
            CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_cache_fts
            USING fts5(evidence_id UNINDEXED, title, body);
            ",
        );
        Ok(())
    }

    fn sync(&self, params: &Value) -> Result<Value> {
        let entries = evidence_entries(params)?;
        if entries.is_empty() {
            return Err(anyhow!(
                "knowledge-cache sync requires --evidence-json or --evidence-file; online KnowledgeCore remains authoritative"
            ));
        }
        let server_url = text_param(params, &["serverUrl"]).unwrap_or_default();
        let conn = self.conn()?;
        let now = timestamp();
        let mut upserted = Vec::new();
        for raw in entries {
            let normalized = normalize_evidence(raw, &server_url, &now);
            conn.execute(
                "
                INSERT INTO knowledge_cache_evidence (
                  evidence_id, title, body, metadata_json, server_url,
                  authorized_at, updated_at, content_sha256
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?7)
                ON CONFLICT(evidence_id) DO UPDATE SET
                  title = excluded.title,
                  body = excluded.body,
                  metadata_json = excluded.metadata_json,
                  server_url = excluded.server_url,
                  updated_at = excluded.updated_at,
                  content_sha256 = excluded.content_sha256
                ",
                params![
                    normalized["evidenceId"].as_str().unwrap_or_default(),
                    normalized["title"].as_str().unwrap_or_default(),
                    normalized["body"].as_str().unwrap_or_default(),
                    serde_json::to_string(normalized.get("metadata").unwrap_or(&json!({})))?,
                    server_url,
                    now,
                    normalized["contentSha256"].as_str().unwrap_or_default()
                ],
            )?;
            let _ = conn.execute(
                "DELETE FROM knowledge_cache_fts WHERE evidence_id = ?1",
                params![normalized["evidenceId"].as_str().unwrap_or_default()],
            );
            let _ = conn.execute(
                "
                INSERT INTO knowledge_cache_fts(evidence_id, title, body)
                VALUES (?1, ?2, ?3)
                ",
                params![
                    normalized["evidenceId"].as_str().unwrap_or_default(),
                    normalized["title"].as_str().unwrap_or_default(),
                    normalized["body"].as_str().unwrap_or_default()
                ],
            );
            upserted.push(normalized);
        }
        Ok(json!({
            "ok": true,
            "schemaVersion": KNOWLEDGE_CACHE_SCHEMA_VERSION,
            "status": "synced",
            "authoritative": false,
            "mode": "authorized-mirror",
            "upserted": upserted.len(),
            "items": upserted,
            "cacheRoot": display_path(&self.root)
        }))
    }

    fn search(&self, params: &Value) -> Result<Value> {
        let query = text_param(params, &["query", "q", "text"])
            .ok_or_else(|| anyhow!("knowledge-cache search requires --query"))?;
        let limit = number_param(params, &["limit"]).unwrap_or(20).clamp(1, 100) as i64;
        let conn = self.conn()?;
        let escaped_query = query.replace('"', " ");
        let fts_results = conn
            .prepare(
                "
                SELECT e.*
                FROM knowledge_cache_fts f
                JOIN knowledge_cache_evidence e ON e.evidence_id = f.evidence_id
                WHERE knowledge_cache_fts MATCH ?1
                ORDER BY rank
                LIMIT ?2
                ",
            )
            .and_then(|mut stmt| {
                let rows = stmt.query_map(params![escaped_query, limit], row_to_evidence)?;
                let mut values = Vec::new();
                for row in rows {
                    values.push(row?);
                }
                Ok(values)
            });
        let results = match fts_results {
            Ok(results) => results,
            Err(_) => self.like_search(&conn, &query, limit)?,
        };
        Ok(json!({
            "ok": true,
            "schemaVersion": KNOWLEDGE_CACHE_SCHEMA_VERSION,
            "status": "ok",
            "authoritative": false,
            "mode": "authorized-mirror",
            "query": query,
            "results": results
        }))
    }

    fn like_search(&self, conn: &Connection, query: &str, limit: i64) -> Result<Vec<Value>> {
        let needle = format!("%{}%", query);
        let mut stmt = conn.prepare(
            "
            SELECT * FROM knowledge_cache_evidence
            WHERE title LIKE ?1 OR body LIKE ?1 OR metadata_json LIKE ?1
            ORDER BY updated_at DESC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![needle, limit], row_to_evidence)?;
        let mut values = Vec::new();
        for row in rows {
            values.push(row?);
        }
        Ok(values)
    }

    fn get(&self, params: &Value) -> Result<Value> {
        let evidence_id = text_param(params, &["evidenceId", "id", "target"])
            .ok_or_else(|| anyhow!("knowledge-cache get requires --evidence-id"))?;
        let conn = self.conn()?;
        let item = conn
            .query_row(
                "SELECT * FROM knowledge_cache_evidence WHERE evidence_id = ?1",
                params![evidence_id],
                row_to_evidence,
            )
            .optional()?;
        match item {
            Some(item) => Ok(json!({
                "ok": true,
                "schemaVersion": KNOWLEDGE_CACHE_SCHEMA_VERSION,
                "authoritative": false,
                "mode": "authorized-mirror",
                "evidence": item
            })),
            None => Ok(json!({
                "ok": false,
                "schemaVersion": KNOWLEDGE_CACHE_SCHEMA_VERSION,
                "status": "not_found",
                "authoritative": false,
                "evidenceId": evidence_id
            })),
        }
    }

    fn status(&self) -> Result<Value> {
        let conn = self.conn()?;
        let count = conn.query_row("SELECT COUNT(*) FROM knowledge_cache_evidence", [], |row| {
            row.get::<_, i64>(0)
        })?;
        Ok(json!({
            "ok": true,
            "schemaVersion": KNOWLEDGE_CACHE_SCHEMA_VERSION,
            "status": "ready",
            "authoritative": false,
            "mode": "authorized-mirror",
            "evidenceCount": count,
            "cacheRoot": display_path(&self.root),
            "dbPath": display_path(&self.db_path)
        }))
    }
}

fn evidence_entries(params: &Value) -> Result<Vec<Value>> {
    if let Some(value) = json_param(params, "evidenceJson") {
        return Ok(entries_from_value(value));
    }
    if let Some(path) = text_param(params, &["evidenceFile", "file"]) {
        let raw = fs::read_to_string(path)?;
        let value = serde_json::from_str::<Value>(&raw)?;
        return Ok(entries_from_value(value));
    }
    Ok(Vec::new())
}

fn entries_from_value(value: Value) -> Vec<Value> {
    if let Some(array) = value.as_array() {
        return array.clone();
    }
    if let Some(array) = value.get("items").and_then(Value::as_array) {
        return array.clone();
    }
    if let Some(array) = value.get("evidence").and_then(Value::as_array) {
        return array.clone();
    }
    vec![value]
}

fn normalize_evidence(raw: Value, server_url: &str, now: &str) -> Value {
    let title = first_string(&raw, &["title", "name", "label"]).unwrap_or_default();
    let body = first_string(&raw, &["body", "text", "content", "preview"]).unwrap_or_default();
    let mut metadata = Map::new();
    if let Some(object) = raw.get("metadata").and_then(Value::as_object) {
        for (key, value) in object {
            metadata.insert(key.clone(), value.clone());
        }
    }
    metadata.insert("serverUrl".into(), json!(server_url));
    metadata.insert("mirroredAt".into(), json!(now));
    let evidence_id = first_string(&raw, &["evidenceId", "id"]).unwrap_or_else(|| {
        let digest = sha256_hex(format!("{}:{}", title, body).as_bytes());
        if title.is_empty() && body.is_empty() {
            format!("evidence-{}", Uuid::new_v4())
        } else {
            format!("evidence-{}", &digest[..24])
        }
    });
    let content_sha256 = sha256_hex(format!("{}:{}:{}", evidence_id, title, body).as_bytes());
    json!({
        "evidenceId": evidence_id,
        "title": title,
        "body": body,
        "metadata": Value::Object(metadata),
        "serverUrl": server_url,
        "authorizedAt": now,
        "updatedAt": now,
        "contentSha256": content_sha256
    })
}

fn row_to_evidence(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let metadata_json: String = row.get("metadata_json")?;
    let metadata = serde_json::from_str::<Value>(&metadata_json).unwrap_or_else(|_| json!({}));
    Ok(json!({
        "evidenceId": row.get::<_, String>("evidence_id")?,
        "title": row.get::<_, String>("title")?,
        "body": row.get::<_, String>("body")?,
        "metadata": metadata,
        "serverUrl": row.get::<_, String>("server_url")?,
        "authorizedAt": row.get::<_, String>("authorized_at")?,
        "updatedAt": row.get::<_, String>("updated_at")?,
        "contentSha256": row.get::<_, String>("content_sha256")?
    }))
}

fn first_string(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(str::to_string)
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_and_search_mirror_evidence() {
        let root = std::env::temp_dir().join(format!("knowledge-cache-test-{}", timestamp()));
        let store = KnowledgeCacheStore::new(root).unwrap();
        let synced = store
            .sync(&json!({
                "evidenceJson": {
                    "id": "ev-1",
                    "title": "Queue recovery",
                    "text": "Source queue resumes upload sessions."
                }
            }))
            .unwrap();
        assert_eq!(synced["upserted"], 1);
        let results = store.search(&json!({"query": "queue"})).unwrap();
        assert_eq!(results["authoritative"], false);
        assert!(!results["results"].as_array().unwrap().is_empty());
    }
}
