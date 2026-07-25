use super::super::*;
use licoup_native::platform::{
    orchestrator_control_plane::build_desktop_orchestrator_request,
    orchestrator_ipc::{OrchestratorIpcClient, OrchestratorIpcReceipt},
    orchestrator_service::default_orchestrator_state_root,
};
use std::time::Duration;

pub(super) fn handle<W: Write>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    params: &Value,
) -> Result<()> {
    debug_assert_eq!(super::ORCHESTRATOR_REQUEST_METHOD, "orchestrator.request");
    let receipt = match default_orchestrator_state_root() {
        Ok(root) => match super::super::orchestrator::desktop_orchestrator_command(params, &root)
            .and_then(build_desktop_orchestrator_request)
        {
            Ok(request) => {
                let timeout = request
                    .params
                    .get("timeoutMs")
                    .and_then(Value::as_u64)
                    .map(|millis| Duration::from_millis(millis.saturating_add(2_000)))
                    .unwrap_or(Duration::from_secs(10));
                OrchestratorIpcClient::new(root)
                    .with_client_kind("desktop")
                    .with_timeout(timeout)
                    .execute(&request)
            }
            Err(_) => OrchestratorIpcReceipt::failure(request_id, "invalid_request"),
        },
        Err(_) => OrchestratorIpcReceipt::failure(request_id, "invalid_request"),
    };
    Ok(write_stdio_rpc_success_shared(
        writer,
        request_id,
        workflow_id,
        serde_json::to_value(receipt)?,
    )?)
}
