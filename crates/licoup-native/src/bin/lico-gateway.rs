//! Unified Gateway Runtime: LLM Gateway (lower) + Communication Channels (upper).

use licoup_native::{
    domain::llm_api_key_vault::{GatewayCredentialHandoff, GatewayCredentialSlot},
    domain::llm_gateway::{CompiledGateway, GatewayConfig},
    platform::gateway_runtime::{GatewayServeArgs, serve_gateway_runtime},
    platform::llm_api_key_vault::PlatformLlmApiKeyVault,
    platform::llm_gateway_client_auth,
    platform::llm_gateway_server::bind_address,
    platform::llm_gateway_usage::GatewayUsageRecorder,
};
use std::{
    env, fs,
    net::TcpListener,
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{Arc, atomic::AtomicBool},
};

const DEFAULT_PORT: u16 = 15_722;
const MAX_ARGUMENTS: usize = 12;
const MAX_ARGUMENT_BYTES: usize = 8 * 1024;
const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
#[cfg(unix)]
const MAX_HANDOFF_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Eq, PartialEq)]
struct Arguments {
    config: PathBuf,
    port: u16,
    check_only: bool,
    credentials_fd: Option<u32>,
    credentials_control: Option<PathBuf>,
    client_token_file: Option<PathBuf>,
    usage: PathBuf,
    disable_channels: bool,
}

fn main() -> ExitCode {
    match run(env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(()) => ExitCode::FAILURE,
    }
}

fn run(raw: Vec<String>) -> Result<(), ()> {
    let arguments = parse_arguments(&raw)?;
    let config = load_config(&arguments.config)?;
    let gateway = Arc::new(CompiledGateway::compile(config).map_err(|_| ())?);
    if arguments.check_only {
        println!(
            r#"{{"ok":true,"schemaVersion":"licoup.gateway-runtime-check.v1","layers":["llm"]}}"#
        );
        return Ok(());
    }
    let credentials = Arc::new(match arguments.credentials_fd {
        Some(fd) => {
            let vault = PlatformLlmApiKeyVault::production().map_err(|_| ())?;
            GatewayCredentialSlot::new(
                vault
                    .gateway_lease_from_handoff(read_handoff(fd)?)
                    .map_err(|_| ())?,
            )
        }
        None => GatewayCredentialSlot::disconnected(),
    });
    let client_token = Arc::new(
        llm_gateway_client_auth::read_token(arguments.client_token_file.as_deref().ok_or(())?)
            .map_err(|_| ())?,
    );
    let listener = TcpListener::bind(bind_address(arguments.port)).map_err(|_| ())?;
    let usage = Arc::new(GatewayUsageRecorder::open(arguments.usage).map_err(|_| ())?);
    let stop = Arc::new(AtomicBool::new(false));
    let api_root = env::var("TELEGRAM_API_ROOT").ok();
    serve_gateway_runtime(
        GatewayServeArgs {
            listener,
            gateway,
            credentials,
            client_token,
            usage,
            credentials_control: arguments.credentials_control,
            enable_channels: !arguments.disable_channels,
            telegram_api_root: api_root,
        },
        stop,
    )
    .map_err(|_| ())
}

#[cfg(unix)]
fn read_handoff(fd: u32) -> Result<GatewayCredentialHandoff, ()> {
    use std::io::Read as _;
    use std::os::fd::{FromRawFd as _, RawFd};
    let mut pipe = unsafe { fs::File::from_raw_fd(fd as RawFd) };
    let mut buffer = Vec::new();
    pipe.by_ref()
        .take(MAX_HANDOFF_BYTES as u64 + 1)
        .read_to_end(&mut buffer)
        .map_err(|_| ())?;
    if buffer.len() > MAX_HANDOFF_BYTES {
        return Err(());
    }
    GatewayCredentialHandoff::from_json(&buffer).map_err(|_| ())
}

#[cfg(not(unix))]
fn read_handoff(_fd: u32) -> Result<GatewayCredentialHandoff, ()> {
    Err(())
}

fn parse_arguments(raw: &[String]) -> Result<Arguments, ()> {
    if raw.len() > MAX_ARGUMENTS || raw.iter().map(String::len).sum::<usize>() > MAX_ARGUMENT_BYTES
    {
        return Err(());
    }
    let mut config = None;
    let mut port = DEFAULT_PORT;
    let mut check_only = false;
    let mut credentials_fd = None;
    let mut credentials_control = None;
    let mut client_token_file = None;
    let mut usage = None;
    let mut disable_channels = false;
    let mut index = 0;
    while index < raw.len() {
        match raw[index].as_str() {
            "--config" if config.is_none() => {
                index += 1;
                config = raw.get(index).map(PathBuf::from);
                if config.is_none() {
                    return Err(());
                }
            }
            "--port" => {
                index += 1;
                port = raw
                    .get(index)
                    .and_then(|value| value.parse().ok())
                    .ok_or(())?;
                if port == 0 {
                    return Err(());
                }
            }
            "--check" if !check_only => check_only = true,
            "--disable-channels" if !disable_channels => disable_channels = true,
            "--credentials-fd" if credentials_fd.is_none() => {
                index += 1;
                credentials_fd = Some(
                    raw.get(index)
                        .and_then(|value| value.parse::<u32>().ok())
                        .ok_or(())?,
                );
            }
            "--credentials-control" if credentials_control.is_none() => {
                index += 1;
                credentials_control = raw.get(index).map(PathBuf::from);
                if credentials_control
                    .as_ref()
                    .is_none_or(|path| !path.is_absolute())
                {
                    return Err(());
                }
            }
            "--client-token-file" if client_token_file.is_none() => {
                index += 1;
                client_token_file = raw.get(index).map(PathBuf::from);
                if client_token_file
                    .as_ref()
                    .is_none_or(|path| !path.is_absolute())
                {
                    return Err(());
                }
            }
            "--usage" if usage.is_none() => {
                index += 1;
                usage = raw.get(index).map(PathBuf::from);
                if usage.as_ref().is_none_or(|path| !path.is_absolute()) {
                    return Err(());
                }
            }
            _ => return Err(()),
        }
        index += 1;
    }
    let config = config.ok_or(())?;
    if !config.is_absolute() {
        return Err(());
    }
    let usage = usage.ok_or(())?;
    Ok(Arguments {
        config,
        port,
        check_only,
        credentials_fd,
        credentials_control,
        client_token_file,
        usage,
        disable_channels,
    })
}

fn load_config(path: &Path) -> Result<GatewayConfig, ()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| ())?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > MAX_CONFIG_BYTES {
        return Err(());
    }
    let bytes = fs::read(path).map_err(|_| ())?;
    serde_json::from_slice(&bytes).map_err(|_| ())
}
