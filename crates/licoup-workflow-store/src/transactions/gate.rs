//! Fair admission to the single SQLite writer.
//!
//! ## The guarantee, stated exactly
//!
//! One SQLite database has one writer at a time. The plan does not promise
//! per-graph parallel database writes and neither does this type: every write
//! in this crate is serialized through one gate.
//!
//! What the gate adds over "whatever the OS lock does" is a *stated order*:
//! waiting is first-come-first-served by ticket. A caller that has taken a
//! ticket is admitted before every caller that takes one afterwards, so no
//! graph can starve another by asking more often. That is the arrival-order
//! guarantee and it is the one the tests hold this type to.
//!
//! It is deliberately **not**:
//!
//! - per-graph round-robin, which would give every graph equal turns; a graph
//!   that asks for ten commits gets ten turns here, ahead of a graph that asks
//!   for one, as long as it asked first;
//! - parallel per-graph writes, which one SQLite database does not offer;
//! - fairness across processes. A second process writing the same file is
//!   serialized by SQLite's own lock, whose order this gate cannot see and does
//!   not claim.
//!
//! ## Shape
//!
//! A ticket lock: `queue.next_ticket` is handed out on arrival, `queue
//! .now_serving` is the ticket whose turn it is, and a waiter blocks on a
//! condition variable until the two agree. Waiting is O(1) and allocation-free
//! per call, and admission is O(1).
//!
//! The resource behind the gate is a second mutex, and the ticket holder is
//! always its only possible contender because only the current ticket may reach
//! it. [`WriteTicket::drop`] therefore releases the resource *before* admitting
//! the next ticket: a waiter that takes over never blocks on the guard of the
//! caller it replaced.

use std::ops::{Deref, DerefMut};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};

/// Tickets issued and the ticket currently being served.
#[derive(Debug, Default)]
struct Queue {
    next_ticket: u64,
    now_serving: u64,
}

/// A first-come-first-served gate in front of `T`.
#[derive(Debug)]
pub struct FairWriteGate<T> {
    queue: Mutex<Queue>,
    ready: Condvar,
    resource: Mutex<T>,
}

impl<T> FairWriteGate<T> {
    pub fn new(resource: T) -> Self {
        Self {
            queue: Mutex::new(Queue::default()),
            ready: Condvar::new(),
            resource: Mutex::new(resource),
        }
    }

    /// Take a ticket and wait until it is this caller's turn.
    pub fn enter(&self) -> WriteTicket<'_, T> {
        let ticket = {
            // A panic while holding the gate leaves the database in whatever
            // state the unwinding statement left it — SQLite rolls the
            // transaction back — and must not wedge every later caller.
            let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
            let ticket = queue.next_ticket;
            queue.next_ticket = queue.next_ticket.wrapping_add(1);
            while queue.now_serving != ticket {
                queue = self
                    .ready
                    .wait(queue)
                    .unwrap_or_else(PoisonError::into_inner);
            }
            ticket
        };
        WriteTicket {
            gate: self,
            ticket,
            resource: Some(self.resource.lock().unwrap_or_else(PoisonError::into_inner)),
        }
    }

    /// Tickets handed out so far, including the one being served. Telemetry for
    /// admission wait, and the hook that lets a test stage callers in a known
    /// order instead of racing for one.
    pub fn tickets_taken(&self) -> u64 {
        self.queue
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .next_ticket
    }

    fn release(&self, ticket: u64) {
        let mut queue = self.queue.lock().unwrap_or_else(PoisonError::into_inner);
        queue.now_serving = ticket.wrapping_add(1);
        self.ready.notify_all();
    }
}

/// Exclusive access to the gated resource, released on drop.
#[derive(Debug)]
pub struct WriteTicket<'a, T> {
    gate: &'a FairWriteGate<T>,
    ticket: u64,
    /// `None` only while this ticket is being dropped, which no other caller can
    /// observe because the ticket owns the resource until then.
    resource: Option<MutexGuard<'a, T>>,
}

impl<T> Deref for WriteTicket<'_, T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.resource
            .as_deref()
            .expect("a live ticket always holds its resource")
    }
}

impl<T> DerefMut for WriteTicket<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        self.resource
            .as_deref_mut()
            .expect("a live ticket always holds its resource")
    }
}

impl<T> Drop for WriteTicket<'_, T> {
    fn drop(&mut self) {
        self.resource.take();
        self.gate.release(self.ticket);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Stage one waiter, wait until its ticket exists, and record when it runs.
    fn waiter(
        gate: &Arc<FairWriteGate<u64>>,
        log: &Arc<Mutex<Vec<&'static str>>>,
        label: &'static str,
    ) -> std::thread::JoinHandle<()> {
        let gate = gate.clone();
        let log = log.clone();
        std::thread::spawn(move || {
            let ticket = gate.enter();
            log.lock()
                .unwrap_or_else(PoisonError::into_inner)
                .push(label);
            drop(ticket);
        })
    }

    #[test]
    fn a_waiter_takes_its_turn_in_arrival_order() {
        let gate = Arc::new(FairWriteGate::new(0u64));
        let log = Arc::new(Mutex::new(Vec::new()));
        let held = gate.enter();

        let second = waiter(&gate, &log, "second");
        while gate.tickets_taken() < 2 {
            std::hint::spin_loop();
        }
        let third = waiter(&gate, &log, "third");
        while gate.tickets_taken() < 3 {
            std::hint::spin_loop();
        }

        // Neither waiter can have run: the main test holds the gate, so the
        // order they run in is decided by the tickets they already hold.
        assert!(log.lock().unwrap().is_empty());
        drop(held);
        second.join().unwrap();
        third.join().unwrap();
        assert_eq!(*log.lock().unwrap(), ["second", "third"]);
    }

    #[test]
    fn every_contender_finishes_under_contention() {
        let gate = Arc::new(FairWriteGate::new(0u64));
        let mut workers = Vec::new();
        for _ in 0..8 {
            let gate = gate.clone();
            workers.push(std::thread::spawn(move || {
                for _ in 0..64 {
                    *gate.enter() += 1;
                }
            }));
        }
        for worker in workers {
            worker.join().unwrap();
        }
        // Every increment landed: no caller was refused a turn, and no update
        // was lost to a second writer.
        assert_eq!(*gate.enter(), 8 * 64);
    }
}
