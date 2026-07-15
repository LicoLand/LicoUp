use crate::domain::conversation_snapshots;
use crate::domain::targets;
use crate::platform::client_state::ClientStateStore;
use crate::platform::paths::portable_data_dir;
use anyhow::{Result, anyhow};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const ARCHIVE_JOB_SCHEMA_VERSION: &str = "v0.0.1:conversation-archive-jobs-1";
const ARCHIVE_JOB_DIR: &str = "conversation-archive-jobs";
const ARCHIVE_JOB_DB: &str = "conversation-archive-jobs.sqlite";
const DEFAULT_MAX_ATTEMPTS: u64 = 2;

#[derive(Clone, Debug)]
struct ArchiveJob {
    job_id: String,
    request: Value,
    target_scan: Value,
    status: String,
    phase: String,
    attempt: u64,
    max_attempts: u64,
    archive_result: Value,
    validation_result: Value,
    created_at: String,
    updated_at: String,
    retry_after: String,
    last_error: String,
    completed_at: String,
    failed_at: String,
    cancelled_at: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ArchiveJobStatus {
    Queued,
    Scanning,
    Archiving,
    Verifying,
    RetryScheduled,
    Completed,
    Failed,
    Cancelled,
}

impl ArchiveJobStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Scanning => "scanning",
            Self::Archiving => "archiving",
            Self::Verifying => "verifying",
            Self::RetryScheduled => "retry_scheduled",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "queued" => Ok(Self::Queued),
            "scanning" => Ok(Self::Scanning),
            "archiving" => Ok(Self::Archiving),
            "verifying" => Ok(Self::Verifying),
            "retry_scheduled" => Ok(Self::RetryScheduled),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            other => Err(anyhow!("unknown archive job status: {}", other)),
        }
    }

    fn terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

struct RetryPolicy {
    max_attempts: u64,
    base_backoff_seconds: u64,
}

impl RetryPolicy {
    fn from_request(request: &Value) -> Self {
        Self {
            max_attempts: number_param(request, &["maxAttempts"])
                .unwrap_or(DEFAULT_MAX_ATTEMPTS)
                .clamp(1, 10),
            base_backoff_seconds: number_param(request, &["retryBackoffSeconds"]).unwrap_or(0),
        }
    }

    fn should_retry(&self, attempt: u64, error_kind: &str) -> bool {
        attempt < self.max_attempts
            && matches!(
                error_kind,
                "archive_failed" | "archive_error" | "verification_failed" | "verification_error"
            )
    }

    fn retry_after(&self, attempt: u64) -> String {
        if self.base_backoff_seconds == 0 {
            return String::new();
        }
        let shift = attempt.saturating_sub(1).min(10) as u32;
        let multiplier = 1_u64.checked_shl(shift).unwrap_or(1 << 10);
        timestamp_after_seconds(self.base_backoff_seconds.saturating_mul(multiplier))
    }
}

struct ArchiveJobStore {
    root: PathBuf,
    db_path: PathBuf,
}

pub fn create(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.create(params)
}

pub fn status(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.status(params)
}

pub fn list(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.list(params)
}

pub fn events(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.events(params)
}

pub fn cancel(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.cancel(params)
}

pub fn drain(params: &Value) -> Result<Value> {
    let store = ArchiveJobStore::from_params(params)?;
    store.drain(params)
}

impl ArchiveJobStore {
    fn from_params(params: &Value) -> Result<Self> {
        let root = if let Some(state_root) = text_param(params, &["stateRoot", "clientStateRoot"]) {
            ClientStateStore::new(expand_home(&state_root))?
                .root()
                .join(ARCHIVE_JOB_DIR)
        } else if let Some(portable_dir) = text_param(params, &["portableDir"]) {
            ClientStateStore::new(expand_home(&portable_dir).join("lico-client"))?
                .root()
                .join(ARCHIVE_JOB_DIR)
        } else {
            ClientStateStore::new(portable_data_dir()?.join("lico-client"))?
                .root()
                .join(ARCHIVE_JOB_DIR)
        };
        Self::new(root)
    }

    fn new(root: PathBuf) -> Result<Self> {
        fs::create_dir_all(&root)?;
        let store = Self {
            db_path: root.join(ARCHIVE_JOB_DB),
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
            CREATE TABLE IF NOT EXISTS conversation_archive_jobs (
              job_id TEXT PRIMARY KEY,
              request_json TEXT NOT NULL,
              target_scan_json TEXT NOT NULL,
              status TEXT NOT NULL,
              phase TEXT NOT NULL,
              attempt INTEGER NOT NULL DEFAULT 0,
              max_attempts INTEGER NOT NULL DEFAULT 2,
              archive_result_json TEXT NOT NULL DEFAULT '{}',
              validation_result_json TEXT NOT NULL DEFAULT '{}',
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              retry_after TEXT NOT NULL DEFAULT '',
              last_error TEXT NOT NULL DEFAULT '',
              completed_at TEXT NOT NULL DEFAULT '',
              failed_at TEXT NOT NULL DEFAULT '',
              cancelled_at TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_conversation_archive_jobs_status
              ON conversation_archive_jobs(status, updated_at);
            CREATE TABLE IF NOT EXISTS conversation_archive_job_events (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              job_id TEXT NOT NULL,
              event_type TEXT NOT NULL,
              phase TEXT NOT NULL,
              status TEXT NOT NULL,
              attempt INTEGER NOT NULL,
              payload_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY(job_id) REFERENCES conversation_archive_jobs(job_id)
            );
            CREATE INDEX IF NOT EXISTS idx_conversation_archive_job_events_job
              ON conversation_archive_job_events(job_id, sequence);
            ",
        )?;
        Ok(())
    }

    fn create(&self, params: &Value) -> Result<Value> {
        let request = normalize_request(params)?;
        let policy = RetryPolicy::from_request(&request);
        let job_id = text_param(params, &["jobId"]).unwrap_or_else(|| job_id_for(&request));
        let conn = self.conn()?;
        if let Some(existing) = self.get_job(&conn, &job_id)? {
            return Ok(self.job_response(&conn, existing)?);
        }

        let now = timestamp();
        let mut scan_params = request.clone();
        if let Some(object) = scan_params.as_object_mut() {
            object.insert("archiveMode".to_string(), json!(true));
        }
        let target_scan = targets::scan_targets_with_params(&scan_params)?;
        conn.execute(
            "
            INSERT INTO conversation_archive_jobs (
              job_id, request_json, target_scan_json, status, phase, attempt, max_attempts,
              archive_result_json, validation_result_json, created_at, updated_at, retry_after,
              last_error, completed_at, failed_at, cancelled_at
            )
            VALUES (?1, ?2, ?3, 'queued', 'queued', 0, ?4, '{}', '{}', ?5, ?5, '', '', '', '', '')
            ",
            params![
                job_id,
                serde_json::to_string(&request)?,
                serde_json::to_string(&target_scan)?,
                policy.max_attempts,
                now,
            ],
        )?;
        let job = self
            .get_job(&conn, &job_id)?
            .ok_or_else(|| anyhow!("archive job insert failed"))?;
        self.append_event(
            &conn,
            &job.job_id,
            "archive.scan.completed",
            ArchiveJobStatus::Queued,
            0,
            json!({ "targetScan": target_scan_summary(&job.target_scan) }),
        )?;
        self.append_event(
            &conn,
            &job.job_id,
            "archive.job.queued",
            ArchiveJobStatus::Queued,
            0,
            json!({ "jobId": job.job_id }),
        )?;
        append_activity(
            "conversation_archive_jobs.created",
            json!({
                "target": "conversation-archive-jobs",
                "jobId": job.job_id,
                "status": job.status,
                "targetScan": target_scan_summary(&job.target_scan)
            }),
        );
        self.job_response(&conn, job)
    }

    fn status(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let job_id = required_job_id(params)?;
        let job = self
            .get_job(&conn, &job_id)?
            .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job_id))?;
        self.job_response(&conn, job)
    }

    fn list(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let status = text_param(params, &["status"]).unwrap_or_default();
        let limit = number_param(params, &["limit"])
            .unwrap_or(100)
            .clamp(1, 1000) as i64;
        let mut stmt = conn.prepare(
            "
            SELECT * FROM conversation_archive_jobs
            WHERE (?1 = '' OR status = ?1)
            ORDER BY created_at DESC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![status, limit], row_to_job)?;
        let mut jobs = Vec::<Value>::new();
        for row in rows {
            jobs.push(job_to_json(row?));
        }
        Ok(json!({
            "ok": true,
            "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
            "jobs": jobs,
            "jobRoot": display_path(&self.root),
            "dbPath": display_path(&self.db_path)
        }))
    }

    fn events(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let job_id = required_job_id(params)?;
        let events = self.list_events(&conn, &job_id, number_param(params, &["limit"]))?;
        Ok(json!({
            "ok": true,
            "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
            "jobId": job_id,
            "events": events
        }))
    }

    fn cancel(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let job_id = required_job_id(params)?;
        let job = self
            .get_job(&conn, &job_id)?
            .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job_id))?;
        if ArchiveJobStatus::from_str(&job.status)?.terminal() {
            return self.job_response(&conn, job);
        }
        let now = timestamp();
        conn.execute(
            "
            UPDATE conversation_archive_jobs
            SET status = 'cancelled', phase = 'cancelled', updated_at = ?1,
                cancelled_at = ?1, last_error = 'operator_cancelled'
            WHERE job_id = ?2
            ",
            params![now, job_id],
        )?;
        self.append_event(
            &conn,
            &job_id,
            "archive.cancelled",
            ArchiveJobStatus::Cancelled,
            job.attempt,
            json!({ "reason": text_param(params, &["reason"]).unwrap_or_else(|| "operator_cancelled".to_string()) }),
        )?;
        let job = self
            .get_job(&conn, &job_id)?
            .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job_id))?;
        self.job_response(&conn, job)
    }

    fn drain(&self, params: &Value) -> Result<Value> {
        let conn = self.conn()?;
        let once = bool_param(params, &["once"]).unwrap_or(false);
        let stop_on_error = bool_param(params, &["stopOnError"]).unwrap_or(false);
        let mut processed = Vec::<Value>::new();
        let mut completed = 0_u64;
        let mut failed = 0_u64;
        let mut deferred = 0_u64;

        loop {
            let jobs = self.next_jobs(&conn, params)?;
            if jobs.is_empty() {
                break;
            }
            for job in jobs {
                let job_id = job.job_id.clone();
                let outcome = self.advance_job(&conn, job)?;
                let status = outcome
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if status == "completed" {
                    completed += 1;
                } else if status == "failed" {
                    failed += 1;
                } else if status == "retry_scheduled" {
                    deferred += 1;
                }
                processed.push(json!({
                    "jobId": job_id,
                    "outcome": outcome
                }));
                if once || (stop_on_error && status == "failed") {
                    return Ok(json!({
                        "ok": true,
                        "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
                        "status": "drained",
                        "processed": processed.len(),
                        "completed": completed,
                        "failed": failed,
                        "deferred": deferred,
                        "jobs": processed
                    }));
                }
            }
        }

        Ok(json!({
            "ok": true,
            "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
            "status": "drained",
            "processed": processed.len(),
            "completed": completed,
            "failed": failed,
            "deferred": deferred,
            "jobs": processed
        }))
    }

    fn next_jobs(&self, conn: &Connection, params: &Value) -> Result<Vec<ArchiveJob>> {
        let job_id = text_param(params, &["jobId"]);
        let limit = if job_id.is_some() {
            1
        } else {
            number_param(params, &["limit"]).unwrap_or(10).clamp(1, 100) as i64
        };
        let mut stmt = conn.prepare(
            "
            SELECT * FROM conversation_archive_jobs
            WHERE status IN ('queued', 'archiving', 'verifying', 'retry_scheduled')
              AND (?1 = '' OR job_id = ?1)
            ORDER BY created_at ASC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![job_id.unwrap_or_default(), limit], row_to_job)?;
        let mut jobs = Vec::new();
        for row in rows {
            jobs.push(row?);
        }
        Ok(jobs)
    }

    fn advance_job(&self, conn: &Connection, job: ArchiveJob) -> Result<Value> {
        match ArchiveJobStatus::from_str(&job.status)? {
            ArchiveJobStatus::Queued | ArchiveJobStatus::RetryScheduled => {
                self.run_archive_step(conn, job)
            }
            ArchiveJobStatus::Archiving => self.run_archive_step(conn, job),
            ArchiveJobStatus::Verifying => self.run_verify_step(conn, job),
            ArchiveJobStatus::Scanning
            | ArchiveJobStatus::Completed
            | ArchiveJobStatus::Failed
            | ArchiveJobStatus::Cancelled => self.job_response(conn, job),
        }
    }

    fn run_archive_step(&self, conn: &Connection, mut job: ArchiveJob) -> Result<Value> {
        if self.is_cancelled(conn, &job.job_id)? {
            let updated = self
                .get_job(conn, &job.job_id)?
                .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job.job_id))?;
            return self.job_response(conn, updated);
        }
        let attempt = job.attempt + 1;
        let now = timestamp();
        conn.execute(
            "
            UPDATE conversation_archive_jobs
            SET status = 'archiving', phase = 'archiving', attempt = ?1,
                updated_at = ?2, retry_after = '', last_error = ''
            WHERE job_id = ?3
            ",
            params![attempt, now, job.job_id],
        )?;
        self.append_event(
            conn,
            &job.job_id,
            "archive.run.started",
            ArchiveJobStatus::Archiving,
            attempt,
            json!({ "attempt": attempt }),
        )?;
        job.attempt = attempt;

        let archive_params = merge_params(
            &job.request,
            json!({
                "targetScan": job.target_scan,
                "trigger": "conversation-archive-job",
                "jobId": job.job_id
            }),
        );
        match conversation_snapshots::archive_collect(&archive_params) {
            Ok(result) => {
                let archive_ok = result.get("ok").and_then(Value::as_bool).unwrap_or(false);
                conn.execute(
                    "
                    UPDATE conversation_archive_jobs
                    SET archive_result_json = ?1, updated_at = ?2
                    WHERE job_id = ?3
                    ",
                    params![serde_json::to_string(&result)?, timestamp(), job.job_id],
                )?;
                self.append_event(
                    conn,
                    &job.job_id,
                    if archive_ok {
                        "archive.run.completed"
                    } else {
                        "archive.run.failed"
                    },
                    ArchiveJobStatus::Archiving,
                    attempt,
                    json!({ "result": result.clone() }),
                )?;
                if archive_ok {
                    conn.execute(
                        "
                        UPDATE conversation_archive_jobs
                        SET status = 'verifying', phase = 'verifying', updated_at = ?1,
                            last_error = ''
                        WHERE job_id = ?2
                        ",
                        params![timestamp(), job.job_id],
                    )?;
                    self.append_event(
                        conn,
                        &job.job_id,
                        "archive.verify.started",
                        ArchiveJobStatus::Verifying,
                        attempt,
                        json!({ "attempt": attempt }),
                    )?;
                    let updated = self.get_job(conn, &job.job_id)?.ok_or_else(|| {
                        anyhow!("unknown conversation archive job: {}", job.job_id)
                    })?;
                    self.job_response(conn, updated)
                } else {
                    self.handle_retry_or_fail(
                        conn,
                        job,
                        "archive_failed",
                        result
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("archive returned ok=false"),
                        json!({ "archiveResult": result }),
                    )
                }
            }
            Err(error) => {
                self.append_event(
                    conn,
                    &job.job_id,
                    "archive.run.failed",
                    ArchiveJobStatus::Archiving,
                    attempt,
                    json!({ "error": error.to_string() }),
                )?;
                self.handle_retry_or_fail(
                    conn,
                    job,
                    "archive_error",
                    &error.to_string(),
                    json!({ "error": error.to_string() }),
                )
            }
        }
    }

    fn run_verify_step(&self, conn: &Connection, job: ArchiveJob) -> Result<Value> {
        if self.is_cancelled(conn, &job.job_id)? {
            let updated = self
                .get_job(conn, &job.job_id)?
                .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job.job_id))?;
            return self.job_response(conn, updated);
        }
        let collection_paths = archive_collection_paths(&job.archive_result);
        let mut collections = Vec::<Value>::new();
        let mut had_error = false;
        for collection_path in collection_paths {
            let verify_params = merge_params(
                &job.request,
                json!({
                    "collectionPath": collection_path,
                    "jobId": job.job_id
                }),
            );
            match conversation_snapshots::archive_verify(&verify_params) {
                Ok(verified) => collections.push(verified),
                Err(error) => {
                    had_error = true;
                    collections.push(json!({
                        "ok": false,
                        "collectionPath": collection_path,
                        "validation": failed_validation(&collection_path, &error.to_string())
                    }));
                }
            }
        }
        if collections.is_empty() {
            had_error = true;
            collections.push(json!({
                "ok": false,
                "collectionPath": "",
                "validation": failed_validation("", "archive produced no collection paths")
            }));
        }
        let validation = aggregate_validations(&collections);
        let verification_ok = !had_error
            && validation
                .get("healthStatus")
                .and_then(Value::as_str)
                .is_some_and(|status| status != "failed");
        let validation_result = json!({
            "ok": verification_ok,
            "mode": "conversation-archive-job-verify",
            "collectionCount": collections.len(),
            "collections": collections,
            "validation": validation
        });
        conn.execute(
            "
            UPDATE conversation_archive_jobs
            SET validation_result_json = ?1, updated_at = ?2
            WHERE job_id = ?3
            ",
            params![
                serde_json::to_string(&validation_result)?,
                timestamp(),
                job.job_id
            ],
        )?;
        self.append_event(
            conn,
            &job.job_id,
            if verification_ok {
                "archive.verify.completed"
            } else {
                "archive.verify.failed"
            },
            ArchiveJobStatus::Verifying,
            job.attempt,
            json!({ "validation": validation_result.clone() }),
        )?;
        if verification_ok {
            let now = timestamp();
            conn.execute(
                "
                UPDATE conversation_archive_jobs
                SET status = 'completed', phase = 'completed', updated_at = ?1,
                    completed_at = ?1, last_error = ''
                WHERE job_id = ?2
                ",
                params![now, job.job_id],
            )?;
            self.append_event(
                conn,
                &job.job_id,
                "archive.completed",
                ArchiveJobStatus::Completed,
                job.attempt,
                json!({ "validation": validation_result }),
            )?;
            let updated = self
                .get_job(conn, &job.job_id)?
                .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job.job_id))?;
            append_activity(
                "conversation_archive_jobs.completed",
                json!({
                    "target": "conversation-archive-jobs",
                    "jobId": updated.job_id,
                    "attempt": updated.attempt,
                    "validation": updated.validation_result.get("validation").cloned().unwrap_or_else(|| json!({}))
                }),
            );
            self.job_response(conn, updated)
        } else {
            self.handle_retry_or_fail(
                conn,
                job,
                if had_error {
                    "verification_error"
                } else {
                    "verification_failed"
                },
                "archive verification failed",
                json!({ "validation": validation_result }),
            )
        }
    }

    fn handle_retry_or_fail(
        &self,
        conn: &Connection,
        job: ArchiveJob,
        error_kind: &str,
        message: &str,
        payload: Value,
    ) -> Result<Value> {
        let policy = RetryPolicy {
            max_attempts: job.max_attempts,
            base_backoff_seconds: RetryPolicy::from_request(&job.request).base_backoff_seconds,
        };
        let now = timestamp();
        if policy.should_retry(job.attempt, error_kind) {
            let retry_after = policy.retry_after(job.attempt);
            conn.execute(
                "
                UPDATE conversation_archive_jobs
                SET status = 'retry_scheduled', phase = 'retry_scheduled',
                    updated_at = ?1, retry_after = ?2, last_error = ?3
                WHERE job_id = ?4
                ",
                params![now, retry_after, message, job.job_id],
            )?;
            self.append_event(
                conn,
                &job.job_id,
                "archive.retry.scheduled",
                ArchiveJobStatus::RetryScheduled,
                job.attempt,
                json!({
                    "errorKind": error_kind,
                    "message": message,
                    "retryAfter": retry_after,
                    "nextAttempt": job.attempt + 1,
                    "payload": payload
                }),
            )?;
        } else {
            conn.execute(
                "
                UPDATE conversation_archive_jobs
                SET status = 'failed', phase = 'failed', updated_at = ?1,
                    failed_at = ?1, last_error = ?2
                WHERE job_id = ?3
                ",
                params![now, message, job.job_id],
            )?;
            self.append_event(
                conn,
                &job.job_id,
                "archive.failed",
                ArchiveJobStatus::Failed,
                job.attempt,
                json!({
                    "errorKind": error_kind,
                    "message": message,
                    "deadLetter": true,
                    "payload": payload
                }),
            )?;
        }
        let updated = self
            .get_job(conn, &job.job_id)?
            .ok_or_else(|| anyhow!("unknown conversation archive job: {}", job.job_id))?;
        self.job_response(conn, updated)
    }

    fn is_cancelled(&self, conn: &Connection, job_id: &str) -> Result<bool> {
        let status = conn
            .query_row(
                "SELECT status FROM conversation_archive_jobs WHERE job_id = ?1",
                params![job_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .unwrap_or_default();
        Ok(status == "cancelled")
    }

    fn get_job(&self, conn: &Connection, job_id: &str) -> Result<Option<ArchiveJob>> {
        conn.query_row(
            "SELECT * FROM conversation_archive_jobs WHERE job_id = ?1",
            params![job_id],
            row_to_job,
        )
        .optional()
        .map_err(Into::into)
    }

    fn append_event(
        &self,
        conn: &Connection,
        job_id: &str,
        event_type: &str,
        status: ArchiveJobStatus,
        attempt: u64,
        payload: Value,
    ) -> Result<()> {
        conn.execute(
            "
            INSERT INTO conversation_archive_job_events
              (job_id, event_type, phase, status, attempt, payload_json, created_at)
            VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6)
            ",
            params![
                job_id,
                event_type,
                status.as_str(),
                attempt,
                serde_json::to_string(&payload)?,
                timestamp(),
            ],
        )?;
        Ok(())
    }

    fn list_events(
        &self,
        conn: &Connection,
        job_id: &str,
        limit: Option<u64>,
    ) -> Result<Vec<Value>> {
        let limit = limit.unwrap_or(1000).clamp(1, 5000) as i64;
        let mut stmt = conn.prepare(
            "
            SELECT sequence, job_id, event_type, phase, status, attempt, payload_json, created_at
            FROM conversation_archive_job_events
            WHERE job_id = ?1
            ORDER BY sequence ASC
            LIMIT ?2
            ",
        )?;
        let rows = stmt.query_map(params![job_id, limit], |row| {
            let payload_raw: String = row.get(6)?;
            let payload = serde_json::from_str::<Value>(&payload_raw).unwrap_or_else(|_| json!({}));
            Ok(json!({
                "sequence": row.get::<_, i64>(0)?,
                "jobId": row.get::<_, String>(1)?,
                "type": row.get::<_, String>(2)?,
                "phase": row.get::<_, String>(3)?,
                "status": row.get::<_, String>(4)?,
                "attempt": row.get::<_, u64>(5)?,
                "payload": payload,
                "createdAt": row.get::<_, String>(7)?
            }))
        })?;
        let mut events = Vec::new();
        for row in rows {
            events.push(row?);
        }
        Ok(events)
    }

    fn job_response(&self, conn: &Connection, job: ArchiveJob) -> Result<Value> {
        let job_status = job.status.clone();
        let events = self.list_events(conn, &job.job_id, Some(1000))?;
        let latest_event_status = events
            .last()
            .and_then(|event| event.get("status"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let event_consistency = json!({
            "ok": latest_event_status.is_empty() || latest_event_status == job_status,
            "jobStatus": job_status,
            "latestEventStatus": latest_event_status,
            "eventCount": events.len()
        });
        let mut value = job_to_json(job);
        if let Some(object) = value.as_object_mut() {
            object.insert("ok".to_string(), json!(true));
            object.insert(
                "schemaVersion".to_string(),
                json!(ARCHIVE_JOB_SCHEMA_VERSION),
            );
            object.insert("events".to_string(), Value::Array(events));
            object.insert("eventConsistency".to_string(), event_consistency);
            object.insert("jobRoot".to_string(), json!(display_path(&self.root)));
            object.insert("dbPath".to_string(), json!(display_path(&self.db_path)));
        }
        Ok(value)
    }
}

fn normalize_request(params: &Value) -> Result<Value> {
    let keywords = text_param(params, &["keywords", "keyword", "terms", "query", "topic"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("archive jobs create requires --keywords"))?;
    let path = text_param(
        params,
        &[
            "path",
            "archiveRoot",
            "destination",
            "destinationPath",
            "outputDir",
            "snapshotRoot",
        ],
    )
    .filter(|value| !value.trim().is_empty())
    .ok_or_else(|| anyhow!("archive jobs create requires --path"))?;
    let mut request = Map::new();
    for key in [
        "stateRoot",
        "clientStateRoot",
        "portableDir",
        "homeDir",
        "agent",
        "agentId",
        "target",
        "agents",
        "curation",
        "archiveParallelism",
        "parallelism",
        "includeAccessibleEnvironments",
        "maxAttempts",
        "retryBackoffSeconds",
    ] {
        if let Some(value) = params.get(key).filter(|value| !value.is_null()) {
            request.insert(key.to_string(), value.clone());
        }
    }
    request.insert("keywords".to_string(), json!(keywords));
    request.insert("path".to_string(), json!(path));
    request
        .entry("curation".to_string())
        .or_insert_with(|| json!("true"));
    request
        .entry("maxAttempts".to_string())
        .or_insert_with(|| json!(DEFAULT_MAX_ATTEMPTS));
    Ok(Value::Object(request))
}

fn required_job_id(params: &Value) -> Result<String> {
    text_param(params, &["jobId", "id"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("conversation archive jobs command requires --job-id"))
}

fn row_to_job(row: &rusqlite::Row<'_>) -> rusqlite::Result<ArchiveJob> {
    let request_raw: String = row.get("request_json")?;
    let target_scan_raw: String = row.get("target_scan_json")?;
    let archive_result_raw: String = row.get("archive_result_json")?;
    let validation_result_raw: String = row.get("validation_result_json")?;
    Ok(ArchiveJob {
        job_id: row.get("job_id")?,
        request: parse_json_field(&request_raw),
        target_scan: parse_json_field(&target_scan_raw),
        status: row.get("status")?,
        phase: row.get("phase")?,
        attempt: row.get("attempt")?,
        max_attempts: row.get("max_attempts")?,
        archive_result: parse_json_field(&archive_result_raw),
        validation_result: parse_json_field(&validation_result_raw),
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        retry_after: row.get("retry_after")?,
        last_error: row.get("last_error")?,
        completed_at: row.get("completed_at")?,
        failed_at: row.get("failed_at")?,
        cancelled_at: row.get("cancelled_at")?,
    })
}

fn parse_json_field(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap_or_else(|_| json!({}))
}

fn job_to_json(job: ArchiveJob) -> Value {
    let target_scan_summary = target_scan_summary(&job.target_scan);
    json!({
        "jobId": job.job_id,
        "request": job.request,
        "targetScan": job.target_scan,
        "targetScanSummary": target_scan_summary,
        "status": job.status,
        "phase": job.phase,
        "attempt": job.attempt,
        "maxAttempts": job.max_attempts,
        "archiveResult": job.archive_result,
        "validationResult": job.validation_result,
        "createdAt": job.created_at,
        "updatedAt": job.updated_at,
        "retryAfter": job.retry_after,
        "lastError": job.last_error,
        "completedAt": job.completed_at,
        "failedAt": job.failed_at,
        "cancelledAt": job.cancelled_at,
        "workflow": {
            "status": job.status,
            "currentPhase": job.phase,
            "attempt": job.attempt,
            "maxAttempts": job.max_attempts
        },
        "mode": "conversation-archive-job",
        "entry": "keyword-archive-job"
    })
}

fn archive_collection_paths(archive_result: &Value) -> Vec<String> {
    let mut paths = Vec::<String>::new();
    if let Some(archives) = archive_result.get("archives").and_then(Value::as_array) {
        for archive in archives {
            if let Some(path) = archive
                .get("collectionPath")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                paths.push(path.to_string());
            }
        }
    }
    if paths.is_empty() {
        if let Some(path) = archive_result
            .get("collectionPath")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            paths.push(path.to_string());
        }
    }
    paths.sort();
    paths.dedup();
    paths
}

fn aggregate_validations(collections: &[Value]) -> Value {
    if collections.len() == 1 {
        if let Some(validation) = collections[0].get("validation") {
            return validation.clone();
        }
    }
    let mut failed = false;
    let mut error_count = 0_u64;
    let mut warning_count = 0_u64;
    let mut record_count = 0_u64;
    let mut raw_content_bytes = 0_u64;
    let mut issues = Vec::<Value>::new();
    for collection in collections {
        let Some(validation) = collection.get("validation") else {
            failed = true;
            error_count += 1;
            continue;
        };
        failed = failed
            || validation
                .get("healthStatus")
                .and_then(Value::as_str)
                .is_some_and(|status| status == "failed");
        error_count += validation
            .get("errorCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        warning_count += validation
            .get("warningCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        record_count += validation
            .get("recordCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        raw_content_bytes += validation
            .get("rawContentBytes")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if let Some(items) = validation.get("issues").and_then(Value::as_array) {
            for issue in items {
                let mut issue = issue.clone();
                if let Some(object) = issue.as_object_mut() {
                    object.insert(
                        "collectionPath".to_string(),
                        collection
                            .get("collectionPath")
                            .cloned()
                            .unwrap_or_else(|| json!("")),
                    );
                }
                issues.push(issue);
            }
        }
    }
    json!({
        "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
        "healthStatus": if failed { "failed" } else { "ok" },
        "checkedAt": timestamp(),
        "recordCount": record_count,
        "rawContentBytes": raw_content_bytes,
        "errorCount": error_count,
        "warningCount": warning_count,
        "issues": issues
    })
}

fn failed_validation(collection_path: &str, message: &str) -> Value {
    json!({
        "schemaVersion": ARCHIVE_JOB_SCHEMA_VERSION,
        "healthStatus": "failed",
        "checkedAt": timestamp(),
        "recordCount": 0,
        "rawContentBytes": 0,
        "errorCount": 1,
        "warningCount": 0,
        "issues": [{
            "type": "archive_job_verification_error",
            "severity": "error",
            "collectionPath": collection_path,
            "message": message
        }]
    })
}

fn target_scan_summary(target_scan: &Value) -> Value {
    let candidates = target_scan
        .get("candidates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let detected = candidates
        .iter()
        .filter(|candidate| {
            candidate
                .get("status")
                .and_then(Value::as_str)
                .is_some_and(|status| status != "not-detected")
        })
        .count();
    json!({
        "source": target_scan.get("source").cloned().unwrap_or_else(|| json!("target-adapters")),
        "clientCount": candidates.len(),
        "detectedCount": detected,
        "clients": candidates.iter().map(|candidate| {
            json!({
                "target": candidate.get("target").cloned().unwrap_or_else(|| json!("")),
                "label": candidate.get("label").cloned().unwrap_or_else(|| json!("")),
                "status": candidate.get("status").cloned().unwrap_or_else(|| json!("")),
                "historyRoots": candidate.get("historyRoots").cloned().unwrap_or_else(|| json!([])),
                "remoteHistoryRoots": candidate.get("remoteHistoryRoots").cloned().unwrap_or_else(|| json!([]))
            })
        }).collect::<Vec<_>>()
    })
}

fn merge_params(base: &Value, overlay: Value) -> Value {
    let mut object = base.as_object().cloned().unwrap_or_default();
    if let Some(overlay) = overlay.as_object() {
        for (key, value) in overlay {
            object.insert(key.clone(), value.clone());
        }
    }
    Value::Object(object)
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
            value.as_u64().or_else(|| {
                value
                    .as_str()
                    .and_then(|text| text.trim().parse::<u64>().ok())
            })
        })
    })
}

fn bool_param(params: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value.as_bool().or_else(|| {
                value.as_str().map(|text| {
                    matches!(
                        text.trim().to_ascii_lowercase().as_str(),
                        "1" | "true" | "yes" | "on"
                    )
                })
            })
        })
    })
}

fn job_id_for(request: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(request).unwrap_or_default());
    hasher.update(timestamp().as_bytes());
    let digest = format!("{:x}", hasher.finalize());
    format!("conversation_archive_job_{}", &digest[..24])
}

fn timestamp_after_seconds(seconds: u64) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs().saturating_add(seconds);
    format!("{}.{:09}Z", secs, now.subsec_nanos())
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

fn expand_home(path: &str) -> PathBuf {
    if path == "~" || path.starts_with("~/") {
        if let Some(home) = directories::UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf()) {
            if path == "~" {
                return home;
            }
            return home.join(path.trim_start_matches("~/"));
        }
    }
    PathBuf::from(path)
}

fn append_activity(event_type: &str, payload: Value) {
    if let Ok(log) = ClientStateStore::portable().map(|store| store.activity_log()) {
        let _ = log.append(event_type, payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn create_job_persists_target_scan_and_queued_state() {
        let state = temp_dir("create-state");
        let home = temp_dir("create-home");
        let history = temp_dir("create-history");
        fs::write(
            history.join("history.jsonl"),
            r#"{"sessionId":"job-create","role":"user","content":"Durable job create"}"#,
        )
        .unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                "targets",
                json!({
                    "items": [{
                        "target": "codex",
                        "manual": true,
                        "historyRoots": [display_path(&history)]
                    }]
                }),
            )
            .unwrap();

        let result = create(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Durable job",
            "path": display_path(&temp_dir("create-archive")),
            "curation": "false"
        }))
        .unwrap();

        assert_eq!(result["status"], "queued");
        let candidates = result["targetScan"]["candidates"].as_array().unwrap();
        assert!(!candidates.is_empty());
        let target_ids = candidates
            .iter()
            .filter_map(|candidate| candidate["target"].as_str())
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(target_ids.len(), candidates.len());
        let history_path = display_path(&history);
        assert!(candidates.iter().any(|candidate| {
            candidate["target"] == "codex"
                && candidate["historyRoots"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|root| root.as_str() == Some(history_path.as_str()))
        }));
        assert!(
            result["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["type"] == "archive.scan.completed")
        );
        let listed = list(&json!({"stateRoot": display_path(&state)})).unwrap();
        assert_eq!(listed["jobs"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn drain_executes_archive_verify_completed() {
        let (state, home, archive_root) = archive_job_fixture("drain-complete", "Durable complete");
        let created = create(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Durable complete",
            "path": display_path(&archive_root),
            "curation": "false"
        }))
        .unwrap();
        let job_id = created["jobId"].as_str().unwrap();

        let drained = drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id
        }))
        .unwrap();

        assert_eq!(drained["completed"], 1);
        let status = status(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert_eq!(status["status"], "completed");
        assert_eq!(status["attempt"], 1);
        assert_eq!(
            status["validationResult"]["validation"]["healthStatus"],
            "ok"
        );
    }

    #[test]
    fn verify_failure_schedules_retry_using_same_target_scan() {
        let (state, home, archive_root) =
            archive_job_fixture("verify-retry", "Durable verification retry");
        let created = create(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Durable verification retry",
            "path": display_path(&archive_root),
            "curation": "false",
            "maxAttempts": 2
        }))
        .unwrap();
        let job_id = created["jobId"].as_str().unwrap();
        drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id,
            "once": "true"
        }))
        .unwrap();
        corrupt_first_raw_content(&archive_root, "durable-verification-retry");

        let verify = drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id,
            "once": "true"
        }))
        .unwrap();
        assert_eq!(verify["jobs"][0]["outcome"]["status"], "retry_scheduled");
        let first_status =
            status(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert_eq!(first_status["attempt"], 1);
        assert_eq!(first_status["targetScan"], created["targetScan"]);
        assert!(
            first_status["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["type"] == "archive.retry.scheduled")
        );

        let completed = drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id
        }))
        .unwrap();
        assert_eq!(completed["completed"], 1);
        let completed_status =
            status(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert_eq!(completed_status["status"], "completed");
        assert_eq!(completed_status["attempt"], 2);
        assert_eq!(completed_status["targetScan"], created["targetScan"]);
    }

    #[test]
    fn max_attempts_exhausted_fails_dead_letter_style() {
        let (state, home, archive_root) =
            archive_job_fixture("verify-failed", "Durable permanent failure");
        let created = create(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Durable permanent failure",
            "path": display_path(&archive_root),
            "curation": "false",
            "maxAttempts": 1
        }))
        .unwrap();
        let job_id = created["jobId"].as_str().unwrap();
        drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id,
            "once": "true"
        }))
        .unwrap();
        corrupt_first_raw_content(&archive_root, "durable-permanent-failure");

        let drained = drain(&json!({
            "stateRoot": display_path(&state),
            "jobId": job_id,
            "once": "true"
        }))
        .unwrap();

        assert_eq!(drained["failed"], 1);
        let status = status(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert_eq!(status["status"], "failed");
        assert!(
            status["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["type"] == "archive.failed"
                    && event["payload"]["deadLetter"] == true)
        );
    }

    #[test]
    fn status_list_events_survive_store_reopen() {
        let (state, home, archive_root) = archive_job_fixture("restart", "Durable restart");
        let created = create(&json!({
            "stateRoot": display_path(&state),
            "homeDir": display_path(&home),
            "agent": "codex",
            "keywords": "Durable restart",
            "path": display_path(&archive_root),
            "curation": "false"
        }))
        .unwrap();
        let job_id = created["jobId"].as_str().unwrap().to_string();
        drop(created);

        let status = status(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert_eq!(status["status"], "queued");
        let list = list(&json!({"stateRoot": display_path(&state)})).unwrap();
        assert_eq!(list["jobs"].as_array().unwrap().len(), 1);
        let events = events(&json!({"stateRoot": display_path(&state), "jobId": job_id})).unwrap();
        assert!(
            events["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["type"] == "archive.job.queued")
        );
    }

    fn archive_job_fixture(name: &str, content: &str) -> (PathBuf, PathBuf, PathBuf) {
        let state = temp_dir(&format!("{}-state", name));
        let home = temp_dir(&format!("{}-home", name));
        let archive_root = temp_dir(&format!("{}-archive", name));
        let history = temp_dir(&format!("{}-history", name));
        fs::write(
            history.join("history.jsonl"),
            format!(
                r#"{{"sessionId":"{}","role":"user","content":"{}"}}"#,
                name, content
            ),
        )
        .unwrap();
        let store = ClientStateStore::new(state.clone()).unwrap();
        store
            .write_collection(
                "targets",
                json!({
                    "items": [{
                        "target": "codex",
                        "manual": true,
                        "historyRoots": [display_path(&history)]
                    }]
                }),
            )
            .unwrap();
        (state, home, archive_root)
    }

    fn corrupt_first_raw_content(archive_root: &Path, folder: &str) {
        let index_path = archive_root.join(folder).join("conversation-index.jsonl");
        let raw = fs::read_to_string(&index_path).unwrap();
        let first = raw.lines().next().unwrap();
        let record: Value = serde_json::from_str(first).unwrap();
        let raw_path = PathBuf::from(record["raw_content_path"].as_str().unwrap());
        fs::write(raw_path, b"{\"corrupt\":true}\n").unwrap();
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!(
            "conversation-archive-jobs-{}-{}",
            name,
            timestamp()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
