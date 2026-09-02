//! Native client CLI and bounded stdio RPC entry point.

use anyhow::Result;
use serde_json::{Value, json};
use std::{
    env,
    io::{self, BufRead, Write},
    panic::{self, AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{Arc, Mutex, atomic::AtomicU64},
};

#[path = "licoup/conversation_host.rs"]
mod conversation_host;
#[path = "licoup/presentation.rs"]
mod presentation;
#[path = "licoup/private_stdin_json.rs"]
mod private_stdin_json;
#[path = "licoup/stdio_rpc.rs"]
mod stdio_rpc;

use presentation::{print_json, print_usage};
use private_stdin_json::materialize_private_stdin_json;
use stdio_rpc::{execute_rpc_cli, serve_stdio_rpc};

// Keep the public CLI boundary token explicit here: the source-boundary gate
// verifies that malformed or substituted protocols cannot silently enter the
// native stdio request parser.
const STDIO_RPC_PROTOCOL: &str = "licoup.stdio.v1";
const STDIO_RPC_MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const STDIO_RPC_MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const STDIO_RPC_MAX_ID_BYTES: usize = 128;
const STDIO_RPC_MAX_ARGS: usize = 4_097;
fn main() -> Result<()> {
    env_logger::Builder::from_default_env()
        .target(env_logger::Target::Stderr)
        .init();
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.as_slice() == ["rpc", "stdio"] {
        // The RPC wire response is already fail-closed and redacted. Keep the
        // process panic hook equally bounded so a panic payload cannot leak a
        // path, command argument, or secret to the parent application's logs.
        panic::set_hook(Box::new(|_| {
            eprintln!("licoup RPC command terminated unexpectedly");
        }));
        // The desktop client spawns this bridge lane during normal startup,
        // so it owns starting the persistent conversation host — and with it
        // the default-enabled, supervised Subagent MCP service — without
        // waiting for a first conversation RPC.
        conversation_host::ensure_host_for_desktop_start();
        let stdin = io::stdin();
        return serve_stdio_rpc(stdin.lock(), io::stdout(), execute_rpc_cli).map(|_| ());
    }
    if args.as_slice() == ["rpc", "conversation"] {
        panic::set_hook(Box::new(|_| {
            eprintln!("licoup conversation RPC proxy terminated unexpectedly");
        }));
        return conversation_host::serve_proxy();
    }
    if args.as_slice() == ["rpc", "conversation-host"] {
        panic::set_hook(Box::new(|_| {
            eprintln!("licoup conversation RPC host terminated unexpectedly");
        }));
        return conversation_host::serve_host();
    }
    let args = materialize_private_stdin_json(args, io::stdin().lock())?;
    match licoup_native::ffi::commands::execute_cli(args)? {
        licoup_native::ffi::commands::CliExecution::Usage => print_usage(),
        licoup_native::ffi::commands::CliExecution::Json(value) => print_json(&value),
        licoup_native::ffi::commands::CliExecution::Streamed => {}
    }
    Ok(())
}

#[cfg(test)]
#[path = "licoup/tests.rs"]
mod tests;
