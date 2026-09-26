use crate::state_machines::conversation_archive_job;
use anyhow::{Result, anyhow};
use serde_json::Value;

pub(crate) const DEFAULT_MAX_ATTEMPTS: u64 = 2;

#[derive(Clone, Debug)]
pub(crate) struct ArchiveJob {
    pub(crate) job_id: String,
    pub(crate) request: Value,
    pub(crate) target_scan: Value,
    pub(crate) status: String,
    pub(crate) phase: String,
    pub(crate) attempt: u64,
    pub(crate) max_attempts: u64,
    pub(crate) archive_result: Value,
    pub(crate) validation_result: Value,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) retry_after: String,
    pub(crate) last_error: String,
    pub(crate) completed_at: String,
    pub(crate) failed_at: String,
    pub(crate) cancelled_at: String,
}

pub(crate) use crate::state_machines::conversation_archive_job::Event as ArchiveJobEvent;
pub(crate) use crate::state_machines::conversation_archive_job::State as ArchiveJobStatus;

pub(crate) fn parse_archive_job_status(value: &str) -> Result<ArchiveJobStatus> {
    ArchiveJobStatus::from_name(value)
        .ok_or_else(|| anyhow!("unknown archive job status: {}", value))
}

pub(crate) fn advance_archive_job_status(
    current: ArchiveJobStatus,
    event: ArchiveJobEvent,
) -> Result<ArchiveJobStatus> {
    conversation_archive_job::transition(current, event)
        .ok_or_else(|| anyhow!("conversation archive job transition is not declared"))
}

pub(crate) struct RetryPolicy {
    pub(crate) max_attempts: u64,
    base_backoff_seconds: u64,
}

impl RetryPolicy {
    pub(crate) fn new(max_attempts: u64, base_backoff_seconds: u64) -> Self {
        Self {
            max_attempts: max_attempts.clamp(1, 10),
            base_backoff_seconds,
        }
    }

    pub(crate) fn should_retry(&self, attempt: u64, error_kind: &str) -> bool {
        attempt < self.max_attempts
            && matches!(
                error_kind,
                "archive_failed" | "archive_error" | "verification_failed" | "verification_error"
            )
    }

    pub(crate) fn retry_delay_seconds(&self, attempt: u64) -> u64 {
        if self.base_backoff_seconds == 0 {
            return 0;
        }
        let shift = attempt.saturating_sub(1).min(10) as u32;
        let multiplier = 1_u64.checked_shl(shift).unwrap_or(1 << 10);
        self.base_backoff_seconds.saturating_mul(multiplier)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_codec_and_terminal_classification_are_consistent() {
        for status in conversation_archive_job::ALL_STATES {
            assert_eq!(
                ArchiveJobStatus::from_name(status.as_str()).unwrap(),
                status
            );
        }
        assert!(conversation_archive_job::terminal(
            ArchiveJobStatus::Completed
        ));
        assert!(!conversation_archive_job::terminal(
            ArchiveJobStatus::RetryScheduled
        ));
    }

    #[test]
    fn retry_policy_bounds_attempts_and_exponentially_backs_off() {
        let policy = RetryPolicy::new(20, 5);
        assert_eq!(policy.max_attempts, 10);
        assert_eq!(policy.retry_delay_seconds(1), 5);
        assert_eq!(policy.retry_delay_seconds(3), 20);
        assert!(policy.should_retry(3, "verification_failed"));
        assert!(!policy.should_retry(3, "permission_denied"));
    }
}
