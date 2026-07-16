//! Native client CLI and bounded stdio RPC entry point.

use anyhow::Result;
use serde_json::{Value, json};
use std::{
    env,
    io::{self, BufRead, Write},
    panic::{self, AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

#[path = "lico-client/presentation.rs"]
mod presentation;
#[path = "lico-client/stdio_rpc.rs"]
mod stdio_rpc;

use presentation::{print_json, print_usage};
use stdio_rpc::{execute_rpc_cli, serve_stdio_rpc};

const STDIO_RPC_PROTOCOL: &str = "lico-client.stdio.v1";
const STDIO_RPC_MAX_REQUEST_BYTES: usize = 16 * 1024 * 1024;
const STDIO_RPC_MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const STDIO_RPC_MAX_ID_BYTES: usize = 128;
const STDIO_RPC_MAX_ARGS: usize = 256;

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
            eprintln!("lico-client RPC command terminated unexpectedly");
        }));
        let stdin = io::stdin();
        return serve_stdio_rpc(stdin.lock(), io::stdout(), execute_rpc_cli).map(|_| ());
    }
    match lico_client_native::ffi::commands::execute_cli(args)? {
        lico_client_native::ffi::commands::CliExecution::Usage => print_usage(),
        lico_client_native::ffi::commands::CliExecution::Json(value) => print_json(&value),
        lico_client_native::ffi::commands::CliExecution::Streamed => {}
    }
    Ok(())
}

#[cfg(test)]
#[path = "lico-client/tests.rs"]
mod tests;
