//! What the single SQLite writer does, and does not, promise to several graphs.
//!
//! The guarantee these tests hold the store to is exactly this: writes are
//! admitted first-come-first-served by ticket, so a graph asking for writes in
//! a loop cannot starve a graph asking for one, and the writer is held only for
//! a short transaction — never across the compilation that produces one.
//!
//! They deliberately do **not** claim:
//!
//! - per-graph parallel database writes. There is one writer and every write in
//!   this suite goes through it;
//! - per-graph round-robin turns. Arrival order is the fairness here: a graph
//!   that asks for ten commits first gets ten turns first;
//! - any ordering between handles that share the file. Two `WorkflowDatabase`
//!   instances, in one process or in several, are serialized by SQLite's own
//!   lock, whose order this crate neither sees nor states. The FIFO order below
//!   is the order of writers waiting on one handle.

use licoup_workflow::ReducerEvent;
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::WorkflowDatabase;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::support;

#[test]
fn waiting_writers_are_admitted_in_arrival_order() {
    let path = support::scratch_path("fifo");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    let admitted: Arc<Mutex<Vec<&'static str>>> = Arc::new(Mutex::new(Vec::new()));
    let held = Arc::new(AtomicBool::new(false));
    let release = Arc::new(AtomicBool::new(false));

    // A first writer holds the gate open while the other two arrive, so their
    // arrival order is known rather than raced for.
    let holder = {
        let database = database.clone();
        let held = held.clone();
        let release = release.clone();
        std::thread::spawn(move || {
            database
                .write(|_, _| {
                    held.store(true, Ordering::SeqCst);
                    while !release.load(Ordering::SeqCst) {
                        std::hint::spin_loop();
                    }
                    Ok(())
                })
                .expect("the holding write runs");
        })
    };
    while !held.load(Ordering::SeqCst) {
        std::hint::spin_loop();
    }

    let mut staged = Vec::new();
    for (index, label) in ["graph-b", "graph-c"].into_iter().enumerate() {
        let writer = database.clone();
        let admitted = admitted.clone();
        staged.push(std::thread::spawn(move || {
            writer
                .write(|_, _| {
                    admitted
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .push(label);
                    Ok(())
                })
                .expect("the staged write runs");
        }));
        let expected = 2 + index as u64;
        while database.tickets_taken() < expected {
            std::hint::spin_loop();
        }
    }
    release.store(true, Ordering::SeqCst);

    holder.join().expect("the holding write finishes");
    for writer in staged {
        writer.join().expect("every staged writer finishes");
    }
    assert_eq!(
        *admitted
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner),
        ["graph-b", "graph-c"],
        "a writer that took its ticket first is admitted first"
    );
    support::remove_database(&path);
}

#[test]
fn every_graph_finishes_under_contention_and_no_write_is_lost() {
    const GRAPHS: usize = 6;
    const RUNS_PER_GRAPH: usize = 4;

    let path = support::scratch_path("contention");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    support::seed_definition(
        &database,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(2),
    )
    .expect("definition seeds");

    let mut workers = Vec::new();
    for index in 0..GRAPHS {
        let database = database.clone();
        workers.push(std::thread::spawn(move || {
            let mut sequences = Vec::new();
            for run in 0..RUNS_PER_GRAPH {
                let label = format!("run-{index}-{run}");
                let port = support::graph(&database, &label).expect("the run starts");
                let sequence = port.checkpoint(&label).expect("checkpoint reads").sequence;
                sequences.push(
                    port.commit(&label, sequence, ReducerEvent::CancelRequested)
                        .expect("every commit is admitted")
                        .sequence,
                );
            }
            sequences
        }));
    }
    let mut committed = 0usize;
    for worker in workers {
        let sequences = worker.join().expect("every graph finishes");
        assert_eq!(sequences, vec![2; RUNS_PER_GRAPH]);
        committed += sequences.len();
    }
    let expected = (GRAPHS * RUNS_PER_GRAPH) as i64;
    assert_eq!(committed as i64, expected);
    assert_eq!(
        support::count(&database, "strategy_run_events", "1=1"),
        2 * expected,
        "each run kept its start event and its commit, and lost neither"
    );
    assert_eq!(
        support::count(&database, "strategy_runs", "terminal=1"),
        expected,
        "every committed run reached its terminal state"
    );
    drop(database);
    support::remove_database(&path);
}

#[test]
fn a_graph_that_is_still_computing_does_not_hold_the_writer() {
    // The reason a reduction is computed outside the gate: a caller between its
    // checkpoint read and its commit holds nothing, so another graph's commit
    // is not waiting behind it. Staged with handshakes rather than sleeps, so
    // what is asserted here is not a timing accident.
    let path = support::scratch_path("computing");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    support::seed_definition(
        &database,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(2),
    )
    .expect("definition seeds");

    let computing = Arc::new(AtomicBool::new(false));
    let committed_while_computing = Arc::new(AtomicBool::new(false));

    let slow = {
        let database = database.clone();
        let computing = computing.clone();
        let committed_while_computing = committed_while_computing.clone();
        std::thread::spawn(move || {
            let port = support::graph(&database, "run-slow").expect("the run starts");
            let sequence = port
                .checkpoint("run-slow")
                .expect("checkpoint reads")
                .sequence;
            // Stands in for compiling and reducing: work deliberately outside
            // any write transaction.
            computing.store(true, Ordering::SeqCst);
            while !committed_while_computing.load(Ordering::SeqCst) {
                std::hint::spin_loop();
            }
            port.commit("run-slow", sequence, ReducerEvent::CancelRequested)
                .expect("the slow graph commits once it is done computing")
                .sequence
        })
    };

    let fast = {
        let database = database.clone();
        let computing = computing.clone();
        let committed_while_computing = committed_while_computing.clone();
        std::thread::spawn(move || {
            while !computing.load(Ordering::SeqCst) {
                std::hint::spin_loop();
            }
            let port = support::graph(&database, "run-fast").expect("the run starts");
            let sequence = port
                .checkpoint("run-fast")
                .expect("checkpoint reads")
                .sequence;
            let advanced = port
                .commit("run-fast", sequence, ReducerEvent::CancelRequested)
                .expect("the fast graph commits while the other is computing")
                .sequence;
            committed_while_computing.store(true, Ordering::SeqCst);
            advanced
        })
    };

    assert_eq!(slow.join().expect("the computing graph finishes"), 2);
    assert_eq!(fast.join().expect("the fast graph finishes"), 2);
    assert!(committed_while_computing.load(Ordering::SeqCst));
    drop(database);
    support::remove_database(&path);
}

#[test]
fn a_claim_with_nothing_left_to_take_is_an_answer_not_an_error() {
    let path = support::scratch_path("nothing-dispatchable");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    support::seed_definition(
        &database,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(1),
    )
    .expect("definition seeds");
    let port = support::graph(&database, "run-one").expect("the run starts");

    let first = port
        .claim_next("run-one", "host-1", support::future_ms())
        .expect("claim runs");
    assert!(
        first.is_some(),
        "the started run holds one dispatchable command"
    );
    let second = port
        .claim_next("run-one", "host-2", support::future_ms())
        .expect("a claim with nothing to take is not an error");
    assert!(second.is_none());
    drop(database);
    support::remove_database(&path);
}

#[test]
fn a_second_handle_on_the_same_file_does_not_lose_a_short_write() {
    // The case the FIFO order above deliberately does not cover: the gate is
    // per handle, so two handles on one file wait on SQLite's own lock. What
    // must still hold is that a short write is not lost to a busy database —
    // the connection's busy timeout covers the wait, and every commit that
    // returned success is in the file when both handles are done.
    const RUNS_PER_HANDLE: usize = 8;

    let path = support::scratch_path("two-handles");
    let first = Arc::new(WorkflowDatabase::open(&path).expect("first handle"));
    support::seed_definition(
        &first,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(2),
    )
    .expect("definition seeds");
    let second = Arc::new(WorkflowDatabase::open(&path).expect("second handle on the same file"));

    let mut writers = Vec::new();
    for (handle, label) in [(first.clone(), "handle-a"), (second.clone(), "handle-b")] {
        writers.push(std::thread::spawn(move || {
            let mut sequences = Vec::with_capacity(RUNS_PER_HANDLE);
            for run in 0..RUNS_PER_HANDLE {
                let name = format!("{label}-run-{run}");
                let port = support::graph(&handle, &name).expect("the run starts");
                let sequence = port.checkpoint(&name).expect("checkpoint reads").sequence;
                sequences.push(
                    port.commit(&name, sequence, ReducerEvent::CancelRequested)
                        .expect("a short write waits for the lock instead of failing as busy")
                        .sequence,
                );
            }
            sequences
        }));
    }

    let mut committed = 0usize;
    for writer in writers {
        let sequences = writer.join().expect("both handles finish");
        assert_eq!(sequences, vec![2; RUNS_PER_HANDLE]);
        committed += sequences.len();
    }
    assert_eq!(
        support::count(&first, "strategy_run_events", "1=1"),
        2 * committed as i64,
        "every run kept its start event and its commit, across both handles"
    );
    assert_eq!(
        support::count(&first, "strategy_runs", "terminal=1"),
        committed as i64,
        "every committed run reached its terminal state"
    );
    drop(second);
    drop(first);
    support::remove_database(&path);
}
