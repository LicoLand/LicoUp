use super::registry::runtime_driver_profile;
use super::{RuntimeAdapter, RuntimeAdapterError};
#[cfg(test)]
use sha2::{Digest, Sha256};
use std::fs;
#[cfg(test)]
use std::fs::{File, Metadata};
#[cfg(test)]
use std::io::Read;
use std::path::Path;

#[cfg(test)]
pub(crate) fn runtime_artifact_digest(executable: &Path) -> Option<String> {
    let mut file = File::open(executable).ok()?;
    let opened_before = file.metadata().ok()?;
    if !opened_before.is_file() {
        return None;
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = loop {
            match file.read(&mut buffer) {
                Ok(read) => break read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return None,
            }
        };
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let opened_after = file.metadata().ok()?;
    let current = File::open(executable).ok()?;
    let current_metadata = current.metadata().ok()?;
    if !same_runtime_artifact(&opened_before, &opened_after)
        || !same_runtime_artifact(&opened_after, &current_metadata)
    {
        return None;
    }
    Some(format!("sha256:{:x}", hasher.finalize()))
}

pub(super) fn runtime_executable(
    adapter: RuntimeAdapter,
    requested: &str,
) -> Result<String, RuntimeAdapterError> {
    if runtime_driver_profile(adapter.id()).is_none() {
        return Err(RuntimeAdapterError::RuntimeProfileUnavailable);
    }
    let requested_path = Path::new(requested);
    if !requested_path.is_absolute() {
        // Group Conversation turns intentionally persist only the Agent id,
        // never an executable path. When such a turn carries the adapter's
        // default command, recover the exact executable from the same native
        // discovery authority used by one-to-one chat. This is especially
        // important for product-bundled runtimes such as Kilo Code, whose
        // official CLI may live inside an editor extension instead of PATH.
        if requested == adapter.default_binary()
            && let Some(discovered) =
                crate::domain::targets::available_runtime_executable(adapter.id())
        {
            return discovered
                .to_str()
                .map(str::to_string)
                .ok_or(RuntimeAdapterError::ExecutableUnavailable);
        }
        return Ok(requested.to_string());
    }
    let canonical =
        fs::canonicalize(requested_path).map_err(|_| RuntimeAdapterError::ExecutableUnavailable)?;
    if !canonical.is_file() {
        return Err(RuntimeAdapterError::ExecutableUnavailable);
    }
    canonical
        .to_str()
        .map(str::to_string)
        .ok_or(RuntimeAdapterError::ExecutableUnavailable)
}

#[cfg(unix)]
#[cfg(test)]
fn same_runtime_artifact(left: &Metadata, right: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
}

#[cfg(not(unix))]
#[cfg(test)]
fn same_runtime_artifact(left: &Metadata, right: &Metadata) -> bool {
    left.len() == right.len()
        && left.modified().ok() == right.modified().ok()
        && left.permissions().readonly() == right.permissions().readonly()
}
