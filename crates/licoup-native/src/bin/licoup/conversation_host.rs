//! Client-local persistent owner for desktop Agent conversation RPC.
//!
//! The Flutter process owns only a replaceable stdio proxy. The listener and
//! every accepted Agent turn live in this detached CLI host, scoped to the
//! client-owned portable data root.

use anyhow::{Context, Result, anyhow};
use interprocess::local_socket::{
    GenericNamespaced, ListenerNonblockingMode, ListenerOptions, SendHalf, Stream, ToNsName as _,
    traits::{Listener as _, Stream as _},
};
use std::{
    env,
    fs::{self, OpenOptions},
    io::{self, BufReader, Read, Write},
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use super::stdio_rpc::{
    PersistentConversationRuntime, execute_rpc_cli, serve_stdio_rpc_with_runtime,
};

const CONNECT_ATTEMPTS: usize = 80;
const CONNECT_RETRY: Duration = Duration::from_millis(25);
const IDLE_EXIT_GRACE: Duration = Duration::from_secs(1);

fn endpoint_name() -> Result<interprocess::local_socket::Name<'static>> {
    let root = licoup_native::platform::paths::portable_data_dir()?;
    endpoint_name_for_root(&root)
}

fn endpoint_name_for_root(root: &Path) -> Result<interprocess::local_socket::Name<'static>> {
    let endpoint_root = root.join("client-state").join("conversation-runtime");
    licoup_native::platform::file_security::ensure_private_dir(&endpoint_root)?;
    let token_path = endpoint_root.join("endpoint-token");
    let read_token = || -> Result<String> {
        let token = fs::read_to_string(&token_path).context("conversation endpoint unavailable")?;
        let token = token.trim();
        if token.len() != 32 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(anyhow!("conversation endpoint unavailable"));
        }
        Ok(token.to_owned())
    };
    let token = match read_token() {
        Ok(token) => token,
        Err(_) => {
            let token = uuid::Uuid::new_v4().simple().to_string();
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&token_path)
            {
                Ok(mut file) => {
                    file.write_all(token.as_bytes())?;
                    file.sync_all()?;
                    licoup_native::platform::file_security::harden_private_path(&token_path)?;
                    token
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => read_token()?,
                Err(_) => return Err(anyhow!("conversation endpoint unavailable")),
            }
        }
    };
    format!("licoup-conversation-{token}")
        .to_ns_name::<GenericNamespaced>()
        .context("conversation endpoint unavailable")
}

fn connect() -> io::Result<Stream> {
    let name = endpoint_name().map_err(io::Error::other)?;
    Stream::connect(name)
}

fn spawn_host() -> Result<()> {
    let executable = env::current_exe().context("conversation host executable unavailable")?;
    let mut command = Command::new(executable);
    command
        .args(["rpc", "conversation-host"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    command
        .spawn()
        .map(|_| ())
        .context("conversation host start failed")
}

fn connect_or_start() -> Result<Stream> {
    if let Ok(stream) = connect() {
        return Ok(stream);
    }
    spawn_host()?;
    for _ in 0..CONNECT_ATTEMPTS {
        if let Ok(stream) = connect() {
            return Ok(stream);
        }
        thread::sleep(CONNECT_RETRY);
    }
    Err(anyhow!("conversation host unavailable"))
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
    let _ = upload.join();
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
    let name = endpoint_name()?;
    let listener = match ListenerOptions::new()
        .name(name)
        .nonblocking(ListenerNonblockingMode::Accept)
        .try_overwrite(false)
        .create_sync()
    {
        Ok(listener) => listener,
        Err(error) if error.kind() == io::ErrorKind::AddrInUse => return Ok(()),
        Err(error) => return Err(error).context("conversation host listener failed"),
    };
    let root = licoup_native::platform::paths::portable_data_dir()?;
    let service = licoup_native::domain::client_conversation::ConversationService::open(&root)?;
    let runtime = PersistentConversationRuntime::new(service.store().clone());
    let mut idle_since = None;
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
                if runtime.idle() {
                    let since = idle_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= IDLE_EXIT_GRACE {
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
    fn endpoint_is_stable_and_private_to_the_portable_root() {
        let root = std::env::temp_dir().join(format!(
            "licoup-conversation-endpoint-test-{}",
            uuid::Uuid::new_v4()
        ));
        let first = endpoint_name_for_root(&root).unwrap();
        let second = endpoint_name_for_root(&root).unwrap();
        assert_eq!(first, second);
        let token =
            fs::read_to_string(root.join("client-state/conversation-runtime/endpoint-token"))
                .unwrap();
        assert_eq!(token.len(), 32);
        assert!(token.bytes().all(|byte| byte.is_ascii_hexdigit()));
        fs::remove_dir_all(root).unwrap();
    }
}
