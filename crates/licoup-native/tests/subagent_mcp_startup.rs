//! Desktop startup lifecycle proof for the Subagent MCP service.
//!
//! A freshly launched desktop bridge lane (`licoup-cli rpc stdio` carrying the
//! desktop client marker) must start the persistent conversation host and the
//! supervised Subagent MCP service before any conversation action: private
//! discovery appears under the client state root, and a connector session
//! negotiates the exact protocol revision and ordered nine-tool catalog. When
//! the owning client disappears, the host shuts down and removes discovery.

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const CLI_BIN: &str = env!("CARGO_BIN_EXE_licoup-cli");
const CONNECTOR_BIN: &str = env!("CARGO_BIN_EXE_lico-subagent-mcp");

const FROZEN_TOOLS: [&str; 9] = [
    "lico_assistant_profiles",
    "lico_assistant_workflow_execute",
    "lico_assistant_workflow_inspect",
    "lico_assistant_workflow_cancel",
    "lico_subagents_list",
    "lico_subagent_probe",
    "lico_subagent_delegate",
    "lico_subagent_continue",
    "lico_subagent_cancel",
];

fn temp_root(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "licoup-subagent-startup-{tag}-{}",
        uuid::Uuid::new_v4()
    ))
}

fn discovery_path(root: &Path) -> PathBuf {
    root.join("client-state")
        .join("subagent-mcp")
        .join("discovery.json")
}

/// A live, idle stand-in for the desktop client process: the bridge lane with
/// its stdin held open never exits on its own, and its pid is killable.
fn spawn_idle_client(root: &Path) -> Child {
    Command::new(CLI_BIN)
        .args(["rpc", "stdio"])
        .env("LICOUP_PORTABLE_DIR", root)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("idle client spawn")
}

fn spawn_bridge_lane(root: &Path, client_pid: u32) -> Child {
    Command::new(CLI_BIN)
        .args(["rpc", "stdio"])
        .env("LICOUP_PORTABLE_DIR", root)
        .env("LICOUP_CLIENT_PID", client_pid.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("bridge lane spawn")
}

fn wait_for(mut predicate: impl FnMut() -> bool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if predicate() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    predicate()
}

fn kill(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn read_discovery_shape(root: &Path) -> Value {
    let raw = std::fs::read(discovery_path(root)).expect("discovery readable");
    serde_json::from_slice(&raw).expect("discovery json")
}

fn connector_session(root: &Path, caller: &str) -> Value {
    let mut child = Command::new(CONNECTOR_BIN)
        .env("LICOUP_PORTABLE_DIR", root)
        .env("LICOUP_MCP_CALLER_PROVIDER", caller)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("connector spawn");
    let frames = [
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "startup-proof", "version": "1"}
            }
        }),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
    ];
    let mut stdin = child.stdin.take().expect("connector stdin");
    for frame in &frames {
        stdin
            .write_all(format!("{frame}\n").as_bytes())
            .expect("connector write");
    }
    drop(stdin);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        if Instant::now() >= deadline {
            kill(&mut child);
            panic!("connector session timed out");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let mut stdout = Vec::new();
    child
        .stdout
        .take()
        .expect("connector stdout")
        .read_to_end(&mut stdout)
        .expect("connector read");
    assert!(stdout.len() <= 1024 * 1024, "connector output bounded");
    serde_json::json!(
        stdout
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_slice::<Value>(line).expect("connector frame"))
            .collect::<Vec<_>>()
    )
}

#[test]
fn fresh_desktop_bridge_lane_exposes_discovery_and_frozen_catalog_before_any_conversation_action() {
    let root = temp_root("launch");
    std::fs::create_dir_all(&root).unwrap();
    let mut bridge = spawn_bridge_lane(&root, std::process::id());
    let exposed = wait_for(|| discovery_path(&root).is_file(), Duration::from_secs(20));
    kill(&mut bridge);
    assert!(
        exposed,
        "discovery must appear right after desktop startup, before any conversation action"
    );
    let discovery = read_discovery_shape(&root);
    assert_eq!(
        discovery.get("schemaVersion").and_then(Value::as_str),
        Some("licoup.subagent-mcp.discovery.v1")
    );
    let endpoint = discovery
        .get("endpoint")
        .and_then(Value::as_str)
        .expect("endpoint");
    assert!(endpoint.starts_with("http://127.0.0.1:"), "loopback only");
    assert!(endpoint.ends_with("/mcp"));
    assert_eq!(
        discovery
            .get("generation")
            .and_then(Value::as_str)
            .map(str::len),
        Some(32)
    );
    let mut token_holders = discovery
        .get("tokens")
        .and_then(Value::as_object)
        .expect("tokens")
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    token_holders.sort();
    assert_eq!(token_holders, ["antigravity", "codex", "cursor"]);

    let frames = connector_session(&root, "codex");
    let frames = frames.as_array().expect("frame list");
    let initialize = frames
        .iter()
        .find(|frame| frame.get("id") == Some(&json!(1)))
        .and_then(|frame| frame.get("result"))
        .expect("initialize result");
    assert_eq!(
        initialize.get("protocolVersion").and_then(Value::as_str),
        Some("2025-06-18")
    );
    assert_eq!(
        initialize
            .pointer("/serverInfo/name")
            .and_then(Value::as_str),
        Some("lico-up-subagents")
    );
    assert_eq!(
        initialize
            .pointer("/serverInfo/version")
            .and_then(Value::as_str),
        Some("0.11.0")
    );
    let tools = frames
        .iter()
        .find(|frame| frame.get("id") == Some(&json!(2)))
        .and_then(|frame| frame.pointer("/result/tools"))
        .and_then(Value::as_array)
        .expect("tools list")
        .iter()
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect::<Vec<_>>();
    assert_eq!(tools, FROZEN_TOOLS, "exact ordered nine-tool catalog");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn owner_shutdown_removes_discovery_state() {
    let root = temp_root("shutdown");
    std::fs::create_dir_all(&root).unwrap();
    let mut client = spawn_idle_client(&root);
    let mut bridge = spawn_bridge_lane(&root, client.id());
    let exposed = wait_for(|| discovery_path(&root).is_file(), Duration::from_secs(20));
    assert!(exposed, "discovery appears after desktop startup");
    kill(&mut client);
    let removed = wait_for(|| !discovery_path(&root).exists(), Duration::from_secs(15));
    kill(&mut bridge);
    assert!(
        removed,
        "graceful owner shutdown stops the service and removes discovery"
    );
    let _ = std::fs::remove_dir_all(&root);
}
