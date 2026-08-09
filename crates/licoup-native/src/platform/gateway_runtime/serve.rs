//! Single-process Gateway Runtime: LLM Gateway (lower) + Communication Channels (upper).

use crate::core::secure_mesh_secret_store::SecretBytes;
use crate::domain::llm_api_key_vault::GatewayCredentialSlot;
use crate::domain::llm_gateway::CompiledGateway;
use crate::platform::gateway_runtime::channels::telegram::{
    BindingStore, LiveBotTransport, RuntimeConfig, clear_ready, load_bot_token, run_channel_loop,
};
use crate::platform::llm_gateway_credentials_control::serve_credentials_control;
use crate::platform::llm_gateway_inventory_control::{
    control_socket_path as inventory_control_socket_path, load_inventory_overlay_if_present,
    overlay_path as inventory_overlay_path, serve_inventory_control,
};
use crate::platform::llm_gateway_server::serve_loopback;
use crate::platform::llm_gateway_usage::GatewayUsageRecorder;
use anyhow::{Result, anyhow};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

pub struct GatewayServeArgs {
    pub listener: TcpListener,
    pub gateway: Arc<CompiledGateway>,
    pub credentials: Arc<GatewayCredentialSlot>,
    pub client_token: Arc<SecretBytes>,
    pub usage: Arc<GatewayUsageRecorder>,
    pub credentials_control: Option<PathBuf>,
    pub enable_channels: bool,
    pub telegram_api_root: Option<String>,
}

/// Serve both layers until `stop` is set. Channel failures are isolated: the
/// LLM loopback layer keeps serving when Telegram is unconfigured or exits.
pub fn serve_gateway_runtime(args: GatewayServeArgs, stop: Arc<AtomicBool>) -> Result<()> {
    let _ = clear_ready();
    // Prefer the last hot-applied readiness overlay so soft-restart and boot
    // see the same verified set as an in-process inventory reload.
    if let Some(state_root) = args
        .credentials_control
        .as_ref()
        .and_then(|path| path.parent())
    {
        let _ = load_inventory_overlay_if_present(&inventory_overlay_path(state_root));
    }
    let http_stop = Arc::clone(&stop);
    let listener = args.listener;
    let gateway = Arc::clone(&args.gateway);
    let credentials = Arc::clone(&args.credentials);
    let client_token = Arc::clone(&args.client_token);
    let usage = Arc::clone(&args.usage);
    let http = thread::Builder::new()
        .name("gateway-llm".into())
        .spawn(move || {
            serve_loopback(
                listener,
                gateway,
                http_stop,
                credentials,
                client_token,
                usage,
            )
            .map_err(|error| anyhow!("llm_layer_failed:{error:?}"))
        })
        .map_err(|_| anyhow!("gateway_runtime_spawn_failed"))?;

    let inventory_socket = args
        .credentials_control
        .as_ref()
        .and_then(|path| path.parent().map(inventory_control_socket_path));

    let control = match args.credentials_control {
        Some(path) => {
            let control_stop = Arc::clone(&stop);
            let control_credentials = Arc::clone(&args.credentials);
            Some(
                thread::Builder::new()
                    .name("gateway-credentials-control".into())
                    .spawn(move || {
                        let _ = serve_credentials_control(path, control_credentials, control_stop);
                    })
                    .map_err(|_| anyhow!("gateway_runtime_spawn_failed"))?,
            )
        }
        None => None,
    };

    let inventory_control = match inventory_socket {
        Some(path) => {
            let control_stop = Arc::clone(&stop);
            Some(
                thread::Builder::new()
                    .name("gateway-inventory-control".into())
                    .spawn(move || {
                        let _ = serve_inventory_control(path, control_stop);
                    })
                    .map_err(|_| anyhow!("gateway_runtime_spawn_failed"))?,
            )
        }
        None => None,
    };

    let channel_stop = Arc::clone(&stop);
    let channel = if args.enable_channels {
        match load_bot_token()? {
            Some(token) => {
                let api_root = args.telegram_api_root.clone();
                Some(
                    thread::Builder::new()
                        .name("gateway-channel-telegram".into())
                        .spawn(move || run_telegram_channel(token, api_root, channel_stop))
                        .map_err(|_| anyhow!("gateway_runtime_spawn_failed"))?,
                )
            }
            None => None,
        }
    } else {
        None
    };

    // Block on the LLM layer (authoritative process lifetime).
    let http_result = http
        .join()
        .map_err(|_| anyhow!("gateway_runtime_join_failed"))?;
    stop.store(true, Ordering::SeqCst);
    if let Some(handle) = control {
        let _ = handle.join();
    }
    if let Some(handle) = inventory_control {
        let _ = handle.join();
    }
    if let Some(handle) = channel {
        let _ = handle.join();
    }
    let _ = clear_ready();
    http_result
}

fn run_telegram_channel(
    token: String,
    api_root: Option<String>,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    let transport = LiveBotTransport::new(token, api_root.as_deref());
    let store = BindingStore::open_default()?;
    match run_channel_loop(
        transport,
        store,
        RuntimeConfig {
            poll_timeout_secs: 25,
            stop: Arc::clone(&stop),
        },
    ) {
        Ok(_identity) => Ok(()),
        Err(error) => {
            // Do not tear down the LLM layer; park until runtime stop.
            let _ = clear_ready();
            let _ = error;
            while !stop.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_secs(2));
            }
            Ok(())
        }
    }
}
