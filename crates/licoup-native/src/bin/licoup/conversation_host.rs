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
    ListenerNonblockingMode, ListenerOptions, SendHalf, Stream,
    traits::{Listener as _, Stream as _},
};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, BufReader, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use super::stdio_rpc::{
    PersistentConversationRuntime, execute_rpc_cli, serve_stdio_rpc_with_runtime,
};

const CONNECT_ATTEMPTS: usize = 80;
const CONNECT_RETRY: Duration = Duration::from_millis(25);
const STALE_HOST_WAIT: Duration = Duration::from_secs(2);
const OWNER_CHECK_INTERVAL: Duration = Duration::from_millis(500);
const IDLE_EXIT_GRACE: Duration = Duration::from_secs(300);
const CLIENT_PID_ENV: &str = "LICOUP_CLIENT_PID";

fn host_identity_path(root: &Path) -> PathBuf {
    root.join("client-state")
        .join("conversation-runtime")
        .join("host-identity")
}

fn metadata_identity(metadata: &fs::Metadata) -> String {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        format!(
            "{}:{}:{}:{}",
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mtime()
        )
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt as _;
        format!(
            "{}:{}:{}",
            metadata.file_index().unwrap_or(0),
            metadata.len(),
            metadata.last_write_time()
        )
    }
}

fn executable_identity() -> io::Result<String> {
    let executable = env::current_exe()?;
    Ok(metadata_identity(&fs::metadata(executable)?))
}

fn valid_host_identity(value: &str) -> bool {
    (1..=96).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'.'))
}

fn parse_host_record(text: &str) -> Option<(String, Option<u32>, Option<u32>)> {
    let mut lines = text.lines();
    let identity = lines.next()?.trim();
    if !valid_host_identity(identity) {
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

fn read_host_record() -> Option<(String, Option<u32>, Option<u32>)> {
    let root = licoup_native::platform::paths::portable_data_dir().ok()?;
    let text = fs::read_to_string(host_identity_path(&root)).ok()?;
    parse_host_record(&text)
}

fn write_host_identity() -> Result<()> {
    let root = licoup_native::platform::paths::portable_data_dir()?;
    let path = host_identity_path(&root);
    if let Some(parent) = path.parent() {
        licoup_native::platform::file_security::ensure_private_dir(parent)?;
    }
    let identity = executable_identity().context("conversation host unavailable")?;
    let mut body = format!("{identity}\n{}\n", std::process::id());
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
    let Ok(identity) = executable_identity() else {
        return false;
    };
    let Some((recorded, Some(host_pid), recorded_client)) = read_host_record() else {
        return false;
    };
    if recorded != identity || process_liveness(host_pid) == ProcessLiveness::Dead {
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
    let upload = thread::spawn(move || -> io::Result<()> {
        io::copy(&mut io::stdin().lock(), &mut sender)?;
        sender.flush()?;
        shutdown_upload(&sender)
    });
    // Continue draining the host after stdout disappears. This prevents a
    // closed GUI pipe from applying backpressure to the turn owner.
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
    write_host_identity()?;
    let root = licoup_native::platform::paths::portable_data_dir()?;
    let service = licoup_native::domain::client_conversation::ConversationService::open(&root)?;
    let runtime = PersistentConversationRuntime::new(service.store().clone());
    let mut idle_since = None;
    let mut next_owner_check = Instant::now();
    loop {
        match listener.accept() {
            Ok(stream) => {
                idle_since = None;
                runtime.client_connected();
                let runtime = runtime.clone();
                thread::spawn(move || {
                    let (receiver, sender) = stream.split();
                    let _ = serve_stdio_rpc_with_runtime(
                        BufReader::new(receiver),
                        sender,
                        execute_rpc_cli,
                        runtime.clone(),
                    );
                    runtime.client_disconnected();
                });
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if configured_client_pid().is_some() && Instant::now() >= next_owner_check {
                    if client_owner_is_gone() {
                        let _ = service.store().checkpoint();
                        return Ok(());
                    }
                    next_owner_check = Instant::now() + OWNER_CHECK_INTERVAL;
                }
                if configured_client_pid().is_none() && runtime.idle() {
                    let since = idle_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= IDLE_EXIT_GRACE {
                        let _ = service.store().checkpoint();
                        return Ok(());
                    }
                } else {
                    idle_since = None;
                }
                thread::sleep(CONNECT_RETRY);
            }
            Err(_) => thread::sleep(CONNECT_RETRY),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_exit_waits_minutes_after_the_owner_is_empty() {
        assert!(IDLE_EXIT_GRACE >= Duration::from_secs(60));
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
    fn host_identity_rejects_paths_and_keeps_a_pid() {
        assert_eq!(
            parse_host_record("1:2:3:4\n12\n"),
            Some(("1:2:3:4".into(), Some(12), None))
        );
        assert_eq!(
            parse_host_record("1:2:3:4\n12\n99\n"),
            Some(("1:2:3:4".into(), Some(12), Some(99)))
        );
        assert_eq!(
            parse_host_record("1:2:3:4\n"),
            Some(("1:2:3:4".into(), None, None))
        );
        assert!(parse_host_record("/Applications/LicoUp.app\n12\n").is_none());
        assert!(parse_host_record("1:2:3:4\n12\nextra\n").is_none());
        assert!(parse_host_record("1:2:3:4\n12\n1\n").is_none());
        let metadata = fs::metadata(env::current_exe().unwrap()).unwrap();
        let identity = metadata_identity(&metadata);
        assert!(valid_host_identity(&identity));
        assert_eq!(identity, metadata_identity(&metadata));
    }
}
