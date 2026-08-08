use licoup_native::{
    domain::llm_api_key_vault::{GatewayCredentialHandoff, GatewayCredentialLease},
    domain::llm_gateway::{CompiledGateway, GatewayConfig},
    platform::llm_api_key_vault::PlatformLlmApiKeyVault,
    platform::llm_gateway_server::{bind_address, serve_loopback},
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
const MAX_ARGUMENTS: usize = 8;
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
    usage: PathBuf,
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
        println!(r#"{{"ok":true,"schemaVersion":"licoup.llm-gateway-check.v1"}}"#);
        return Ok(());
    }
    let credentials = Arc::new(match arguments.credentials_fd {
        Some(fd) => {
            let vault = PlatformLlmApiKeyVault::production().map_err(|_| ())?;
            vault
                .gateway_lease_from_handoff(read_handoff(fd)?)
                .map_err(|_| ())?
        }
        None => GatewayCredentialLease::disconnected(),
    });
    let listener = TcpListener::bind(bind_address(arguments.port)).map_err(|_| ())?;
    let usage = Arc::new(GatewayUsageRecorder::open(arguments.usage).map_err(|_| ())?);
    serve_loopback(
        listener,
        gateway,
        Arc::new(AtomicBool::new(false)),
        credentials,
        usage,
    )
    .map_err(|_| ())
}

/// Read one credential handoff from an inherited pipe fd. The buffer is
/// scoped to this function so it drops promptly once the handoff is parsed;
/// the kernel pipe buffer is the only other copy and the parent zeroizes its
/// own secret material through SecretBytes drop.
#[cfg(unix)]
fn read_handoff(fd: u32) -> Result<GatewayCredentialHandoff, ()> {
    use std::io::Read as _;
    use std::os::fd::{FromRawFd as _, RawFd};
    let mut pipe = unsafe { fs::File::from_raw_fd(fd as RawFd) };
    let mut buffer = Vec::new();
    // Read one byte past the cap so an oversize stream fails closed instead of
    // being silently truncated by `take`.
    pipe.by_ref()
        .take(MAX_HANDOFF_BYTES as u64 + 1)
        .read_to_end(&mut buffer)
        .map_err(|_| ())?;
    if buffer.len() > MAX_HANDOFF_BYTES {
        return Err(());
    }
    GatewayCredentialHandoff::from_json(&buffer).map_err(|_| ())
}

/// The handoff fd is a unix launch mechanism; its presence anywhere else
/// fails closed.
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
    let mut usage = None;
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
            "--credentials-fd" if credentials_fd.is_none() => {
                index += 1;
                credentials_fd = Some(
                    raw.get(index)
                        .and_then(|value| value.parse::<u32>().ok())
                        .ok_or(())?,
                );
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
        usage,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_are_closed_and_require_an_absolute_config() {
        assert!(parse_arguments(&[]).is_err());
        assert!(parse_arguments(&["--config".into(), "relative.json".into()]).is_err());
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--unknown".into(),
            ])
            .is_err()
        );
        assert_eq!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--usage".into(),
                "/synthetic/usage.json".into(),
                "--port".into(),
                "18080".into(),
                "--check".into(),
            ])
            .unwrap(),
            Arguments {
                config: PathBuf::from("/synthetic/gateway.json"),
                port: 18_080,
                check_only: true,
                credentials_fd: None,
                usage: PathBuf::from("/synthetic/usage.json"),
            }
        );
    }

    #[test]
    fn credentials_fd_parses_once_and_rejects_garbage() {
        assert_eq!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--usage".into(),
                "/synthetic/usage.json".into(),
                "--credentials-fd".into(),
                "3".into(),
            ])
            .unwrap(),
            Arguments {
                config: PathBuf::from("/synthetic/gateway.json"),
                port: DEFAULT_PORT,
                check_only: false,
                credentials_fd: Some(3),
                usage: PathBuf::from("/synthetic/usage.json"),
            }
        );
        // A repeated flag is rejected.
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--usage".into(),
                "/synthetic/usage.json".into(),
                "--credentials-fd".into(),
                "3".into(),
                "--credentials-fd".into(),
                "4".into(),
            ])
            .is_err()
        );
        // A non-numeric fd is rejected.
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--usage".into(),
                "/synthetic/usage.json".into(),
                "--credentials-fd".into(),
                "three".into(),
            ])
            .is_err()
        );
        // `--check` combined with the handoff flag still parses.
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--usage".into(),
                "/synthetic/usage.json".into(),
                "--credentials-fd".into(),
                "3".into(),
                "--check".into(),
            ])
            .unwrap()
            .check_only
        );
    }

    #[test]
    fn zero_port_and_duplicate_flags_are_rejected() {
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/gateway.json".into(),
                "--port".into(),
                "0".into(),
            ])
            .is_err()
        );
        assert!(
            parse_arguments(&[
                "--config".into(),
                "/synthetic/a.json".into(),
                "--config".into(),
                "/synthetic/b.json".into(),
            ])
            .is_err()
        );
    }
}
