// Command dispatch with typed command definitions — replaces fragile prefix matching.
// Each sub-module registers its commands via register_* functions.
// execute_cli() dispatches through exact-path matching with rest-capture support.
//
// OTel Semantic Convention Fields (adoption baseline):
//   service.name, service.version
//   process.pid, process.command
//
// These fields SHOULD be emitted on CLI command lifecycle events.
// Adoption is incremental; new command paths should include them.

use anyhow::Result;
use serde_json::{Value, json};
use std::process;

mod agent_usage;
mod client_update;
mod connectors;
mod local_runtime;
mod mcp;
mod mobile;
mod model;
mod openclaw_gateway;
mod opencode_serve;
mod proxy_bridge;
mod secure_mesh;
mod skill;
mod snapshots;
mod state;
mod targets;

#[derive(Debug, PartialEq, Clone)]
pub enum CliExecution {
    Usage,
    Json(Value),
    Streamed,
}

type CommandFn = fn(&[String]) -> Result<CliExecution>;

// ─── Command Definition ────────────────────────────────────────────────────────

struct CommandDef {
    /// Literal path tokens that must match exactly (e.g. ["model", "profiles", "list"])
    path: &'static [&'static str],
    /// Required positional tokens after the path (e.g. ["snapshot-id"])
    required: &'static [&'static str],
    /// If true, capture all remaining args after path + required
    has_rest: bool,
    handler: CommandFn,
    help: &'static str,
}

impl CommandDef {
    fn matches(&self, args: &[String]) -> bool {
        if args.len() < self.path.len() {
            return false;
        }
        for (i, token) in self.path.iter().enumerate() {
            if args[i] != *token {
                return false;
            }
        }
        let offset = self.path.len() + self.required.len();
        if self.has_rest {
            // Rest commands match as long as path + required are satisfied
            args.len() >= offset
        } else {
            // Exact commands require exact arg count
            args.len() == offset
        }
    }
}

// ─── Command Table ─────────────────────────────────────────────────────────────

pub struct CommandTable {
    defs: Vec<CommandDef>,
}

impl CommandTable {
    pub fn new() -> Self {
        let mut table = Self { defs: Vec::new() };
        model::register_commands(&mut table);
        state::register_commands(&mut table);
        local_runtime::register_commands(&mut table);
        opencode_serve::register_commands(&mut table);
        openclaw_gateway::register_commands(&mut table);
        snapshots::register_commands(&mut table);
        agent_usage::register_commands(&mut table);
        client_update::register_commands(&mut table);
        connectors::register_commands(&mut table);
        mobile::register_commands(&mut table);
        proxy_bridge::register_commands(&mut table);
        secure_mesh::register_commands(&mut table);
        targets::register_commands(&mut table);
        mcp::register_commands(&mut table);
        skill::register_commands(&mut table);
        table
    }

    /// Register an exact-match command (no extra args beyond the path).
    pub fn register(&mut self, path: &'static [&'static str], handler: CommandFn) {
        self.defs.push(CommandDef {
            path,
            required: &[],
            has_rest: false,
            handler,
            help: "",
        });
    }

    /// Register a command that captures all remaining args (rest) after the path.
    pub fn register_rest(
        &mut self,
        path: &'static [&'static str],
        handler: CommandFn,
        help: &'static str,
    ) {
        self.defs.push(CommandDef {
            path,
            required: &[],
            has_rest: true,
            handler,
            help,
        });
    }

    /// Register a command with required positionals between the path and optional rest.
    #[allow(dead_code)]
    pub fn register_with_positionals(
        &mut self,
        path: &'static [&'static str],
        required: &'static [&'static str],
        handler: CommandFn,
        help: &'static str,
    ) {
        self.defs.push(CommandDef {
            path,
            required,
            has_rest: false,
            handler,
            help,
        });
    }

    /// Dispatch args to the first matching command handler.
    pub fn dispatch(&self, args: &[String]) -> Option<Result<CliExecution>> {
        for def in &self.defs {
            if def.matches(args) {
                return Some((def.handler)(args));
            }
        }
        None
    }

    /// Collect help text for all registered commands.
    pub fn help_text(&self) -> Vec<String> {
        let mut lines = Vec::new();
        for def in &self.defs {
            let path_str = def.path.join(" ");
            let req_str = if def.required.is_empty() {
                String::new()
            } else {
                format!(" <{}>", def.required.join("> <"))
            };
            let rest_str = if def.has_rest { " [...]" } else { "" };
            let help = if def.help.is_empty() {
                String::new()
            } else {
                format!("  — {}", def.help)
            };
            lines.push(format!("  {}{}{}{}", path_str, req_str, rest_str, help));
        }
        lines
    }
}

fn cli_dispatch_command_name(args: &[String]) -> String {
    args.first()
        .map(String::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("help")
        .to_string()
}

fn cli_dispatch_semantic_fields(args: &[String]) -> Value {
    json!({
        "service.name": "lico-client-native",
        "service.version": env!("CARGO_PKG_VERSION"),
        "process.pid": process::id(),
        "process.command": "lico-client",
        "lico.operation.id": "client.cli.dispatch",
        "lico.command.name": cli_dispatch_command_name(args),
    })
}

fn emit_cli_dispatch_observability(fields: &Value, status: &str) {
    if std::env::var("LICO_CLIENT_CLI_OBSERVABILITY")
        .ok()
        .as_deref()
        != Some("stderr-json")
    {
        return;
    }
    eprintln!(
        "{}",
        json!({
            "event": "client.cli.dispatch",
            "status": status,
            "fields": fields,
        })
    );
}

// ─── CLI Entry Point ───────────────────────────────────────────────────────────

/// The main CLI dispatch entry point — compatible with existing tests.
pub fn execute_cli(args: Vec<String>) -> Result<CliExecution> {
    if args.is_empty()
        || matches!(
            args.first().map(String::as_str),
            Some("--help" | "-h" | "help")
        )
    {
        let semantic_fields = cli_dispatch_semantic_fields(&args);
        emit_cli_dispatch_observability(&semantic_fields, "usage");
        let table = CommandTable::new();
        eprintln!("LicoLite CLI — available commands:");
        for line in table.help_text() {
            eprintln!("{}", line);
        }
        return Ok(CliExecution::Usage);
    }

    let table = CommandTable::new();
    let semantic_fields = cli_dispatch_semantic_fields(&args);
    match table.dispatch(&args) {
        Some(result) => {
            let status = if result.is_ok() { "handled" } else { "failed" };
            emit_cli_dispatch_observability(&semantic_fields, status);
            result
        }
        None => {
            emit_cli_dispatch_observability(&semantic_fields, "unknown");
            let attempted = args.join(" ");
            eprintln!("Unknown command: {}", attempted);
            eprintln!("Run 'lico help' for available commands.");
            eprintln!("Closest matches:");
            for def in &table.defs {
                let cmd_path = def.path.join(" ");
                if cmd_path.starts_with(&args[0]) {
                    eprintln!("  {}", cmd_path);
                }
            }
            Ok(CliExecution::Usage)
        }
    }
}

// ─── Parameter Parsing ─────────────────────────────────────────────────────────

/// Parse --flag value pairs and bare positionals into a JSON object.
pub fn cli_params(args: &[String]) -> Value {
    let mut params = serde_json::Map::new();
    let mut positionals = Vec::<Value>::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some(raw_key) = arg.strip_prefix("--") {
            let key = cli_param_key(raw_key);
            if let Some(value) = args.get(index + 1).filter(|value| !value.starts_with("--")) {
                params.insert(key, json!(value));
                index += 2;
            } else {
                params.insert(key, json!(true));
                index += 1;
            }
            continue;
        }
        positionals.push(json!(arg));
        index += 1;
    }
    if !positionals.is_empty() {
        if !params.contains_key("target") {
            if let Some(target) = positionals.first().and_then(Value::as_str) {
                params.insert("target".to_string(), json!(target));
            }
        }
        params.insert("positionals".to_string(), Value::Array(positionals));
    }
    Value::Object(params)
}

fn cli_param_key(raw: &str) -> String {
    let mut out = String::new();
    let mut uppercase_next = false;
    for ch in raw.chars() {
        if ch == '-' || ch == '_' {
            uppercase_next = true;
            continue;
        }
        if uppercase_next {
            out.extend(ch.to_uppercase());
            uppercase_next = false;
        } else {
            out.push(ch);
        }
    }
    out
}

pub fn parse_json_arg(value: &str) -> Value {
    serde_json::from_str(value).unwrap_or_else(|_| json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_dispatch_semantics_include_otel_field_names() {
        let fields = cli_dispatch_semantic_fields(&["targets".to_string(), "scan".to_string()]);

        assert_eq!(fields["service.name"], "lico-client-native");
        assert_eq!(fields["service.version"], env!("CARGO_PKG_VERSION"));
        assert_eq!(fields["process.command"], "lico-client");
        assert!(fields["process.pid"].as_u64().unwrap_or_default() > 0);
        assert_eq!(fields["lico.operation.id"], "client.cli.dispatch");
        assert_eq!(fields["lico.command.name"], "targets");
    }
}
