use super::*;

pub(crate) enum StdioRpcLine {
    Eof,
    Request(Vec<u8>),
    TooLarge,
}

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
    Shutdown,
}

pub(crate) struct StdioRpcRequest {
    pub(crate) id: String,
    pub(crate) workflow_id: String,
    pub(crate) method: StdioRpcMethod,
}

pub(crate) struct StdioRpcRequestError {
    pub(crate) id: Option<String>,
    pub(crate) workflow_id: Option<String>,
    pub(crate) code: &'static str,
}
