//! Bounded client persistence types.
//!
//! `ClientResourcePolicy` is the single configuration surface for history pages,
//! parser buffers, search results, archive workers, spools, log segments, state
//! quotas, and maintenance batches. Behavior is filled by a later node; this
//! crate only publishes the bound types.

mod resource_policy;

pub use resource_policy::{ClientResourceBounds, ClientResourcePolicy};

#[cfg(test)]
mod tests {
    use super::ClientResourcePolicy;

    #[test]
    fn standard_policy_exposes_fixed_positive_bounds() {
        let policy = ClientResourcePolicy::standard();
        let bounds = policy.bounds();
        assert!(bounds.history_page_size > 0);
        assert!(bounds.parser_buffer_bytes > 0);
        assert!(bounds.search_result_limit > 0);
        assert_eq!(bounds.archive_worker_count, 1);
        assert!(bounds.spool_queue_bytes > 0);
        assert!(bounds.spool_queue_events > 0);
        assert!(bounds.log_segment_bytes > 0);
        assert!(bounds.state_quota_bytes > 0);
        assert!(bounds.maintenance_batch_size > 0);
    }

    #[test]
    fn callers_cannot_construct_unbounded_policy() {
        let policy = ClientResourcePolicy::standard();
        assert!(!policy.allows_unbounded_collections());
    }
}
