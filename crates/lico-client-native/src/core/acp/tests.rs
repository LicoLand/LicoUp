use super::*;
use std::path::PathBuf;

mod codec;
mod requests;
mod responses;

fn client() -> AcpImplementation {
    AcpImplementation::new("lico-arc", "test").title("Lico Arc")
}

fn absolute_test_path() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        PathBuf::from(r"C:\workspace\project")
    }
    #[cfg(not(target_os = "windows"))]
    {
        PathBuf::from("/workspace/project")
    }
}
