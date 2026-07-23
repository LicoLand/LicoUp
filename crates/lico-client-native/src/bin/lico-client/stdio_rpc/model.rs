use super::*;
use lico_client_native::ffi::generated::client_state::{
    ClientStateGetRequest, ClientStateSetRequest,
};

pub(crate) enum StdioRpcLine {
    Eof,
    Request(Vec<u8>),
    TooLarge,
}

#[derive(Debug)]
pub(crate) enum StdioRpcMethod {
    Execute {
        args: Vec<String>,
        portable_data_dir: Option<PathBuf>,
    },
    Conversation {
        operation: String,
        params: Value,
        portable_data_dir: Option<PathBuf>,
    },
    Catalog {
        operation: String,
        params: Value,
        portable_data_dir: Option<PathBuf>,
    },
    StateGet {
        request: ClientStateGetRequest,
        portable_data_dir: Option<PathBuf>,
    },
    StateSet {
        request: ClientStateSetRequest,
        portable_data_dir: Option<PathBuf>,
    },
    Orchestrator {
        params: Value,
    },
    Shutdown,
}

#[derive(Debug)]
pub(crate) struct StdioRpcRequest {
    pub(crate) id: String,
    pub(crate) workflow_id: String,
    pub(crate) method: StdioRpcMethod,
}

#[derive(Debug)]
pub(crate) struct StdioRpcRequestError {
    pub(crate) id: Option<String>,
    pub(crate) workflow_id: Option<String>,
    pub(crate) code: &'static str,
}
