//! Client-local owner for desktop Agent conversation RPC.
//!
//! The Flutter process owns a replaceable stdio proxy. The listener and every
//! accepted Agent turn live in this CLI host, scoped to the client-owned
//! portable data root. The host belongs to that LicoUp process: when the
//! client pid in `LICOUP_CLIENT_PID` is gone, the host exits on its next
//! bounded owner check, including in-flight turns. A five-minute idle exit
//! applies only when that owner pid is unset (CLI and tests).

use anyhow::{Context, Result, anyhow};
use interprocess::local_socket::{
    ListenerNonblockingMode, ListenerOptions, SendHalf, Stream, traits::Stream as _,
};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

use super::stdio_rpc::{
    PersistentConversationRuntime, execute_rpc_cli, serve_stdio_rpc_with_persistent_conversation,
};

const CONNECT_ATTEMPTS: usize = 80;
const CONNECT_RETRY: Duration = Duration::from_millis(25);
const STALE_HOST_WAIT: Duration = Duration::from_secs(2);
const OWNER_CHECK_INTERVAL: Duration = Duration::from_millis(500);
const IDLE_EXIT_GRACE: Duration = Duration::from_secs(300);
const CLIENT_PID_ENV: &str = "LICOUP_CLIENT_PID";

fn host_generation_path(root: &Path) -> PathBuf {
    root.join("client-state")
        .join("conversation-runtime")
        .join("host-generation")
}

fn executable_generation() -> io::Result<String> {
    licoup_native::platform::conversation_host_transport::executable_generation()
}

fn valid_host_generation(value: &str) -> bool {
    value.len() == 16 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn parse_host_generation_record(text: &str) -> Option<(String, Option<u32>, Option<u32>)> {
    let mut lines = text.lines();
    let identity = lines.next()?.trim();
    if !valid_host_generation(identity) {
        return None;
    }
    let host_pid = match lines.next().map(str::trim).filter(|line| !line.is_empty()) {
        None => None,
        Some(line) => Some(line.parse().ok()?),
    };
    let client_pid = match lines.next().map(str::trim) {
        None => None,
        Some("") => None,
        Some(line) => Some(parse_client_pid(line)?),
    };
    if lines.next().is_some() {
        return None;
    }
    Some((identity.to_owned(), host_pid, client_pid))
}

fn read_host_generation_record() -> Option<(String, Option<u32>, Option<u32>)> {
    let root = licoup_native::platform::paths::portable_data_dir().ok()?;
    let text = fs::read_to_string(host_generation_path(&root)).ok()?;
    parse_host_generation_record(&text)
}

fn write_host_generation() -> Result<()> {
    let root = licoup_native::platform::paths::portable_data_dir()?;
    let path = host_generation_path(&root);
    if let Some(parent) = path.parent() {
        licoup_native::platform::file_security::ensure_private_dir(parent)?;
    }
    let generation = executable_generation().context("conversation host unavailable")?;
    let mut body = format!("{generation}\n{}\n", std::process::id());
    if let Some(client_pid) = configured_client_pid() {
        body.push_str(&format!("{client_pid}\n"));
    }
    let mut file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&path)
        .context("conversation host unavailable")?;
    file.write_all(body.as_bytes())?;
    file.sync_all()?;
    licoup_native::platform::file_security::harden_private_path(&path)?;
    Ok(())
}

fn host_is_current() -> bool {
    let Ok(generation) = executable_generation() else {
        return false;
    };
    let Some((recorded, Some(host_pid), recorded_client)) = read_host_generation_record() else {
        return false;
    };
    if recorded != generation || process_liveness(host_pid) == ProcessLiveness::Dead {
        return false;
    }
    match configured_client_pid() {
        None => true,
        Some(expected) => recorded_client == Some(expected),
    }
}

fn endpoint_accepts_connections() -> bool {
    licoup_native::platform::conversation_host_transport::connect().is_ok()
}

fn wait_for_current_or_released_endpoint() -> Option<Stream> {
    let deadline = Instant::now() + STALE_HOST_WAIT;
    while Instant::now() < deadline {
        if host_is_current()
            && let Ok(stream) = licoup_native::platform::conversation_host_transport::connect()
        {
            return Some(stream);
        }
        if !endpoint_accepts_connections() {
            return None;
        }
        thread::sleep(CONNECT_RETRY);
    }
    None
}

fn connect_or_start() -> Result<Stream> {
    if host_is_current() {
        if let Ok(stream) = licoup_native::platform::conversation_host_transport::connect() {
            return Ok(stream);
        }
    } else if endpoint_accepts_connections() {
        if let Some(stream) = wait_for_current_or_released_endpoint() {
            return Ok(stream);
        }
        if endpoint_accepts_connections() {
            // Never kill by an untrusted or stale PID record. A live endpoint
            // owned by another client or binary fails closed instead.
            return Err(anyhow!("conversation host unavailable"));
        }
    }
    spawn_host()?;
    for _ in 0..CONNECT_ATTEMPTS {
        if host_is_current() {
            if let Ok(stream) = licoup_native::platform::conversation_host_transport::connect() {
                return Ok(stream);
            }
        }
        thread::sleep(CONNECT_RETRY);
    }
    Err(anyhow!("conversation host unavailable"))
}

fn parse_client_pid(value: &str) -> Option<u32> {
    let value = value.trim();
    if value.is_empty() || value.len() > 10 || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let pid = value.parse().ok()?;
    (pid > 1).then_some(pid)
}

fn configured_client_pid() -> Option<u32> {
    parse_client_pid(&env::var(CLIENT_PID_ENV).ok()?)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProcessLiveness {
    Alive,
    Dead,
    Unknown,
}

fn process_liveness(pid: u32) -> ProcessLiveness {
    if pid <= 1 {
        return ProcessLiveness::Dead;
    }
    #[cfg(unix)]
    {
        use nix::sys::signal::kill;
        use nix::unistd::Pid;

        let raw = i32::try_from(pid).unwrap_or(0);
        if raw <= 1 {
            return ProcessLiveness::Dead;
        }
        match kill(Pid::from_raw(raw), None) {
            Ok(()) | Err(nix::errno::Errno::EPERM) => ProcessLiveness::Alive,
            Err(nix::errno::Errno::ESRCH) => ProcessLiveness::Dead,
            Err(_) => ProcessLiveness::Unknown,
        }
    }
    #[cfg(windows)]
    {
        windows_process_liveness(pid)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = pid;
        ProcessLiveness::Unknown
    }
}

#[cfg(windows)]
fn windows_process_liveness(pid: u32) -> ProcessLiveness {
    let filter = format!("PID eq {pid}");
    let output = Command::new("tasklist")
        .args(["/FI", &filter, "/FO", "CSV", "/NH"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    let Ok(output) = output else {
        return ProcessLiveness::Unknown;
    };
    if !output.status.success() {
        return ProcessLiveness::Unknown;
    }
    let Ok(stdout) = String::from_utf8(output.stdout) else {
        return ProcessLiveness::Unknown;
    };
    let expected = pid.to_string();
    if stdout.lines().any(|line| {
        line.split("\",\"")
            .nth(1)
            .map(|value| value.trim_matches('"'))
            == Some(expected.as_str())
    }) {
        ProcessLiveness::Alive
    } else {
        ProcessLiveness::Dead
    }
}

fn client_owner_is_gone() -> bool {
    configured_client_pid().is_some_and(|pid| process_liveness(pid) == ProcessLiveness::Dead)
}

/// Desktop startup ownership: every `rpc stdio` bridge lane launched by the
/// desktop client (marked by LICOUP_CLIENT_PID) ensures the persistent
/// conversation host — and with it the supervised Subagent MCP service — is
/// running before any conversation RPC. A spawn failure only degrades MCP
/// readiness; the bridge lane is never affected.
pub(super) fn ensure_host_for_desktop_start() {
    if configured_client_pid().is_none() {
        return;
    }
    if host_is_current() && endpoint_accepts_connections() {
        return;
    }
    let _ = spawn_host();
}

fn spawn_host() -> Result<()> {
    let executable = env::current_exe().context("conversation host executable unavailable")?;
    let mut command = Command::new(executable);
    command
        .args(["rpc", "conversation-host"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(client_pid) = configured_client_pid() {
        command.env(CLIENT_PID_ENV, client_pid.to_string());
    }
    command
        .spawn()
        .map(|_| ())
        .context("conversation host start failed")
}

pub(super) fn serve_proxy() -> Result<()> {
    let stream = connect_or_start()?;
    let (mut receiver, mut sender) = stream.split();
    // Continue draining the host after stdout disappears. This prevents a
    // closed GUI pipe from applying backpressure to the turn owner.
    let upload = thread::spawn(move || -> io::Result<()> {
        io::copy(&mut io::stdin().lock(), &mut sender)?;
        sender.flush()?;
        shutdown_upload(&sender)
    });
    let mut stdout = io::stdout().lock();
    let mut buffer = [0_u8; 16 * 1024];
    let mut observable = true;
    loop {
        let count = receiver.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        if observable && stdout.write_all(&buffer[..count]).is_err() {
            observable = false;
        }
        if observable {
            let _ = stdout.flush();
        }
    }
    // Host EOF must close this proxy's stdout immediately so the desktop can
    // reconnect. Joining would wait forever while the upload thread is still
    // blocked on an open GUI stdin pipe; dropping the handle lets process exit
    // terminate that replaceable proxy thread.
    drop(upload);
    Ok(())
}

#[cfg(unix)]
fn shutdown_upload(sender: &SendHalf) -> io::Result<()> {
    use std::net::Shutdown;

    match sender {
        SendHalf::UdSocket(sender) => sender.as_stream().inner().shutdown(Shutdown::Write),
        #[allow(unreachable_patterns)]
        _ => Ok(()),
    }
}

#[cfg(windows)]
fn shutdown_upload(_sender: &SendHalf) -> io::Result<()> {
    // The named-pipe send half is independently owned and signals completion
    // when the upload thread returns and drops it.
    Ok(())
}

pub(super) fn serve_host() -> Result<()> {
    let name = licoup_native::platform::conversation_host_transport::endpoint_name()?;
    let listener = match ListenerOptions::new()
        .name(name)
        .nonblocking(ListenerNonblockingMode::Accept)
        .try_overwrite(false)
        .create_sync()
    {
        Ok(listener) => listener,
        Err(error) if error.kind() == io::ErrorKind::AddrInUse => {
            if host_is_current() {
                return Ok(());
            }
            if endpoint_accepts_connections() {
                return Err(error).context("conversation host listener already active");
            }
            ListenerOptions::new()
                .name(licoup_native::platform::conversation_host_transport::endpoint_name()?)
                .nonblocking(ListenerNonblockingMode::Accept)
                .try_overwrite(true)
                .create_sync()
                .context("conversation host listener failed")?
        }
        Err(error) => return Err(error).context("conversation host listener failed"),
    };
    write_host_generation()?;
    let root = licoup_native::platform::paths::portable_data_dir()?;
    // The persistent Conversation host and Gateway must admit the same
    // evidence-bound adapters. The Gateway persists hot reloads in this
    // standard overlay; load it before any runtime profile is resolved so a
    // restarted host cannot fall back to the packaged readiness snapshot.
    let readiness_overlay = root
        .join("llm-gateway")
        .join(licoup_native::platform::llm_gateway_inventory_control::OVERLAY_FILE_NAME);
    let _ =
        licoup_native::platform::llm_gateway_inventory_control::load_inventory_overlay_if_present(
            &readiness_overlay,
        );
    let service = licoup_native::domain::client_conversation::ConversationService::open(&root)?;
    let runtime = PersistentConversationRuntime::new(service.store().clone());
    let service = super::stdio_rpc::bind_conversation_runtime(service, &runtime, None);
    {
        let hooked = service.clone();
        runtime.set_settlement_hook(move |conversation_id, payload| {
            hooked
                .after_runtime_settlement(conversation_id, payload)
                .map(|_| ())
                .map_err(|err| err.to_string())
        });
    }
    // The Subagent MCP service is a supervised child: a start failure or an
    // unexpected exit degrades MCP readiness through the monitor instead of
    // crashing the unrelated Conversation host behavior.
    let _subagent_mcp =
        licoup_native::platform::subagent_mcp_supervisor::SubagentMcpService::start();
    serve_bound_host(listener, service, runtime, None)
}

/// One serialized in-process owner for `attend_due`. The accept loop never
/// runs cognition and never joins this worker. Host owner exit signals the
/// loop and returns immediately so a held cognition cannot pin the listener.
struct AttendanceOwner {
    stop: Arc<AtomicBool>,
    active: Arc<AtomicBool>,
    wake: Arc<(Mutex<()>, Condvar)>,
    join: Option<thread::JoinHandle<()>>,
}

impl AttendanceOwner {
    fn spawn(
        service: licoup_native::domain::client_conversation::ConversationService,
    ) -> Result<Self> {
        let stop = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicBool::new(false));
        let wake = Arc::new((Mutex::new(()), Condvar::new()));
        let stop_w = stop.clone();
        let active_w = active.clone();
        let wake_w = wake.clone();
        let join = thread::Builder::new()
            .name("conversation-attend".to_owned())
            .spawn(move || {
                // Claim/cold-recover may enter cognition. Mark attendance
                // active first so generic idle cannot treat that work as idle.
                active_w.store(true, Ordering::Release);
                let _ = service.claim_continuity_owner();
                while !stop_w.load(Ordering::Acquire) {
                    active_w.store(true, Ordering::Release);
                    let _ = service.attend_due();
                    active_w.store(false, Ordering::Release);
                    if stop_w.load(Ordering::Acquire) {
                        break;
                    }
                    let (lock, cv) = &*wake_w;
                    let guard = lock.lock().unwrap_or_else(|poison| poison.into_inner());
                    let _ = cv.wait_timeout(guard, CONNECT_RETRY);
                }
            })
            .context("conversation attendance worker failed")?;
        Ok(Self {
            stop,
            active,
            wake,
            join: Some(join),
        })
    }

    fn active(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    fn shutdown(self) {
        self.stop.store(true, Ordering::Release);
        self.wake.1.notify_all();
        // Detach: configured host-owner exit must release the listener
        // without waiting for an in-flight cognition call.
        drop(self.join);
    }
}

fn generic_idle_may_exit(runtime_idle: bool, attendance_active: bool) -> bool {
    runtime_idle && !attendance_active
}

fn serve_bound_host(
    listener: impl interprocess::local_socket::traits::Listener<Stream = Stream>,
    service: licoup_native::domain::client_conversation::ConversationService,
    runtime: PersistentConversationRuntime,
    stop: Option<Arc<AtomicBool>>,
) -> Result<()> {
    let attendance = AttendanceOwner::spawn(service.clone())?;
    let mut idle_since = None;
    let mut next_owner_check = Instant::now();
    let result = loop {
        if stop
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::Acquire))
        {
            break Ok(());
        }
        match listener.accept() {
            Ok(stream) => {
                // macOS may propagate O_NONBLOCK from the listener despite
                // ListenerNonblockingMode::Accept. Each accepted RPC session
                // is served by its own thread and must block between frames.
                if stream.set_nonblocking(false).is_err() {
                    continue;
                }
                idle_since = None;
                runtime.client_connected();
                let runtime = runtime.clone();
                let conversation_service = service.clone();
                thread::spawn(move || {
                    let (receiver, sender) = stream.split();
                    let _ = serve_stdio_rpc_with_persistent_conversation(
                        BufReader::new(receiver),
                        sender,
                        execute_rpc_cli,
                        runtime.clone(),
                        conversation_service,
                    );
                    runtime.client_disconnected();
                });
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if configured_client_pid().is_some() && Instant::now() >= next_owner_check {
                    if client_owner_is_gone() {
                        let _ = service.store().checkpoint();
                        break Ok(());
                    }
                    next_owner_check = Instant::now() + OWNER_CHECK_INTERVAL;
                }
                if configured_client_pid().is_none()
                    && generic_idle_may_exit(runtime.idle(), attendance.active())
                {
                    let since = idle_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= IDLE_EXIT_GRACE {
                        let _ = service.store().checkpoint();
                        break Ok(());
                    }
                } else {
                    idle_since = None;
                }
                thread::sleep(CONNECT_RETRY);
            }
            Err(_) => {
                thread::sleep(CONNECT_RETRY);
            }
        }
    };
    attendance.shutdown();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use interprocess::local_socket::Stream;

    #[test]
    fn idle_exit_waits_minutes_after_the_owner_is_empty() {
        assert!(IDLE_EXIT_GRACE >= Duration::from_secs(60));
    }

    #[test]
    fn generic_idle_exit_does_not_truncate_active_attendance() {
        assert!(generic_idle_may_exit(true, false));
        assert!(!generic_idle_may_exit(true, true));
        assert!(!generic_idle_may_exit(false, false));
        assert!(!generic_idle_may_exit(false, true));
    }

    #[test]
    fn client_pid_is_digits_and_rejects_init() {
        assert_eq!(parse_client_pid("12345"), Some(12345));
        assert_eq!(parse_client_pid(" 99 "), Some(99));
        assert!(parse_client_pid("0").is_none());
        assert!(parse_client_pid("1").is_none());
        assert!(parse_client_pid("").is_none());
        assert!(parse_client_pid("/bin/licoup").is_none());
        assert_eq!(process_liveness(std::process::id()), ProcessLiveness::Alive);
        assert_eq!(process_liveness(0), ProcessLiveness::Dead);
    }

    #[test]
    fn host_generation_rejects_paths_and_keeps_a_pid() {
        let generation = "0".repeat(16);
        assert_eq!(
            parse_host_generation_record(&format!("{generation}\n12\n")),
            Some((generation.clone(), Some(12), None))
        );
        assert_eq!(
            parse_host_generation_record(&format!("{generation}\n12\n99\n")),
            Some((generation.clone(), Some(12), Some(99)))
        );
        assert_eq!(
            parse_host_generation_record(&format!("{generation}\n")),
            Some((generation.clone(), None, None))
        );
        assert!(parse_host_generation_record("/Applications/LicoUp.app\n12\n").is_none());
        assert!(parse_host_generation_record(&format!("{generation}\n12\nextra\n")).is_none());
        assert!(parse_host_generation_record(&format!("{generation}\n12\n1\n")).is_none());
        let generation = executable_generation().unwrap();
        assert!(valid_host_generation(&generation));
        assert_eq!(generation, executable_generation().unwrap());
    }

    #[test]
    fn ordinary_rpc_post_returns_while_host_wake_cognition_is_already_held() {
        use interprocess::local_socket::ListenerOptions;
        use licoup_conversation::continuity::list_all_pending_wakes;
        use licoup_native::domain::client_conversation::{
            ConversationService, PersistentRuntimePorts,
        };
        use serde_json::{Value, json};
        use std::io::{BufRead, Write as _};

        let root =
            std::env::temp_dir().join(format!("lico-ca-host-listen-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let complete_calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let entered = std::sync::Arc::new(AtomicBool::new(false));
        let hold = std::sync::Arc::new((std::sync::Mutex::new(false), Condvar::new()));
        let hold_for_complete = hold.clone();
        let entered_for_complete = entered.clone();
        let complete_calls_for_turn = complete_calls.clone();
        let service = ConversationService::open(&root)
            .unwrap()
            .bind_conversation_runtime(PersistentRuntimePorts::new(
                |_params: &Value| {
                    Ok(json!({
                        "ok": true,
                        "accepted": true,
                        "turnHandle": "turn:test",
                    }))
                },
                |_conversation_id: &str| json!([]),
                |_params: &Value| Ok(json!({ "ok": true })),
                move |params: &Value| {
                    entered_for_complete.store(true, Ordering::Release);
                    let (lock, cv) = &*hold_for_complete;
                    let mut released = lock.lock().unwrap_or_else(|poison| poison.into_inner());
                    while !*released {
                        released = cv
                            .wait(released)
                            .unwrap_or_else(|poison| poison.into_inner());
                    }
                    complete_calls_for_turn
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .push(params.clone());
                    let conversation_id = params
                        .get("conversationId")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    Ok(json!({
                        "ok": true,
                        "output": listener_child_proposal_json(conversation_id),
                    }))
                },
                |_request: Value| Ok(json!({})),
            ));
        let (conversation_id, owner, agent) = listener_create_group(&service);
        listener_designate(&service, &conversation_id, &owner, &agent);
        let posted = listener_post(&service, &conversation_id, &owner, "prepare notes now");
        let _ = service
            .execute(json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": conversation_id,
                "eventId": posted,
            }))
            .unwrap();
        service
            .after_runtime_settlement(
                &conversation_id,
                &json!({
                    "output": listener_assistant_envelope(
                        "I'll prepare the notes in a child conversation.",
                        &listener_child_proposal_json(&conversation_id),
                    ),
                    "membershipId": agent,
                    "causationId": posted,
                }),
            )
            .unwrap();
        let host = service.continuity().cloned().unwrap();
        let pending_before = list_all_pending_wakes(host.store()).unwrap();
        assert!(
            !pending_before.is_empty(),
            "durable delegation must leave a pending review wake"
        );
        let logical_wake_ids: Vec<String> = pending_before
            .iter()
            .map(|(_, wake)| wake.logical_wake_id.clone())
            .collect();
        let name =
            licoup_native::platform::conversation_host_transport::endpoint_name_for_root(&root)
                .unwrap();
        let listener = ListenerOptions::new()
            .name(name)
            .nonblocking(ListenerNonblockingMode::Accept)
            .try_overwrite(true)
            .create_sync()
            .expect("test host listener");
        let runtime = PersistentConversationRuntime::new(service.store().clone());
        let stop = Arc::new(AtomicBool::new(false));
        let host_service = service.clone();
        let host_stop = stop.clone();
        let host_thread = thread::spawn(move || {
            serve_bound_host(listener, host_service, runtime, Some(host_stop))
        });

        let entered_deadline = Instant::now() + Duration::from_secs(8);
        while !entered.load(Ordering::Acquire) {
            assert!(
                Instant::now() < entered_deadline,
                "wake cognition must enter the host attendance worker before the new RPC session"
            );
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            complete_calls
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .len(),
            0,
            "held cognition must have entered but not finished before the new RPC post"
        );

        let post_root = root.clone();
        let post_conversation = conversation_id.clone();
        let post_owner = owner.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            let mut stream = connect_test_host(&post_root);
            let request = json!({
                "protocol": licoup_native::platform::conversation_host_transport::STDIO_RPC_PROTOCOL,
                "id": "post-while-held",
                "workflowId": "listener-wake",
                "method": "client.conversation.execute",
                "params": {
                    "action": "conversation.message.post",
                    "conversationId": post_conversation,
                    "authorMembershipId": post_owner,
                    "content": "ordinary follow-up while wake cognition is already held",
                }
            });
            serde_json::to_writer(&mut stream, &request).unwrap();
            stream.write_all(b"\n").unwrap();
            stream.flush().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let _ = tx.send(serde_json::from_str::<Value>(&line).unwrap());
        });
        let follow_up = rx
            .recv_timeout(Duration::from_secs(8))
            .expect("actual host RPC post must return while wake cognition is held");
        assert_eq!(follow_up["ok"], true, "{follow_up}");
        let posted_event = follow_up["result"]["result"]["event"]["id"]
            .as_str()
            .expect("ordinary post must persist an event");
        assert!(!posted_event.is_empty());
        assert!(
            follow_up["result"]["result"]["continuityDrain"].is_null(),
            "ordinary post must not drain wakes: {follow_up}"
        );
        assert!(
            list_all_pending_wakes(host.store())
                .unwrap()
                .iter()
                .any(|(_, wake)| logical_wake_ids.contains(&wake.logical_wake_id)),
            "pending review ownership must survive the new RPC session"
        );
        assert_eq!(
            complete_calls
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .len(),
            0,
            "listener must not await the already-entered held cognition"
        );

        {
            let (lock, cv) = &*hold;
            let mut released = lock.lock().unwrap_or_else(|poison| poison.into_inner());
            *released = true;
            cv.notify_all();
        }
        let finish_deadline = Instant::now() + Duration::from_secs(8);
        loop {
            let completes = complete_calls
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .clone();
            if completes.len() == 1 {
                assert_eq!(
                    completes[0].get("continuityKind").and_then(Value::as_str),
                    Some("wake-review"),
                    "attendance must progress the pending review once after release"
                );
                break;
            }
            assert!(
                Instant::now() < finish_deadline,
                "attendance must finish the already-entered review once after release"
            );
            thread::sleep(Duration::from_millis(20));
        }

        stop.store(true, Ordering::Release);
        let _ = host_thread.join();
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn host_owner_stop_returns_while_wake_cognition_is_still_held() {
        use interprocess::local_socket::ListenerOptions;
        use licoup_conversation::continuity::list_all_pending_wakes;
        use licoup_native::domain::client_conversation::{
            ConversationService, PersistentRuntimePorts,
        };
        use serde_json::{Value, json};

        let root = std::env::temp_dir().join(format!("lico-ca-host-stop-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let complete_calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let entered = std::sync::Arc::new(AtomicBool::new(false));
        let hold = std::sync::Arc::new((std::sync::Mutex::new(false), Condvar::new()));
        let hold_for_complete = hold.clone();
        let entered_for_complete = entered.clone();
        let complete_calls_for_turn = complete_calls.clone();
        let service = ConversationService::open(&root)
            .unwrap()
            .bind_conversation_runtime(PersistentRuntimePorts::new(
                |_params: &Value| {
                    Ok(json!({
                        "ok": true,
                        "accepted": true,
                        "turnHandle": "turn:test",
                    }))
                },
                |_conversation_id: &str| json!([]),
                |_params: &Value| Ok(json!({ "ok": true })),
                move |params: &Value| {
                    entered_for_complete.store(true, Ordering::Release);
                    let (lock, cv) = &*hold_for_complete;
                    let mut released = lock.lock().unwrap_or_else(|poison| poison.into_inner());
                    while !*released {
                        released = cv
                            .wait(released)
                            .unwrap_or_else(|poison| poison.into_inner());
                    }
                    complete_calls_for_turn
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner())
                        .push(params.clone());
                    let conversation_id = params
                        .get("conversationId")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    Ok(json!({
                        "ok": true,
                        "output": listener_child_proposal_json(conversation_id),
                    }))
                },
                |_request: Value| Ok(json!({})),
            ));
        let (conversation_id, owner, agent) = listener_create_group(&service);
        listener_designate(&service, &conversation_id, &owner, &agent);
        let posted = listener_post(&service, &conversation_id, &owner, "prepare notes now");
        let _ = service
            .execute(json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": conversation_id,
                "eventId": posted,
            }))
            .unwrap();
        service
            .after_runtime_settlement(
                &conversation_id,
                &json!({
                    "output": listener_assistant_envelope(
                        "I'll prepare the notes in a child conversation.",
                        &listener_child_proposal_json(&conversation_id),
                    ),
                    "membershipId": agent,
                    "causationId": posted,
                }),
            )
            .unwrap();
        assert!(
            !list_all_pending_wakes(service.continuity().cloned().unwrap().store())
                .unwrap()
                .is_empty(),
            "durable delegation must leave a pending review wake"
        );
        let name =
            licoup_native::platform::conversation_host_transport::endpoint_name_for_root(&root)
                .unwrap();
        let listener = ListenerOptions::new()
            .name(name)
            .nonblocking(ListenerNonblockingMode::Accept)
            .try_overwrite(true)
            .create_sync()
            .expect("test host listener");
        let runtime = PersistentConversationRuntime::new(service.store().clone());
        let stop = Arc::new(AtomicBool::new(false));
        let host_service = service.clone();
        let host_stop = stop.clone();
        let host_thread = thread::spawn(move || {
            serve_bound_host(listener, host_service, runtime, Some(host_stop))
        });

        let entered_deadline = Instant::now() + Duration::from_secs(8);
        while !entered.load(Ordering::Acquire) {
            assert!(
                Instant::now() < entered_deadline,
                "wake cognition must enter before configured host stop"
            );
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            complete_calls
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .len(),
            0,
            "held cognition must have entered but not finished before stop"
        );

        stop.store(true, Ordering::Release);
        let host_deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if host_thread.is_finished() {
                break;
            }
            assert!(
                Instant::now() < host_deadline,
                "serve_bound_host must return without waiting for held cognition"
            );
            thread::sleep(Duration::from_millis(10));
        }
        host_thread
            .join()
            .expect("host thread must return after stop")
            .expect("serve_bound_host stop path");
        assert!(
            try_connect_test_host(&root, Duration::from_millis(150)).is_err(),
            "listener/endpoint must be released before the synthetic hold is released"
        );
        assert_eq!(
            complete_calls
                .lock()
                .unwrap_or_else(|poison| poison.into_inner())
                .len(),
            0,
            "host return must happen before held cognition finishes"
        );

        {
            let (lock, cv) = &*hold;
            let mut released = lock.lock().unwrap_or_else(|poison| poison.into_inner());
            *released = true;
            cv.notify_all();
        }
        let finish_deadline = Instant::now() + Duration::from_secs(8);
        while complete_calls
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .is_empty()
        {
            assert!(
                Instant::now() < finish_deadline,
                "detached attendance must finish the held review after hold release"
            );
            thread::sleep(Duration::from_millis(20));
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    fn listener_create_group(
        service: &licoup_native::domain::client_conversation::ConversationService,
    ) -> (String, String, String) {
        use serde_json::json;
        let group = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Listener wake",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [{
                    "principal": {
                        "id": "agent:codex",
                        "kind": "agent",
                        "displayName": "Codex",
                        "agentId": "codex"
                    },
                    "access": "member"
                }]
            }))
            .unwrap();
        let memberships = group["memberships"].as_array().unwrap();
        let owner = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "human")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let agent = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "agent")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        (group["id"].as_str().unwrap().to_owned(), owner, agent)
    }

    fn listener_designate(
        service: &licoup_native::domain::client_conversation::ConversationService,
        conversation_id: &str,
        owner: &str,
        agent: &str,
    ) {
        use serde_json::json;
        let revision = service.store().get(conversation_id).unwrap().revision;
        service
            .execute(json!({
                "action": "conversation.assistant.set",
                "conversationId": conversation_id,
                "ownerMembershipId": owner,
                "expectedRevision": revision,
                "membershipId": agent,
            }))
            .unwrap();
    }

    fn listener_post(
        service: &licoup_native::domain::client_conversation::ConversationService,
        conversation_id: &str,
        owner: &str,
        content: &str,
    ) -> String {
        use serde_json::json;
        service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner,
                "content": content,
            }))
            .unwrap()["event"]["id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn listener_child_proposal_json(conversation_id: &str) -> String {
        use licoup_conversation::continuity::{
            ContinuityCommitmentProposal, ContinuityFollowThroughKind,
            ContinuityInterpretationProposal, ContinuityMatterSubject, ContinuitySpeechAct,
            ContinuityTaskChildAdmission, ContinuityWriteEnvelope,
        };
        serde_json::to_string(&ContinuityInterpretationProposal {
            envelope: ContinuityWriteEnvelope {
                conversation_id: conversation_id.to_owned(),
                source_event_refs: Vec::new(),
                observed_revision: 0,
                designation_epoch: 0,
                request_id: "request:goal:matter:notes".into(),
            },
            matter_associations: Vec::new(),
            speech_act: ContinuitySpeechAct::Delegation,
            commitment_proposals: vec![ContinuityCommitmentProposal {
                matter_id: Some("matter:notes".into()),
                subject: ContinuityMatterSubject::New,
                expected_result: "Prepare matter:notes".into(),
                criteria: Vec::new(),
                create_goal: true,
            }],
            agreement_proposals: Vec::new(),
            capability_needs: Vec::new(),
            uncertainty_reasons: Vec::new(),
            requested_reads: Vec::new(),
            task_child_admission: Some(ContinuityTaskChildAdmission {
                goal_id: "goal:matter:notes".into(),
                parent_conversation_id: conversation_id.to_owned(),
                speech_act: ContinuitySpeechAct::Delegation,
                follow_through_kind: ContinuityFollowThroughKind::Durable,
                observed_child_conversation_id: None,
                observed_card_anchor: None,
                request_id: "request:admit:goal:matter:notes".into(),
            }),
        })
        .unwrap()
    }

    fn listener_assistant_envelope(reply: &str, proposal_json: &str) -> String {
        let proposal: serde_json::Value = serde_json::from_str(proposal_json).unwrap();
        serde_json::to_string(&serde_json::json!({
            "replyText": reply,
            "interpretationProposal": proposal,
        }))
        .unwrap()
    }

    fn connect_test_host(root: &Path) -> Stream {
        try_connect_test_host(root, Duration::from_secs(5))
            .unwrap_or_else(|error| panic!("actual host listener did not accept: {error}"))
    }

    fn try_connect_test_host(root: &Path, timeout: Duration) -> io::Result<Stream> {
        let deadline = Instant::now() + timeout;
        loop {
            let name =
                licoup_native::platform::conversation_host_transport::endpoint_name_for_root(root)
                    .unwrap();
            match Stream::connect(name) {
                Ok(stream) => return Ok(stream),
                Err(_) if Instant::now() < deadline => thread::sleep(CONNECT_RETRY),
                Err(error) => return Err(error),
            }
        }
    }
}
