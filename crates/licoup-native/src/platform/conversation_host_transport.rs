//! Private local transport shared by the Conversation host and admitted native
//! clients. The endpoint name is an opaque token stored below the client-owned
//! portable data root; no runtime path or process fact crosses the RPC wire.

use anyhow::{Context, Result, anyhow};
use interprocess::local_socket::{GenericNamespaced, Stream, ToNsName as _, traits::Stream as _};
use std::{
    fs,
    io::{self, Write},
    path::Path,
};

pub const STDIO_RPC_PROTOCOL: &str = "licoup.stdio.v1";

pub fn endpoint_name() -> Result<interprocess::local_socket::Name<'static>> {
    let root = super::paths::portable_data_dir()?;
    endpoint_name_for_root(&root)
}

fn existing_endpoint_name() -> Result<interprocess::local_socket::Name<'static>> {
    let root = super::paths::portable_data_dir_read_only()?;
    existing_endpoint_name_for_root(&root)
}

fn read_endpoint_token(token_path: &Path) -> Result<String> {
    let token = super::file_security::read_existing_private_text_bounded(token_path, 64)?
        .ok_or_else(|| anyhow!("conversation endpoint unavailable"))?;
    let token = token.trim();
    if token.len() != 32 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(anyhow!("conversation endpoint unavailable"));
    }
    Ok(token.to_owned())
}

fn endpoint_name_from_token(token: &str) -> Result<interprocess::local_socket::Name<'static>> {
    format!("licoup-conversation-{token}")
        .to_ns_name::<GenericNamespaced>()
        .context("conversation endpoint unavailable")
}

fn existing_endpoint_name_for_root(
    root: &Path,
) -> Result<interprocess::local_socket::Name<'static>> {
    let token_path = root
        .join("client-state")
        .join("conversation-runtime")
        .join("endpoint-token");
    endpoint_name_from_token(&read_endpoint_token(&token_path)?)
}

pub fn endpoint_name_for_root(root: &Path) -> Result<interprocess::local_socket::Name<'static>> {
    let endpoint_root = root.join("client-state").join("conversation-runtime");
    super::file_security::ensure_private_dir(&endpoint_root)?;
    let token_path = endpoint_root.join("endpoint-token");
    let token = match read_endpoint_token(&token_path) {
        Ok(token) => token,
        Err(_) => {
            let token = uuid::Uuid::new_v4().simple().to_string();
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&token_path)
            {
                Ok(mut file) => {
                    file.write_all(token.as_bytes())?;
                    file.sync_all()?;
                    super::file_security::harden_private_path(&token_path)?;
                    token
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    read_endpoint_token(&token_path)?
                }
                Err(_) => return Err(anyhow!("conversation endpoint unavailable")),
            }
        }
    };
    endpoint_name_from_token(&token)
}

pub fn connect() -> io::Result<Stream> {
    let name = endpoint_name().map_err(io::Error::other)?;
    Stream::connect(name)
}

/// Connect only when the host has already published its private endpoint.
/// Unlike `connect`, this read-only lookup never creates a directory or token.
pub fn connect_existing() -> io::Result<Stream> {
    let name = existing_endpoint_name().map_err(io::Error::other)?;
    Stream::connect(name)
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

    #[test]
    fn existing_endpoint_lookup_never_creates_missing_state() {
        let root = std::env::temp_dir().join(format!(
            "licoup-conversation-endpoint-read-only-test-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = super::super::paths::set_portable_data_dir_override(Some(root.clone()));
        let missing = existing_endpoint_name();
        super::super::paths::set_portable_data_dir_override(previous);
        assert!(missing.is_err());
        assert!(!root.exists());

        let created = endpoint_name_for_root(&root).unwrap();
        let observed = existing_endpoint_name_for_root(&root).unwrap();
        assert_eq!(created, observed);
        fs::remove_dir_all(root).unwrap();
    }
}
