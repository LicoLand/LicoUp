use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{atomic_write_private_text, ensure_private_dir};
use anyhow::{Result, anyhow};
use directories::UserDirs;
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const COLLECTION: &str = "proxy-bridge";
const BRIDGE_SCHEMA_VERSION: u32 = 1;
const DEFAULT_MIXED_PORT: u16 = 7897;
const NO_PROXY_VALUE: &str = "127.0.0.1,localhost,::1,.local";

#[derive(Clone, Copy)]
struct AgentBridgeDef {
    id: &'static str,
    label: &'static str,
    binary_names: &'static [&'static str],
    process_names: &'static [&'static str],
}

const AGENT_BRIDGE_DEFS: &[AgentBridgeDef] = &[
    AgentBridgeDef {
        id: "codex",
        label: "ChatGPT Codex - CLI",
        binary_names: &["codex"],
        process_names: &["codex", "codex.exe"],
    },
    AgentBridgeDef {
        id: "claude-code",
        label: "Claude Code - CLI",
        binary_names: &["claude"],
        process_names: &["claude", "claude.exe"],
    },
    AgentBridgeDef {
        id: "antigravity",
        label: "Antigravity - CLI",
        binary_names: &["antigravity"],
        process_names: &["antigravity", "antigravity.exe"],
    },
    AgentBridgeDef {
        id: "opencode",
        label: "OpenCode - CLI",
        binary_names: &["opencode"],
        process_names: &["opencode", "opencode.exe"],
    },
    AgentBridgeDef {
        id: "openclaw",
        label: "OpenClaw - CLI",
        binary_names: &["openclaw"],
        process_names: &["openclaw", "openclaw.exe"],
    },
    AgentBridgeDef {
        id: "cursor",
        label: "Cursor - IDE",
        binary_names: &["cursor"],
        process_names: &["cursor", "cursor.exe"],
    },
    AgentBridgeDef {
        id: "code",
        label: "Visual Studio Code - IDE",
        binary_names: &["code", "code-insiders"],
        process_names: &["code", "code.exe", "code-insiders", "code-insiders.exe"],
    },
    AgentBridgeDef {
        id: "copilot",
        label: "GitHub Copilot - CLI",
        binary_names: &["copilot"],
        process_names: &["copilot", "copilot.exe"],
    },
    AgentBridgeDef {
        id: "kilo-code",
        label: "Kilo Code - CLI",
        binary_names: &["kilo", "kilocode"],
        process_names: &["kilo", "kilo.exe", "kilocode", "kilocode.exe"],
    },
    AgentBridgeDef {
        id: "kimi-code",
        label: "Kimi Code - CLI",
        binary_names: &["kimi"],
        process_names: &["kimi", "kimi.exe"],
    },
    AgentBridgeDef {
        id: "hermes",
        label: "Hermes Agent - CLI",
        binary_names: &["hermes"],
        process_names: &["hermes", "hermes.exe"],
    },
    AgentBridgeDef {
        id: "pi",
        label: "Pi Agent - CLI",
        binary_names: &["pi"],
        process_names: &["pi", "pi.exe"],
    },
];

#[derive(Clone, Debug)]
struct ClashDetection {
    app_detected: bool,
    app_candidates: Vec<Value>,
    config_candidates: Vec<Value>,
    selected_config_path: Option<PathBuf>,
    mixed_port: Option<u16>,
    mixed_port_source: String,
    proxy_url: String,
    proxy_reachable: bool,
    tun: TunDetection,
    warnings: Vec<Value>,
}

#[derive(Clone, Debug, Default)]
struct TunDetection {
    configured: bool,
    enabled: bool,
    stack: Option<String>,
    device: Option<String>,
    auto_route: Option<bool>,
    auto_detect_interface: Option<bool>,
    find_process_mode: Option<String>,
    enable_process: Option<bool>,
    config_path: Option<PathBuf>,
}

pub fn detect(params: &Value) -> Result<Value> {
    let detection = detect_clash(params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "mode": "clash-proxy-bridge",
        "detection": detection_json(&detection),
        "proxy": proxy_json(&detection),
        "tunAssist": tun_assist_json(&detection, &selected_agent_defs(params)),
        "warnings": detection.warnings
    }))
}

pub fn status(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let document = store.read_collection(COLLECTION)?;
    let detection = detect_clash(params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "mode": "clash-proxy-bridge",
        "status": bridge_status(&document),
        "document": document,
        "detection": detection_json(&detection),
        "proxy": proxy_json(&detection),
        "tunAssist": tun_assist_json(&detection, &selected_agent_defs(params))
    }))
}

pub fn plan(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let detection = detect_clash(params)?;
    let agents = selected_agent_defs(params);
    let wrapper_root = wrapper_root(&store);
    let wrappers = wrapper_plan(&agents, &wrapper_root, &detection.proxy_url);
    Ok(json!({
        "ok": true,
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "mode": "clash-proxy-bridge",
        "status": "planned",
        "willModifyClashConfig": false,
        "willWriteClientState": true,
        "willWriteManagedWrappers": true,
        "detection": detection_json(&detection),
        "proxy": proxy_json(&detection),
        "clientBridge": {
            "enabled": bool_param(params, "clientEnabled").unwrap_or(true),
            "environment": proxy_environment_json(&detection.proxy_url)
        },
        "wrappers": {
            "enabled": bool_param(params, "wrapperEnabled").unwrap_or(true),
            "root": display_path(wrapper_root),
            "items": wrappers
        },
        "tunAssist": tun_assist_json(&detection, &agents)
    }))
}

pub fn apply(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let detection = detect_clash(params)?;
    ensure_loopback_proxy_url(&detection.proxy_url)?;
    let agents = selected_agent_defs(params);
    let client_enabled = bool_param(params, "clientEnabled").unwrap_or(true);
    let wrapper_enabled = bool_param(params, "wrapperEnabled").unwrap_or(true);
    let wrapper_root = wrapper_root(&store);
    let wrappers = if wrapper_enabled {
        write_wrappers(&agents, &wrapper_root, &detection.proxy_url)?
    } else {
        Vec::new()
    };
    let generated_at = timestamp();
    let document = json!({
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "collection": COLLECTION,
        "enabled": client_enabled || wrapper_enabled,
        "provider": "clash-verge",
        "generatedAt": generated_at,
        "proxy": proxy_json(&detection),
        "clientBridge": {
            "enabled": client_enabled,
            "environment": proxy_environment_json(&detection.proxy_url)
        },
        "wrappers": {
            "enabled": wrapper_enabled,
            "root": display_path(wrapper_root.clone()),
            "items": wrappers
        },
        "targets": agents.iter().map(|agent| json!({
            "target": agent.id,
            "label": agent.label,
            "binaryNames": agent.binary_names,
            "processNames": agent.process_names
        })).collect::<Vec<_>>(),
        "detection": detection_json(&detection),
        "tunAssist": tun_assist_json(&detection, &agents),
        "policy": {
            "modifiesClashConfig": false,
            "transparentTrafficHijack": false,
            "managedWrapperDirectoryOnly": true
        }
    });
    let saved = store.write_collection(COLLECTION, document)?;
    let activity = store.activity_log().append(
        "proxy_bridge.applied",
        json!({
            "target": "proxy-bridge",
            "provider": "clash-verge",
            "proxyUrl": detection.proxy_url,
            "clientEnabled": client_enabled,
            "wrapperEnabled": wrapper_enabled,
            "wrapperRoot": display_path(wrapper_root)
        }),
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "mode": "clash-proxy-bridge",
        "status": "applied",
        "document": saved,
        "activity": activity
    }))
}

pub fn rollback(params: &Value) -> Result<Value> {
    let store = client_state_store(params)?;
    let existing = store.read_collection(COLLECTION)?;
    let remove_wrappers = bool_param(params, "removeWrappers").unwrap_or(true);
    let removed_wrappers = if remove_wrappers {
        remove_managed_wrappers(&store, &existing)?
    } else {
        Vec::new()
    };
    let document = json!({
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "collection": COLLECTION,
        "enabled": false,
        "provider": "clash-verge",
        "rolledBackAt": timestamp(),
        "proxy": existing.get("proxy").cloned().unwrap_or_else(|| json!({})),
        "clientBridge": {
            "enabled": false,
            "environment": {}
        },
        "wrappers": {
            "enabled": false,
            "root": display_path(wrapper_root(&store)),
            "items": []
        },
        "previousStatus": bridge_status(&existing),
        "policy": {
            "modifiesClashConfig": false,
            "transparentTrafficHijack": false,
            "managedWrapperDirectoryOnly": true
        }
    });
    let saved = store.write_collection(COLLECTION, document)?;
    let activity = store.activity_log().append(
        "proxy_bridge.rolled_back",
        json!({
            "target": "proxy-bridge",
            "removedWrappers": removed_wrappers.len(),
            "removeWrappers": remove_wrappers
        }),
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": BRIDGE_SCHEMA_VERSION,
        "mode": "clash-proxy-bridge",
        "status": "rolled_back",
        "removedWrappers": removed_wrappers,
        "document": saved,
        "activity": activity
    }))
}

fn client_state_store(params: &Value) -> Result<ClientStateStore> {
    if let Some(path) = text_param(params, &["stateRoot"]) {
        return ClientStateStore::new(PathBuf::from(path));
    }
    ClientStateStore::portable()
}

fn detect_clash(params: &Value) -> Result<ClashDetection> {
    let mut warnings = Vec::<Value>::new();
    let app_candidates = clash_app_candidates();
    let app_detected = app_candidates
        .iter()
        .any(|candidate| candidate.get("exists").and_then(Value::as_bool) == Some(true));
    let config_paths = clash_config_candidates(params);
    let mut config_candidates = Vec::<Value>::new();
    let mut selected_config_path = None;
    let mut selected_config_content = None;
    for path in config_paths {
        let exists = path.is_file();
        let mut item = json!({
            "path": display_path(path.clone()),
            "exists": exists
        });
        if exists {
            match fs::read_to_string(&path) {
                Ok(content) => {
                    if selected_config_path.is_none() && has_clash_signal(&content) {
                        selected_config_path = Some(path.clone());
                        selected_config_content = Some(content.clone());
                        item["selected"] = json!(true);
                    }
                    if let Some(port) = yaml_number(&content, "mixed-port") {
                        item["mixedPort"] = json!(port);
                    }
                    if let Some(enabled) = yaml_tun_bool(&content, "enable") {
                        item["tunEnabled"] = json!(enabled);
                    }
                }
                Err(error) => {
                    item["readable"] = json!(false);
                    warnings.push(json!({
                        "code": "clash_config_unreadable",
                        "message": error.to_string()
                    }));
                }
            }
        }
        config_candidates.push(item);
    }

    let proxy_url_override = text_param(params, &["proxyUrl"]);
    let mixed_port_override = u16_param(params, "mixedPort");
    let (mixed_port, mixed_port_source) = if let Some(proxy_url) = proxy_url_override.as_deref() {
        ensure_loopback_proxy_url(proxy_url)?;
        (proxy_port(proxy_url), "explicit-proxy-url".to_string())
    } else if let Some(port) = mixed_port_override {
        (Some(port), "explicit-mixed-port".to_string())
    } else if let Some(content) = selected_config_content.as_deref() {
        if let Some(port) = yaml_number(content, "mixed-port").and_then(to_u16) {
            (Some(port), "clash-config:mixed-port".to_string())
        } else if let Some(port) = yaml_number(content, "port").and_then(to_u16) {
            (Some(port), "clash-config:port".to_string())
        } else {
            (Some(DEFAULT_MIXED_PORT), "default-clash-verge".to_string())
        }
    } else {
        (Some(DEFAULT_MIXED_PORT), "default-clash-verge".to_string())
    };
    let proxy_url = proxy_url_override.unwrap_or_else(|| {
        format!(
            "http://127.0.0.1:{}",
            mixed_port.unwrap_or(DEFAULT_MIXED_PORT)
        )
    });
    ensure_loopback_proxy_url(&proxy_url)?;
    let tun = selected_config_content
        .as_deref()
        .map(|content| tun_detection(content, selected_config_path.clone()))
        .unwrap_or_default();
    let proxy_reachable = mixed_port.map(is_loopback_port_reachable).unwrap_or(false);
    if !app_detected && selected_config_path.is_none() {
        warnings.push(json!({
            "code": "clash_verge_not_detected",
            "message": "Clash Verge was not detected in common app or config locations."
        }));
    }
    if !proxy_reachable {
        warnings.push(json!({
            "code": "clash_proxy_not_reachable",
            "message": "The loopback mixed-port is not reachable right now; apply can still save configuration for the next Clash start."
        }));
    }
    Ok(ClashDetection {
        app_detected,
        app_candidates,
        config_candidates,
        selected_config_path,
        mixed_port,
        mixed_port_source,
        proxy_url,
        proxy_reachable,
        tun,
        warnings,
    })
}

fn clash_app_candidates() -> Vec<Value> {
    let mut paths = Vec::<PathBuf>::new();
    if cfg!(target_os = "macos") {
        paths.extend([
            PathBuf::from("/Applications/Clash Verge.app"),
            PathBuf::from("/Applications/Clash Verge Rev.app"),
        ]);
        if let Some(home) = home_dir() {
            paths.push(home.join("Applications").join("Clash Verge.app"));
            paths.push(home.join("Applications").join("Clash Verge Rev.app"));
        }
    } else if cfg!(target_os = "windows") {
        if let Ok(program_files) = env::var("ProgramFiles") {
            paths.push(PathBuf::from(&program_files).join("Clash Verge"));
            paths.push(PathBuf::from(&program_files).join("Clash Verge Rev"));
        }
        if let Ok(local_app_data) = env::var("LOCALAPPDATA") {
            paths.push(
                PathBuf::from(&local_app_data)
                    .join("Programs")
                    .join("Clash Verge"),
            );
            paths.push(
                PathBuf::from(&local_app_data)
                    .join("Programs")
                    .join("Clash Verge Rev"),
            );
        }
    } else {
        paths.extend([
            PathBuf::from("/usr/bin/clash-verge"),
            PathBuf::from("/usr/local/bin/clash-verge"),
            PathBuf::from(concat!("/", "opt", "/Clash Verge")),
            PathBuf::from(concat!("/", "opt", "/clash-verge")),
        ]);
    }
    paths
        .into_iter()
        .map(|path| {
            json!({
                "path": display_path(path.clone()),
                "exists": path.exists()
            })
        })
        .collect()
}

fn clash_config_candidates(params: &Value) -> Vec<PathBuf> {
    let mut paths = Vec::<PathBuf>::new();
    if let Some(path) = text_param(params, &["configPath", "clashConfig"]) {
        paths.push(PathBuf::from(path));
    }
    if let Some(dir) = text_param(params, &["clashDir", "appDir"]) {
        add_clash_dir_candidates(&mut paths, PathBuf::from(dir));
    }
    for dir in default_clash_dirs() {
        add_clash_dir_candidates(&mut paths, dir);
    }
    dedupe_paths(paths)
}

fn add_clash_dir_candidates(paths: &mut Vec<PathBuf>, dir: PathBuf) {
    paths.push(dir.join("verge.yaml"));
    paths.push(dir.join("config.yaml"));
    paths.push(dir.join("profiles").join("default.yaml"));
    if let Ok(entries) = fs::read_dir(dir.join("profiles")) {
        for entry in entries.flatten() {
            let path = entry.path();
            let extension = path.extension().and_then(|item| item.to_str());
            if matches!(extension, Some("yaml" | "yml")) {
                paths.push(path);
            }
        }
    }
}

fn default_clash_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::<PathBuf>::new();
    if let Some(home) = home_dir() {
        if cfg!(target_os = "macos") {
            dirs.push(
                home.join("Library")
                    .join("Application Support")
                    .join("io.github.clash-verge-rev.clash-verge-rev"),
            );
            dirs.push(home.join(".config").join("clash-verge"));
        } else if cfg!(target_os = "windows") {
            if let Ok(app_data) = env::var("APPDATA") {
                dirs.push(
                    PathBuf::from(&app_data).join("io.github.clash-verge-rev.clash-verge-rev"),
                );
                dirs.push(PathBuf::from(&app_data).join("clash-verge"));
            }
            if let Ok(local_app_data) = env::var("LOCALAPPDATA") {
                dirs.push(
                    PathBuf::from(&local_app_data)
                        .join("io.github.clash-verge-rev.clash-verge-rev"),
                );
            }
        } else {
            if let Ok(xdg_config) = env::var("XDG_CONFIG_HOME") {
                dirs.push(
                    PathBuf::from(&xdg_config).join("io.github.clash-verge-rev.clash-verge-rev"),
                );
                dirs.push(PathBuf::from(&xdg_config).join("clash-verge"));
            }
            if let Ok(xdg_data) = env::var("XDG_DATA_HOME") {
                dirs.push(
                    PathBuf::from(&xdg_data).join("io.github.clash-verge-rev.clash-verge-rev"),
                );
            }
            dirs.push(home.join(".config").join("clash-verge"));
            dirs.push(
                home.join(".local")
                    .join("share")
                    .join("io.github.clash-verge-rev.clash-verge-rev"),
            );
        }
    }
    dirs
}

fn has_clash_signal(content: &str) -> bool {
    yaml_number(content, "mixed-port").is_some()
        || yaml_number(content, "port").is_some()
        || yaml_scalar(content, "external-controller").is_some()
        || content.lines().any(|line| line.trim() == "tun:")
}

fn tun_detection(content: &str, config_path: Option<PathBuf>) -> TunDetection {
    TunDetection {
        configured: yaml_has_section(content, "tun"),
        enabled: yaml_tun_bool(content, "enable").unwrap_or(false),
        stack: yaml_tun_scalar(content, "stack"),
        device: yaml_tun_scalar(content, "device"),
        auto_route: yaml_tun_bool(content, "auto-route"),
        auto_detect_interface: yaml_tun_bool(content, "auto-detect-interface"),
        find_process_mode: yaml_scalar(content, "find-process-mode"),
        enable_process: yaml_bool(content, "enable-process"),
        config_path,
    }
}

fn yaml_has_section(content: &str, key: &str) -> bool {
    content.lines().any(|line| {
        let trimmed = strip_comment(line).trim();
        trimmed == format!("{key}:")
    })
}

fn yaml_number(content: &str, key: &str) -> Option<u64> {
    yaml_scalar(content, key).and_then(|value| value.parse::<u64>().ok())
}

fn yaml_bool(content: &str, key: &str) -> Option<bool> {
    yaml_scalar(content, key).and_then(|value| match value.to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" => Some(false),
        _ => None,
    })
}

fn yaml_scalar(content: &str, key: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = strip_comment(line).trim();
        let Some(rest) = trimmed.strip_prefix(key) else {
            continue;
        };
        let Some(value) = rest.strip_prefix(':') else {
            continue;
        };
        let value = clean_yaml_scalar(value);
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

fn yaml_tun_bool(content: &str, key: &str) -> Option<bool> {
    yaml_tun_scalar(content, key).and_then(|value| match value.to_ascii_lowercase().as_str() {
        "true" | "yes" | "on" | "1" => Some(true),
        "false" | "no" | "off" | "0" => Some(false),
        _ => None,
    })
}

fn yaml_tun_scalar(content: &str, key: &str) -> Option<String> {
    yaml_section_scalar(content, "tun", key)
}

fn yaml_section_scalar(content: &str, section: &str, key: &str) -> Option<String> {
    let mut in_section = false;
    let mut section_indent = 0usize;
    for line in content.lines() {
        let uncommented = strip_comment(line);
        let trimmed = uncommented.trim();
        if trimmed.is_empty() {
            continue;
        }
        let indent = uncommented
            .chars()
            .take_while(|ch| ch.is_whitespace())
            .count();
        if !in_section {
            if trimmed == format!("{section}:") {
                in_section = true;
                section_indent = indent;
            }
            continue;
        }
        if indent <= section_indent {
            break;
        }
        let Some(rest) = trimmed.strip_prefix(key) else {
            continue;
        };
        let Some(value) = rest.strip_prefix(':') else {
            continue;
        };
        let value = clean_yaml_scalar(value);
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

fn strip_comment(line: &str) -> &str {
    let mut in_quote = false;
    let mut quote = '\0';
    for (index, ch) in line.char_indices() {
        if in_quote {
            if ch == quote {
                in_quote = false;
            }
            continue;
        }
        if ch == '"' || ch == '\'' {
            in_quote = true;
            quote = ch;
            continue;
        }
        if ch == '#' {
            return &line[..index];
        }
    }
    line
}

fn clean_yaml_scalar(value: &str) -> String {
    let trimmed = value.trim();
    trimmed
        .trim_matches('"')
        .trim_matches('\'')
        .trim()
        .to_string()
}

fn to_u16(value: u64) -> Option<u16> {
    u16::try_from(value).ok().filter(|port| *port > 0)
}

fn is_loopback_port_reachable(port: u16) -> bool {
    let addrs = [
        SocketAddr::from(([127, 0, 0, 1], port)),
        SocketAddr::from(([0, 0, 0, 0, 0, 0, 0, 1], port)),
    ];
    addrs.iter().any(|addr| {
        TcpStream::connect_timeout(addr, Duration::from_millis(180))
            .map(|stream| {
                drop(stream);
                true
            })
            .unwrap_or(false)
    })
}

fn proxy_json(detection: &ClashDetection) -> Value {
    json!({
        "provider": "clash-verge",
        "proxyUrl": detection.proxy_url,
        "mixedPort": detection.mixed_port,
        "mixedPortSource": detection.mixed_port_source,
        "reachable": detection.proxy_reachable,
        "environment": proxy_environment_json(&detection.proxy_url)
    })
}

fn detection_json(detection: &ClashDetection) -> Value {
    json!({
        "appDetected": detection.app_detected,
        "appCandidates": detection.app_candidates,
        "configCandidates": detection.config_candidates,
        "selectedConfigPath": detection.selected_config_path.clone().map(display_path),
        "tun": tun_detection_json(&detection.tun)
    })
}

fn tun_detection_json(tun: &TunDetection) -> Value {
    let authorization_status = if tun.enabled {
        "enabled_in_config_unverified"
    } else if tun.configured {
        "configured_but_disabled"
    } else {
        "not_configured"
    };
    json!({
        "configured": tun.configured,
        "enabled": tun.enabled,
        "authorizationStatus": authorization_status,
        "stack": tun.stack,
        "device": tun.device,
        "autoRoute": tun.auto_route,
        "autoDetectInterface": tun.auto_detect_interface,
        "findProcessMode": tun.find_process_mode,
        "enableProcess": tun.enable_process,
        "configPath": tun.config_path.clone().map(display_path)
    })
}

fn tun_assist_json(detection: &ClashDetection, agents: &[AgentBridgeDef]) -> Value {
    let rules = agents
        .iter()
        .flat_map(|agent| {
            agent
                .process_names
                .iter()
                .copied()
                .filter(|name| !name.ends_with(".exe"))
                .map(|name| {
                    json!({
                        "agentId": agent.id,
                        "processName": name,
                        "rule": format!("PROCESS-NAME,{name},<your-proxy-policy>")
                    })
                })
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    let process_rule_lines = rules
        .iter()
        .filter_map(|rule| rule.get("rule").and_then(Value::as_str))
        .map(|rule| format!("  - {rule}"))
        .collect::<Vec<_>>()
        .join("\n");
    let yaml_snippet = format!(
        "mixed-port: {}\nallow-lan: false\nenable-process: true\nfind-process-mode: strict\ntun:\n  enable: true\n  stack: mixed\n  auto-route: true\n  auto-detect-interface: true\n  dns-hijack:\n    - any:53\n    - tcp://any:53\nrules:\n{}\n",
        detection.mixed_port.unwrap_or(DEFAULT_MIXED_PORT),
        if process_rule_lines.is_empty() {
            "  - MATCH,<your-proxy-policy>".to_string()
        } else {
            process_rule_lines
        }
    );
    json!({
        "mode": "advisory-only",
        "willModifyClashConfig": false,
        "authorizationStatus": tun_detection_json(&detection.tun)["authorizationStatus"].clone(),
        "summary": if detection.tun.enabled {
            "Clash TUN appears enabled in config, but OS authorization cannot be proven from the client."
        } else {
            "Enable and authorize TUN inside Clash Verge before using these process rules."
        },
        "requiredUserAction": platform_tun_guidance(),
        "processRules": rules,
        "yamlSnippet": yaml_snippet
    })
}

fn proxy_environment_json(proxy_url: &str) -> Value {
    let mut map = Map::new();
    for key in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
    ] {
        map.insert(key.to_string(), json!(proxy_url));
    }
    map.insert("NO_PROXY".to_string(), json!(NO_PROXY_VALUE));
    map.insert("no_proxy".to_string(), json!(NO_PROXY_VALUE));
    map.insert("LICO_PROXY_BRIDGE_ACTIVE".to_string(), json!("1"));
    Value::Object(map)
}

fn platform_tun_guidance() -> Vec<Value> {
    if cfg!(target_os = "windows") {
        vec![
            json!("Enable Clash Verge Service Mode or run Clash Verge as administrator."),
            json!("Enable TUN in Clash Verge settings, then restart the core."),
            json!("Review process rules before adding them to a merge/script profile."),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            json!("Open Clash Verge settings and authorize TUN from the Clash settings panel."),
            json!("Enable TUN after authorization, then restart the core."),
            json!("Review process rules before adding them to a merge/script profile."),
        ]
    } else {
        vec![
            json!(
                "Authorize TUN in Clash Verge and ensure firewall rules allow the TUN interface."
            ),
            json!("Enable TUN after authorization, then restart the core."),
            json!("Review process rules before adding them to a merge/script profile."),
        ]
    }
}

fn wrapper_plan(agents: &[AgentBridgeDef], root: &Path, proxy_url: &str) -> Vec<Value> {
    agents
        .iter()
        .map(|agent| wrapper_item(agent, root, proxy_url, false))
        .collect()
}

fn write_wrappers(agents: &[AgentBridgeDef], root: &Path, proxy_url: &str) -> Result<Vec<Value>> {
    ensure_private_dir(root)?;
    let mut items = Vec::<Value>::new();
    for agent in agents {
        let path = wrapper_path(root, agent.id);
        let content = wrapper_content(agent, proxy_url);
        atomic_write_private_text(&path, &content)?;
        set_unix_executable(&path)?;
        items.push(wrapper_item(agent, root, proxy_url, true));
    }
    Ok(items)
}

fn wrapper_item(agent: &AgentBridgeDef, root: &Path, proxy_url: &str, written: bool) -> Value {
    json!({
        "target": agent.id,
        "label": agent.label,
        "path": display_path(wrapper_path(root, agent.id)),
        "binary": agent.binary_names.first().copied().unwrap_or(agent.id),
        "proxyUrl": proxy_url,
        "written": written,
        "managed": true
    })
}

fn wrapper_path(root: &Path, agent_id: &str) -> PathBuf {
    let extension = if cfg!(target_os = "windows") {
        ".cmd"
    } else {
        ""
    };
    root.join(format!("lico-{}-proxy{}", sanitize_id(agent_id), extension))
}

fn wrapper_content(agent: &AgentBridgeDef, proxy_url: &str) -> String {
    let binary = agent.binary_names.first().copied().unwrap_or(agent.id);
    if cfg!(target_os = "windows") {
        format!(
            "@echo off\r\nset \"HTTP_PROXY={proxy_url}\"\r\nset \"HTTPS_PROXY={proxy_url}\"\r\nset \"ALL_PROXY={proxy_url}\"\r\nset \"http_proxy={proxy_url}\"\r\nset \"https_proxy={proxy_url}\"\r\nset \"all_proxy={proxy_url}\"\r\nset \"NO_PROXY={NO_PROXY_VALUE}\"\r\nset \"no_proxy={NO_PROXY_VALUE}\"\r\nset \"LICO_PROXY_BRIDGE_ACTIVE=1\"\r\n{binary} %*\r\n"
        )
    } else {
        format!(
            "#!/bin/sh\nexport HTTP_PROXY={proxy}\nexport HTTPS_PROXY={proxy}\nexport ALL_PROXY={proxy}\nexport http_proxy={proxy}\nexport https_proxy={proxy}\nexport all_proxy={proxy}\nexport NO_PROXY={no_proxy}\nexport no_proxy={no_proxy}\nexport LICO_PROXY_BRIDGE_ACTIVE=1\nexec {binary} \"$@\"\n",
            proxy = shell_quote(proxy_url),
            no_proxy = shell_quote(NO_PROXY_VALUE),
            binary = shell_quote(binary)
        )
    }
}

#[cfg(unix)]
fn set_unix_executable(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(path, permissions)?;
    Ok(())
}

#[cfg(not(unix))]
fn set_unix_executable(_path: &Path) -> Result<()> {
    Ok(())
}

fn remove_managed_wrappers(store: &ClientStateStore, document: &Value) -> Result<Vec<Value>> {
    let root = wrapper_root(store);
    let root_canonical = fs::canonicalize(&root).unwrap_or(root.clone());
    let mut removed = Vec::<Value>::new();
    let items = document
        .get("wrappers")
        .and_then(|wrappers| wrappers.get("items"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for item in items {
        let Some(path_text) = item.get("path").and_then(Value::as_str) else {
            continue;
        };
        let path = PathBuf::from(path_text);
        let canonical_parent = path
            .parent()
            .and_then(|parent| fs::canonicalize(parent).ok())
            .unwrap_or_else(|| root_canonical.clone());
        if canonical_parent != root_canonical {
            continue;
        }
        if path.exists() {
            fs::remove_file(&path)?;
            removed.push(json!({
                "path": display_path(path),
                "removed": true
            }));
        }
    }
    Ok(removed)
}

fn wrapper_root(store: &ClientStateStore) -> PathBuf {
    store.root().join("proxy-bridge").join("wrappers")
}

fn selected_agent_defs(params: &Value) -> Vec<AgentBridgeDef> {
    let requested = target_list_param(params);
    if requested.is_empty() {
        return AGENT_BRIDGE_DEFS.to_vec();
    }
    requested
        .into_iter()
        .filter_map(|target| agent_def(&target))
        .collect()
}

fn target_list_param(params: &Value) -> Vec<String> {
    text_param(params, &["targets", "agents", "target", "agent"])
        .map(|value| {
            value
                .split(',')
                .map(normalize_agent_id)
                .filter(|item| !item.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn agent_def(target: &str) -> Option<AgentBridgeDef> {
    let normalized = normalize_agent_id(target);
    AGENT_BRIDGE_DEFS
        .iter()
        .copied()
        .find(|def| def.id == normalized)
}

fn normalize_agent_id(value: &str) -> String {
    match value.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude_code" | "claudecode" => "claude-code".to_string(),
        "antigravity-code" | "antigravity_code" => "antigravity".to_string(),
        "open-code" | "open_code" => "opencode".to_string(),
        "vscode" | "vs-code" | "vs_code" => "code".to_string(),
        "github-copilot" => "copilot".to_string(),
        "kilo" | "kilo_code" | "kilocode" => "kilo-code".to_string(),
        "kimi_code" | "kimicode" => "kimi-code".to_string(),
        "hermes-agent" | "hermes_serena" | "hermes-serena" => "hermes".to_string(),
        "pi-agent" | "pi_agent" | "pi-coding-agent" | "pi_coding_agent" => "pi".to_string(),
        other => other.to_string(),
    }
}

fn bridge_status(document: &Value) -> &'static str {
    if document
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        "enabled"
    } else if document
        .get("rolledBackAt")
        .and_then(Value::as_str)
        .is_some()
    {
        "rolled_back"
    } else {
        "not_configured"
    }
}

fn ensure_loopback_proxy_url(proxy_url: &str) -> Result<()> {
    let trimmed = proxy_url.trim();
    let lower = trimmed.to_ascii_lowercase();
    let Some(rest) = lower
        .strip_prefix("http://")
        .or_else(|| lower.strip_prefix("https://"))
        .or_else(|| lower.strip_prefix("socks5://"))
        .or_else(|| lower.strip_prefix("socks5h://"))
    else {
        return Err(anyhow!(
            "proxy URL must use http, https, socks5, or socks5h"
        ));
    };
    let host_port = rest.split('/').next().unwrap_or_default();
    let host = host_port
        .rsplit_once(':')
        .map(|(host, _)| host)
        .unwrap_or(host_port)
        .trim_matches(['[', ']']);
    if !matches!(host, "127.0.0.1" | "localhost" | "::1") {
        return Err(anyhow!("proxy URL must point to loopback"));
    }
    if proxy_port(trimmed).is_none() {
        return Err(anyhow!("proxy URL must include a valid port"));
    }
    Ok(())
}

fn proxy_port(proxy_url: &str) -> Option<u16> {
    let without_scheme = proxy_url.split_once("://")?.1;
    let host_port = without_scheme.split('/').next().unwrap_or_default();
    let (_, port) = host_port.rsplit_once(':')?;
    port.trim_matches(']')
        .parse::<u16>()
        .ok()
        .filter(|port| *port > 0)
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            return Some(value.to_string());
        }
    }
    None
}

fn bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| {
        value.as_bool().or_else(|| {
            value.as_str().map(|raw| {
                matches!(
                    raw.trim().to_ascii_lowercase().as_str(),
                    "1" | "true" | "yes" | "on"
                )
            })
        })
    })
}

fn u16_param(params: &Value, key: &str) -> Option<u16> {
    params.get(key).and_then(|value| {
        value
            .as_u64()
            .and_then(to_u16)
            .or_else(|| value.as_str().and_then(|raw| raw.parse::<u16>().ok()))
    })
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = std::collections::BTreeSet::<String>::new();
    let mut out = Vec::<PathBuf>::new();
    for path in paths {
        let key = path.to_string_lossy().to_string();
        if seen.insert(key) {
            out.push(path);
        }
    }
    out
}

fn sanitize_id(value: &str) -> String {
    let sanitized = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    if sanitized.is_empty() {
        "agent".to_string()
    } else {
        sanitized
    }
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '/' | '.' | ':' | '_' | '-' | ','))
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

fn display_path(path: PathBuf) -> String {
    path.to_string_lossy().to_string()
}

fn timestamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    format!("{}", millis)
}

fn home_dir() -> Option<PathBuf> {
    UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_test_dir(name: &str) -> PathBuf {
        env::temp_dir().join(format!("lico-proxy-bridge-{name}-{}", timestamp()))
    }

    #[test]
    fn detect_reads_mixed_port_and_tun_from_explicit_config() {
        let dir = temp_test_dir("detect");
        fs::create_dir_all(&dir).unwrap();
        let config = dir.join("verge.yaml");
        fs::write(
            &config,
            r#"
mixed-port: 7897
enable-process: true
find-process-mode: strict
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
"#,
        )
        .unwrap();

        let result = detect(&json!({"configPath": config.to_string_lossy()})).unwrap();

        assert_eq!(result["ok"], true);
        assert_eq!(result["proxy"]["mixedPort"], 7897);
        assert_eq!(result["detection"]["tun"]["enabled"], true);
        assert_eq!(result["detection"]["tun"]["findProcessMode"], "strict");
        assert_eq!(result["tunAssist"]["willModifyClashConfig"], false);
    }

    #[test]
    fn plan_generates_agent_wrappers_without_modifying_clash_config() {
        let state_root = temp_test_dir("plan").join("lico-client");
        let result = plan(&json!({
            "stateRoot": state_root.to_string_lossy(),
            "proxyUrl": "http://127.0.0.1:7897",
            "targets": "codex,kimi-code"
        }))
        .unwrap();

        assert_eq!(result["status"], "planned");
        assert_eq!(result["willModifyClashConfig"], false);
        let wrappers = result["wrappers"]["items"].as_array().unwrap();
        assert_eq!(wrappers.len(), 2);
        assert_eq!(wrappers[1]["target"], "kimi-code");
        assert_eq!(wrappers[1]["label"], "Kimi Code - CLI");
        assert!(
            result["tunAssist"]["yamlSnippet"]
                .as_str()
                .unwrap()
                .contains("PROCESS-NAME,codex")
        );
        assert!(
            result["tunAssist"]["yamlSnippet"]
                .as_str()
                .unwrap()
                .contains("PROCESS-NAME,kimi")
        );
    }

    #[test]
    fn kimi_code_bridge_does_not_alias_the_consumer_desktop_target() {
        assert_eq!(normalize_agent_id("kimi_code"), "kimi-code");
        assert_eq!(normalize_agent_id("kimicode"), "kimi-code");
        assert_eq!(agent_def("kimi-code").unwrap().label, "Kimi Code - CLI");
        assert!(agent_def("kimi").is_none());
        assert!(agent_def("moonshot").is_none());
    }

    #[test]
    fn apply_writes_managed_wrappers_and_rollback_removes_them() {
        let state_root = temp_test_dir("apply").join("lico-client");
        let apply_result = apply(&json!({
            "stateRoot": state_root.to_string_lossy(),
            "proxyUrl": "http://127.0.0.1:7897",
            "targets": "codex",
            "clientEnabled": true,
            "wrapperEnabled": true
        }))
        .unwrap();

        assert_eq!(apply_result["status"], "applied");
        let wrapper_path = PathBuf::from(
            apply_result["document"]["wrappers"]["items"][0]["path"]
                .as_str()
                .unwrap(),
        );
        assert!(wrapper_path.exists());
        let wrapper = fs::read_to_string(&wrapper_path).unwrap();
        assert!(wrapper.contains("HTTP_PROXY"));
        assert!(wrapper.contains("127.0.0.1:7897"));

        let rollback_result =
            rollback(&json!({"stateRoot": state_root.to_string_lossy()})).unwrap();
        assert_eq!(rollback_result["status"], "rolled_back");
        assert!(!wrapper_path.exists());
        assert_eq!(rollback_result["document"]["enabled"], false);
    }

    #[test]
    fn reject_non_loopback_proxy_urls() {
        let result = plan(&json!({"proxyUrl": "http://192.168.1.5:7897"}));
        assert!(result.is_err());
    }
}
