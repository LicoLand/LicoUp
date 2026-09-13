//! Local lifecycle control for this executable, independent of the kernel.
use crate::{
    private_state,
    transport::{self, SubagentMcpSupervisor},
};
use anyhow::{Result, anyhow};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    env, fs,
    process::{Command, Stdio},
    thread,
    time::Duration,
};

fn current() -> Option<transport::DiscoveryDocument> {
    transport::discovery_path_read_only()
        .ok()
        .and_then(|path| transport::read_discovery(&path).ok())
}
fn status() -> Value {
    let running = current().is_some_and(|document| {
        let Some((caller, _)) = document.tokens.iter().next() else {
            return false;
        };
        transport::load_connector_discovery(caller)
            .ok()
            .is_some_and(|discovery| transport::connector_health(&discovery))
    });
    json!({"service":"subagents","state":if running {"running"} else {"stopped"}})
}
fn service_lease_held() -> bool {
    let Ok(root) = private_state::portable_data_dir_read_only() else {
        return false;
    };
    let Ok(lease) = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.join("client-state/subagent-mcp/service.lock"))
    else {
        return false;
    };
    match lease.try_lock_exclusive() {
        Ok(()) => false,
        Err(error) => error.kind() == std::io::ErrorKind::WouldBlock,
    }
}
fn clean_stale_generation(generation: &str) {
    // Hold the OS lease while inspecting/removing a crashed generation, so a
    // newly starting service cannot publish between that check and deletion.
    let Ok(root) = private_state::portable_data_dir_read_only() else {
        return;
    };
    let Ok(lease) = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.join("client-state/subagent-mcp/service.lock"))
    else {
        return;
    };
    if lease.try_lock_exclusive().is_err() {
        return;
    }
    if current().is_some_and(|value| value.generation == generation) {
        if let Ok(path) = transport::discovery_path_read_only() {
            let _ = fs::remove_file(path);
        }
    }
}
fn start() -> Result<Value> {
    if status()["state"] == "running" {
        return Ok(status());
    }
    let executable = env::current_exe().map_err(|_| anyhow!("mcp_binary_unavailable"))?;
    let mut child = Command::new(executable)
        .args(["service", "serve"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| anyhow!("mcp_start_failed"))?;
    loop {
        if status()["state"] == "running" {
            return Ok(status());
        }
        if child.try_wait()?.is_some() {
            // A simultaneous starter can win the exclusive service lease.
            let state = status();
            if state["state"] == "running" {
                return Ok(state);
            }
            if !service_lease_held() {
                return Err(anyhow!("mcp_start_failed"));
            }
        }
        thread::sleep(Duration::from_millis(25));
    }
}
fn stop() -> Result<Value> {
    let Some(document) = current() else {
        return Ok(status());
    };
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(2))
        .build();
    let endpoint = document
        .endpoint
        .strip_suffix("/mcp")
        .ok_or_else(|| anyhow!("mcp_state_invalid"))?;
    match agent
        .post(&format!("{endpoint}/control/stop"))
        .set(
            "authorization",
            &format!("Bearer {}", document.control_token),
        )
        .send_bytes(&[])
    {
        Ok(response) if response.status() == 202 => {}
        Err(ureq::Error::Transport(_)) if !service_lease_held() => {
            clean_stale_generation(&document.generation);
            return Ok(status());
        }
        _ => return Err(anyhow!("mcp_stop_failed")),
    }
    // Drain acknowledged protocol calls, without an arbitrary task deadline.
    while current().is_some_and(|value| value.generation == document.generation) {
        if !service_lease_held() {
            clean_stale_generation(&document.generation);
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }
    Ok(json!({"service":"subagents","state":"stopped"}))
}
fn serve() -> Result<Value> {
    let root = private_state::portable_data_dir()?.join("client-state/subagent-mcp");
    private_state::ensure_private_dir(&root)?;
    let mut options = fs::OpenOptions::new();
    options.create(true).read(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lease = options.open(root.join("service.lock"))?;
    lease
        .try_lock_exclusive()
        .map_err(|_| anyhow!("mcp_service_already_running"))?;
    // Catalog startup is read-only. The native process performs all commands.
    let service = SubagentMcpSupervisor::start()?;
    while !service.stopped() && service.healthy() {
        thread::sleep(Duration::from_millis(50));
    }
    drop(service);
    drop(lease);
    Ok(json!({"service":"subagents","state":"stopped"}))
}
pub fn execute(action: &str) -> Result<Value> {
    match action {
        "start" => start(),
        "stop" => stop(),
        "status" => Ok(status()),
        "reload" => {
            stop()?;
            start()
        }
        "serve" => serve(),
        _ => Err(anyhow!("mcp_lifecycle_invalid")),
    }
}
