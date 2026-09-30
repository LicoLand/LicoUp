use licoup_client_state::ClientStateStore;
use licoup_foundation::platform::file_security::{
    atomic_write_private_text_bounded, create_private_state_marker, read_private_state_marker,
    remove_private_state_marker,
};
use anyhow::{Result, anyhow};
use std::path::PathBuf;

const AUTHORITY_CHALLENGE_MARKER_MAX_BYTES: usize = 64 * 1024;

fn authority_challenge_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-kt-authority-config.pending"))
}

pub(super) fn read_authority_challenge_marker() -> Result<Option<Vec<u8>>> {
    read_private_state_marker(&authority_challenge_path()?)
}

pub(super) fn create_authority_challenge_marker(value: &[u8]) -> Result<()> {
    create_private_state_marker(&authority_challenge_path()?, value)
}

pub(super) fn replace_authority_challenge_marker(value: &[u8]) -> Result<()> {
    let text = std::str::from_utf8(value)
        .map_err(|_| anyhow!("secure mesh KT authority challenge marker is not UTF-8"))?;
    atomic_write_private_text_bounded(
        &authority_challenge_path()?,
        text,
        AUTHORITY_CHALLENGE_MARKER_MAX_BYTES,
    )
}

pub(super) fn remove_authority_challenge_marker() -> Result<bool> {
    remove_private_state_marker(&authority_challenge_path()?)
}
