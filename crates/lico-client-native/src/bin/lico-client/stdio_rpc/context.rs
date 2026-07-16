use super::*;

pub(crate) fn execute_rpc_cli(
    args: Vec<String>,
    portable_data_dir: Option<PathBuf>,
) -> Result<lico_client_native::ffi::commands::CliExecution> {
    let _portable_data_dir = PortableDataDirOverrideGuard::set(portable_data_dir);
    lico_client_native::ffi::commands::execute_cli(args)
}

pub(crate) struct PortableDataDirOverrideGuard {
    previous: Option<PathBuf>,
}

impl PortableDataDirOverrideGuard {
    pub(crate) fn set(path: Option<PathBuf>) -> Self {
        let previous = lico_client_native::platform::paths::set_portable_data_dir_override(path);
        Self { previous }
    }
}

impl Drop for PortableDataDirOverrideGuard {
    fn drop(&mut self) {
        lico_client_native::platform::paths::set_portable_data_dir_override(self.previous.take());
    }
}
