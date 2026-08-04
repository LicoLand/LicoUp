use super::super::*;
use std::time::{Duration, Instant};

pub(super) const MAX_CONCURRENT_SENDS: usize = 16;
const SHUTDOWN_GRACE_PERIOD: Duration = Duration::from_secs(1);

pub(super) fn spawn_send<W>(
    writer: Arc<Mutex<W>>,
    request_id: String,
    workflow_id: String,
    params: Value,
    portable_data_dir: Option<PathBuf>,
) -> std::thread::JoinHandle<()>
where
    W: Write + Send + 'static,
{
    std::thread::spawn(move || {
        let _ = execute(
            &writer,
            &request_id,
            &workflow_id,
            "send",
            params,
            portable_data_dir,
            true,
        );
    })
}

pub(super) fn execute<W>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    operation: &str,
    params: Value,
    portable_data_dir: Option<PathBuf>,
    stream_events: bool,
) -> Result<()>
where
    W: Write + Send + 'static,
{
    let sequence = Arc::new(AtomicU64::new(0));
    let event_write_failed = Arc::new(AtomicBool::new(false));
    let stream_guard = stream_events.then(|| {
        let writer = Arc::clone(writer);
        let request_id = request_id.to_owned();
        let workflow_id = workflow_id.to_owned();
        let sequence = Arc::clone(&sequence);
        let event_write_failed = Arc::clone(&event_write_failed);
        licoup_native::platform::install_stream_sink(Box::new(move |event| {
            if event_write_failed.load(Ordering::Acquire) {
                return;
            }
            let next = sequence.load(Ordering::Acquire) + 1;
            if write_stdio_rpc_event(&writer, &request_id, &workflow_id, next, event).is_err() {
                event_write_failed.store(true, Ordering::Release);
            } else {
                sequence.store(next, Ordering::Release);
            }
        }));
        licoup_native::platform::StreamSinkGuard
    });
    let execution = catch_unwind(AssertUnwindSafe(|| {
        let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
        licoup_native::platform::dispatch_lane_operation(operation, &params)
            .map(licoup_native::ffi::commands::CliExecution::Json)
    }));
    drop(stream_guard);
    let terminal_sequence = sequence.fetch_add(1, Ordering::AcqRel) + 1;
    if event_write_failed.load(Ordering::Acquire) {
        write_stdio_rpc_terminal_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            &stdio_rpc_client_error("stream_protocol_failed"),
        )?;
        return Ok(());
    }
    match execution {
        Ok(Ok(licoup_native::ffi::commands::CliExecution::Json(value))) => {
            write_stdio_rpc_terminal_success(
                writer,
                request_id,
                workflow_id,
                terminal_sequence,
                value,
            )
        }
        Ok(Err(error)) => write_stdio_rpc_terminal_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            &error.client_error(),
        ),
        Err(_) => write_stdio_rpc_terminal_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            &stdio_rpc_client_error("command_panicked"),
        ),
        Ok(Ok(_)) => write_stdio_rpc_terminal_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            &stdio_rpc_client_error("command_failed"),
        ),
    }?;
    Ok(())
}

pub(super) fn has_capacity(workers: &[std::thread::JoinHandle<()>]) -> bool {
    workers.len() < MAX_CONCURRENT_SENDS
}

pub(super) fn join_until_shutdown(workers: &mut Vec<std::thread::JoinHandle<()>>) -> bool {
    join_until(workers, SHUTDOWN_GRACE_PERIOD)
}

fn join_until(workers: &mut Vec<std::thread::JoinHandle<()>>, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        reap_finished(workers);
        if workers.is_empty() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

pub(super) fn reap_finished(workers: &mut Vec<std::thread::JoinHandle<()>>) {
    let mut index = 0;
    while index < workers.len() {
        if workers[index].is_finished() {
            let worker = workers.swap_remove(index);
            let _ = worker.join();
        } else {
            index += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_worker_capacity_is_bounded() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let wait = Arc::new(Mutex::new(wait));
        let mut workers = Vec::new();
        for _ in 0..MAX_CONCURRENT_SENDS {
            let wait = Arc::clone(&wait);
            workers.push(std::thread::spawn(move || {
                let _ = wait.lock().unwrap().recv();
            }));
        }

        assert!(!has_capacity(&workers));
        for _ in 0..MAX_CONCURRENT_SENDS {
            release.send(()).unwrap();
        }
        assert!(join_until(&mut workers, Duration::from_secs(1)));
    }

    #[test]
    fn conversation_worker_shutdown_has_a_deadline() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let mut workers = vec![std::thread::spawn(move || {
            let _ = wait.recv();
        })];

        assert!(!join_until(&mut workers, Duration::from_millis(20)));
        release.send(()).unwrap();
        assert!(join_until(&mut workers, Duration::from_secs(1)));
    }
}
