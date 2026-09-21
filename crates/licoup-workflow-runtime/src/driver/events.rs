//! The two channels between effect workers and the drive loop.
//!
//! Results and control are **separate deques with separate bounds**. A backed-up
//! result path cannot consume the room a control request needs, and control
//! capacity cannot be spent by completions; the loop takes control first, for a
//! bounded burst, which is what keeps either side from starving the other. Both
//! are in-process hand-offs, not a durable queue: the durable side is V7-R3's
//! routing.
//!
//! Nothing here calls anything. The queue is a place values wait, never a place
//! callbacks run: the mutex is held for a push or a take and released before the
//! drive loop acts on what it took, so no adapter is invoked and no store is
//! called while it is held. A worker that ends without delivering a verdict is
//! accounted for by the [`WorkerTicket`] it drops on the way out, which is how
//! the loop can tell "still working" from "gone" instead of waiting forever.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use super::control::ControlRequest;
use super::effect::EffectOutcome;
use crate::node::NodeVisitKey;

/// What a worker has to report for one effect.
pub(crate) enum AdapterVerdict {
    /// The adapter returned a verdict.
    Verdict(EffectOutcome),
    /// The adapter itself could not report, with the code and text to record.
    /// The drive records this as an unknown effect position, never as a failure
    /// of the effect: an adapter that could not report has not proved that
    /// anything did or did not happen.
    Unreported {
        code: &'static str,
        detail: Option<String>,
    },
}

/// One completed effect on its way back to the drive loop.
pub(crate) struct Completion {
    pub command_id: String,
    pub attempt_token: String,
    pub node: NodeVisitKey,
    pub verdict: AdapterVerdict,
}

/// Whether the loop was woken or ran out of time.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum WaitOutcome {
    /// There is work, or the drive was closed.
    Work,
    /// Nothing arrived in time. The caller renews its leases.
    TimedOut,
}

/// One step of the result path, read as a single fact.
pub(crate) enum Arrival {
    /// A verdict is waiting.
    Completion(Box<Completion>),
    /// Nothing is waiting and no effect is still running.
    Ended,
    /// Nothing is waiting, but effects are still running.
    Waiting,
}

struct Queues {
    control: VecDeque<ControlRequest>,
    results: VecDeque<Completion>,
    workers: usize,
    result_bound: usize,
    control_bound: usize,
    closed: bool,
}

/// The channels one drive owns.
pub(crate) struct RunEvents {
    inner: Mutex<Queues>,
    wake: Condvar,
}

impl RunEvents {
    /// The result bound is the in-flight bound, safely.
    ///
    /// At most one completion exists per in-flight effect, and the drive admits
    /// no more than `result_bound` effects, so a result can only be refused when
    /// the queue is full and the driver has stopped draining — which is why
    /// `push_result` may wait at all, and why it can always be released by
    /// closing the drive.
    pub(crate) fn new(result_bound: usize, control_bound: usize) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(Queues {
                control: VecDeque::new(),
                results: VecDeque::new(),
                workers: 0,
                result_bound: result_bound.max(1),
                control_bound: control_bound.max(1),
                closed: false,
            }),
            wake: Condvar::new(),
        })
    }

    /// Queue a control request. Refused, with the request handed back, when the
    /// control bound is reached: a refused control is visible to its caller,
    /// which is the opposite of a dropped one.
    pub(crate) fn push_control(&self, request: ControlRequest) -> Result<(), ControlRequest> {
        let mut queues = self.lock();
        if queues.closed || queues.control.len() >= queues.control_bound {
            return Err(request);
        }
        queues.control.push_back(request);
        drop(queues);
        self.wake.notify_all();
        Ok(())
    }

    /// Take the oldest control request, if one is waiting.
    pub(crate) fn take_control(&self) -> Option<ControlRequest> {
        let mut queues = self.lock();
        let request = queues.control.pop_front();
        if request.is_some() {
            // A worker may be waiting for room in the result deque.
            self.wake.notify_all();
        }
        request
    }

    /// Queue one completion, waiting for room if the result path is saturated.
    ///
    /// The wait ends when the drive closes, in which case the completion is
    /// dropped: the drive that would have committed it is gone, and the durable
    /// possible-effect marker is the fact recovery reads. That is a deliberate
    /// choice of in-doubt over a silent "the effect never happened".
    pub(crate) fn push_result(&self, completion: Completion) {
        let deadline = Instant::now() + RESULT_WAIT;
        let mut queues = self.lock();
        while queues.results.len() >= queues.result_bound && !queues.closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let (guard, _) = self
                .wake
                .wait_timeout(queues, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            queues = guard;
        }
        if !queues.closed {
            queues.results.push_back(completion);
        }
        drop(queues);
        self.wake.notify_all();
    }

    /// Take one completion, or find out that every admitted effect has ended.
    ///
    /// Both facts are read under one lock, and that is the point: "no completion
    /// is waiting" and "no worker is running" must not be two separate
    /// observations. Taken separately, a worker that pushed and then exited
    /// between them would have its completion reported as an effect that never
    /// reported — and the loop would settle a command whose verdict was already
    /// on its way.
    pub(crate) fn take_completion(&self) -> Arrival {
        let mut queues = self.lock();
        if let Some(completion) = queues.results.pop_front() {
            self.wake.notify_all();
            return Arrival::Completion(Box::new(completion));
        }
        if queues.workers == 0 && !queues.closed {
            Arrival::Ended
        } else {
            Arrival::Waiting
        }
    }

    pub(crate) fn result_depth(&self) -> usize {
        self.lock().results.len()
    }

    pub(crate) fn control_depth(&self) -> usize {
        self.lock().control.len()
    }

    /// Wait for work, a worker ending, or the drive closing.
    pub(crate) fn wait(&self, timeout: Duration) -> WaitOutcome {
        let deadline = Instant::now() + timeout;
        let mut queues = self.lock();
        loop {
            if !queues.control.is_empty()
                || !queues.results.is_empty()
                || queues.closed
                || queues.workers == 0
            {
                return WaitOutcome::Work;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return WaitOutcome::TimedOut;
            }
            let (guard, _) = self
                .wake
                .wait_timeout(queues, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            queues = guard;
        }
    }

    /// Release anything waiting on this drive.
    pub(crate) fn close(&self) {
        self.lock().closed = true;
        self.wake.notify_all();
    }

    fn worker_started(&self) {
        let mut queues = self.lock();
        queues.workers = queues.workers.saturating_add(1);
    }

    fn worker_finished(&self) {
        let mut queues = self.lock();
        queues.workers = queues.workers.saturating_sub(1);
        drop(queues);
        self.wake.notify_all();
    }

    /// Poisoning is absorbed: the queues are plain values, and a panicking
    /// worker must not be able to make the drive unable to end.
    fn lock(&self) -> MutexGuard<'_, Queues> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Longest a worker waits for room on a saturated result path.
const RESULT_WAIT: Duration = Duration::from_secs(5);

/// One effect thread's claim on the queue's worker count.
///
/// Created before the thread starts and moved into it, so it is dropped exactly
/// once: on normal return, on a panic unwinding the thread, or on a failed
/// spawn. A count of zero therefore means every admitted effect has stopped,
/// which is the fact the loop uses to settle effects that will never report.
pub(crate) struct WorkerTicket {
    events: Arc<RunEvents>,
}

impl WorkerTicket {
    pub(crate) fn new(events: &Arc<RunEvents>) -> Self {
        events.worker_started();
        Self {
            events: Arc::clone(events),
        }
    }
}

impl Drop for WorkerTicket {
    fn drop(&mut self) {
        self.events.worker_finished();
    }
}
