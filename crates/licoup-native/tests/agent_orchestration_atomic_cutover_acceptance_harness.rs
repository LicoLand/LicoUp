//! Frozen atomic-cutover acceptance over the real private IPC service.
//!
//! Production owns every builder and state transition used here. The only
//! acceptance-only dependency is a deterministic governed dispatch adapter;
//! it is injected behind the real durable service/store boundary.

#![cfg(debug_assertions)]

use licoup_native::platform::{
    orchestrator_control_plane::{
        DesktopOrchestratorCommand, build_cli_orchestrator_request,
        build_codex_mcp_orchestrator_request, build_codex_mcp_status_event_request,
        build_desktop_orchestrator_request,
    },
    orchestrator_ipc::{OrchestratorIpcClient, OrchestratorIpcReceipt, OrchestratorIpcRequest},
    orchestrator_service::{
        OrchestratorServiceLifecycle, OrchestratorServiceOptions, PrivateArtifactStore,
        test_support::DeterministicGovernedDispatchRegistration,
    },
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const POLICY_ID: &str = "policy-cutover-synthetic";
const REGISTER_KEY: &str = "register-cutover-synthetic";
const ACTIVATE_KEY: &str = "activate-cutover-synthetic";
const SUBMIT_KEY: &str = "submit-cutover-synthetic";
const INPUT_HANDLE: &str = "artifact-input-synthetic";
const INPUT_BODY: &[u8] = b"synthetic-cutover-input";

struct PrivateStateRoot(PathBuf);

impl PrivateStateRoot {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lico-up-cutover-acceptance-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir(&path).expect("private acceptance root must be created");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .expect("private acceptance root permissions");
        }
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for PrivateStateRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[derive(Clone, Copy)]
enum Surface {
    Desktop,
    Cli,
    CodexMcp,
}

struct RunningService {
    join: Option<JoinHandle<Result<(), &'static str>>>,
    endpoint_generation: String,
}

impl RunningService {
    fn start(root: &Path) -> Self {
        let state_root = root.to_path_buf();
        let join = thread::spawn(move || {
            OrchestratorServiceLifecycle::serve_foreground(OrchestratorServiceOptions {
                state_root,
                ready_file: None,
                acceptance_control_root: None,
            })
            .map_err(|failure| failure.code)
        });
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if join.is_finished() {
                let code = match join.join() {
                    Ok(Ok(())) => "ok".to_owned(),
                    Ok(Err(code)) => code.to_owned(),
                    Err(_) => "panic".to_owned(),
                };
                panic!("production service exited before readiness: {code}");
            }
            let status = OrchestratorIpcClient::new(root)
                .with_client_kind("desktop")
                .with_auto_start(false)
                .with_timeout(Duration::from_millis(100))
                .execute(
                    &build_desktop_orchestrator_request(DesktopOrchestratorCommand::ServiceStatus)
                        .expect("desktop service-status builder"),
                );
            if status.ok {
                let result = status.result.expect("service status result");
                return Self {
                    join: Some(join),
                    endpoint_generation: required_string(&result, "endpointGeneration"),
                };
            }
            assert!(
                Instant::now() < deadline,
                "production service readiness deadline"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn stop(mut self, clients: &SurfaceClients) {
        let stop = build_desktop_orchestrator_request(DesktopOrchestratorCommand::StopService {
            idempotency_key: format!("stop-service-{}", uuid::Uuid::new_v4().simple()),
        })
        .expect("desktop service-stop builder");
        assert_success(clients.execute(Surface::Desktop, &stop));
        let result = self
            .join
            .take()
            .expect("service thread")
            .join()
            .expect("service thread must not panic");
        assert_eq!(result, Ok(()));
    }
}

struct SurfaceClients {
    desktop: OrchestratorIpcClient,
    cli: OrchestratorIpcClient,
    codex_mcp: OrchestratorIpcClient,
}

impl SurfaceClients {
    fn new(root: &Path) -> Self {
        Self {
            desktop: client(root, "desktop"),
            cli: client(root, "cli"),
            codex_mcp: client(root, "codex-mcp"),
        }
    }

    fn execute(
        &self,
        surface: Surface,
        request: &OrchestratorIpcRequest,
    ) -> OrchestratorIpcReceipt {
        assert_eq!(request.client_kind, surface.client_kind());
        match surface {
            Surface::Desktop => self.desktop.execute(request),
            Surface::Cli => self.cli.execute(request),
            Surface::CodexMcp => self.codex_mcp.execute(request),
        }
    }
}

fn client(root: &Path, client_kind: &'static str) -> OrchestratorIpcClient {
    OrchestratorIpcClient::new(root)
        .with_client_kind(client_kind)
        .with_auto_start(false)
        .with_timeout(Duration::from_secs(2))
}

impl Surface {
    fn client_kind(self) -> &'static str {
        match self {
            Self::Desktop => "desktop",
            Self::Cli => "cli",
            Self::CodexMcp => "codex-mcp",
        }
    }
}

#[test]
fn agent_orchestration_atomic_cutover_acceptance_harness() {
    let root = PrivateStateRoot::new();
    assert_production_builder_linkage_and_real_authority();
    let dispatch_registration =
        DeterministicGovernedDispatchRegistration::install("fixture-agent", "fixture-model")
            .expect("deterministic governed adapter registration");
    let input_digest = format!("{:x}", Sha256::digest(INPUT_BODY));
    let first_service = RunningService::start(root.path());
    let artifacts = PrivateArtifactStore::open(root.path()).expect("private artifact store");
    assert_eq!(
        artifacts
            .put(INPUT_HANDLE, INPUT_BODY)
            .expect("stage synthetic input artifact"),
        input_digest
    );
    let first_clients = SurfaceClients::new(root.path());

    let old_schema = policy_document(1);
    let old_request =
        build_desktop_orchestrator_request(DesktopOrchestratorCommand::RegisterPolicy {
            policy: old_schema,
            idempotency_key: "register-old-schema".into(),
        })
        .expect("desktop builder must preserve backend schema rejection");
    assert_failure(
        first_clients.execute(Surface::Desktop, &old_request),
        "policy_schema_unsupported",
    );

    let mut malformed = policy_document(3);
    malformed["fallbackAgent"] = json!("must-not-be-accepted");
    let malformed_request =
        build_desktop_orchestrator_request(DesktopOrchestratorCommand::RegisterPolicy {
            policy: malformed,
            idempotency_key: "register-malformed".into(),
        })
        .expect("desktop builder must not replace backend closed-schema validation");
    assert_failure(
        first_clients.execute(Surface::Desktop, &malformed_request),
        "policy_schema_invalid",
    );

    let register = build_desktop_orchestrator_request(DesktopOrchestratorCommand::RegisterPolicy {
        policy: policy_document(3),
        idempotency_key: REGISTER_KEY.into(),
    })
    .expect("canonical desktop policy registration request");
    assert_eq!(register.method, "policy.register");
    let registered = assert_success(first_clients.execute(Surface::Desktop, &register));
    let policy_revision = required_string(&registered, "policyRevisionId");
    assert!(!policy_revision.is_empty());
    assert_eq!(required_string(&registered, "state"), "registered");

    let activate = build_desktop_orchestrator_request(DesktopOrchestratorCommand::ActivatePolicy {
        policy_revision_id: policy_revision.clone(),
        idempotency_key: ACTIVATE_KEY.into(),
    })
    .expect("canonical desktop policy activation request");
    assert_eq!(activate.method, "policy.activate");
    let activated = assert_success(first_clients.execute(Surface::Desktop, &activate));
    assert_eq!(
        required_string(&activated, "policyRevisionId"),
        policy_revision
    );
    assert_eq!(required_string(&activated, "state"), "active");

    let desktop_submit =
        build_desktop_orchestrator_request(DesktopOrchestratorCommand::SubmitWorkflow {
            policy_revision_id: policy_revision.clone(),
            input_artifact_handle: INPUT_HANDLE.into(),
            input_digest: input_digest.clone(),
            idempotency_key: SUBMIT_KEY.into(),
        })
        .expect("desktop submit builder");
    let cli_submit = build_cli_orchestrator_request(&[
        "submit".into(),
        "--policy-revision-id".into(),
        policy_revision.clone(),
        "--input-artifact-handle".into(),
        INPUT_HANDLE.into(),
        "--input-digest".into(),
        input_digest.clone(),
        "--idempotency-key".into(),
        SUBMIT_KEY.into(),
    ])
    .expect("real CLI submit builder");
    let mcp_submit = build_codex_mcp_orchestrator_request(
        "lico_workflow_submit",
        &json!({
            "policyRevisionId": policy_revision,
            "inputArtifact": {"handle": INPUT_HANDLE, "digest": input_digest},
            "idempotencyKey": SUBMIT_KEY,
        }),
    )
    .expect("real Codex MCP submit builder");
    assert_equivalent_commands(&desktop_submit, &cli_submit, &mcp_submit);

    let desktop_receipt = assert_success(first_clients.execute(Surface::Desktop, &desktop_submit));
    let workflow_id = required_string(&desktop_receipt, "workflowId");
    let terminal_before_restart = wait_for_terminal(
        &first_clients,
        Surface::Desktop,
        desktop_status(&workflow_id),
    );
    let desktop_events =
        assert_success(first_clients.execute(Surface::Desktop, &desktop_events(&workflow_id, 0)));
    let desktop_projection = semantic_projection(&terminal_before_restart, &desktop_events);
    assert_eq!(dispatch_effect_count(&desktop_events), 1);

    let endpoint_before = first_service.endpoint_generation.clone();
    first_service.stop(&first_clients);
    drop(first_clients);

    let second_service = RunningService::start(root.path());
    assert_ne!(second_service.endpoint_generation, endpoint_before);
    let second_clients = SurfaceClients::new(root.path());

    let cli_receipt = assert_success(second_clients.execute(Surface::Cli, &cli_submit));
    let mcp_receipt = assert_success(second_clients.execute(Surface::CodexMcp, &mcp_submit));
    assert_eq!(cli_receipt, desktop_receipt);
    assert_eq!(mcp_receipt, desktop_receipt);

    let cli_status_request = build_cli_orchestrator_request(&[
        "workflow-status".into(),
        "--workflow-id".into(),
        workflow_id.clone(),
    ])
    .expect("real CLI status builder");
    let cli_events_request = build_cli_orchestrator_request(&[
        "events".into(),
        "--workflow-id".into(),
        workflow_id.clone(),
        "--after-cursor".into(),
        "0".into(),
        "--limit".into(),
        "128".into(),
    ])
    .expect("real CLI events builder");
    let mcp_status_request = build_codex_mcp_orchestrator_request(
        "lico_workflow_status",
        &json!({"workflowId": workflow_id, "afterCursor": 0, "limit": 128}),
    )
    .expect("real MCP status builder");
    let mcp_events_request = build_codex_mcp_status_event_request(
        &mcp_status_request,
        &json!({"workflowId": workflow_id, "afterCursor": 0, "limit": 128}),
    )
    .expect("real MCP status event-page builder");

    let cli_status = assert_success(second_clients.execute(Surface::Cli, &cli_status_request));
    let cli_events = assert_success(second_clients.execute(Surface::Cli, &cli_events_request));
    let mcp_status = assert_success(second_clients.execute(Surface::CodexMcp, &mcp_status_request));
    let mcp_events = assert_success(second_clients.execute(Surface::CodexMcp, &mcp_events_request));
    let cli_projection = semantic_projection(&cli_status, &cli_events);
    let mcp_projection = semantic_projection(&mcp_status, &mcp_events);
    assert_eq!(cli_projection, desktop_projection);
    assert_eq!(mcp_projection, desktop_projection);
    assert_eq!(dispatch_effect_count(&cli_events), 1);
    assert_eq!(dispatch_effect_count(&mcp_events), 1);

    second_service.stop(&second_clients);
    drop(second_clients);
    drop(dispatch_registration);
    println!(
        "LICOUP_CUTOVER_ACCEPTANCE {}",
        json!({
            "surfaces": ["desktop", "cli", "codex-mcp"],
            "privateEndpointCount": 1,
            "samePolicyRevision": true,
            "sameSequences": true,
            "sameAdapterDecision": true,
            "sameTerminalReceipt": true,
            "serviceStoreRestarted": true,
            "dispatchEffects": 1,
            "oldSchemaRejected": true,
            "malformedPolicyRejected": true,
        })
    );
}

fn assert_success(receipt: OrchestratorIpcReceipt) -> Value {
    assert!(receipt.ok, "synthetic orchestration request must succeed");
    receipt
        .result
        .expect("successful receipt must project a result")
}

fn assert_failure(receipt: OrchestratorIpcReceipt, expected: &str) {
    assert!(!receipt.ok);
    assert_eq!(receipt.error_code(), Some(expected));
    assert!(receipt.result.is_none());
}

fn assert_equivalent_commands(
    desktop: &OrchestratorIpcRequest,
    cli: &OrchestratorIpcRequest,
    mcp: &OrchestratorIpcRequest,
) {
    for request in [desktop, cli, mcp] {
        assert_eq!(request.protocol_version, "lico.orchestrator.ipc.v1");
        assert_eq!(request.method, "workflow.submit");
        assert_eq!(request.params, desktop.params);
        assert_eq!(request.idempotency_key.as_deref(), Some(SUBMIT_KEY));
    }
    assert_eq!(desktop.client_kind, "desktop");
    assert_eq!(cli.client_kind, "cli");
    assert_eq!(mcp.client_kind, "codex-mcp");
}

fn wait_for_terminal(
    clients: &SurfaceClients,
    surface: Surface,
    request: OrchestratorIpcRequest,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let result = assert_success(clients.execute(surface, &request));
        if matches!(
            result.get("state").and_then(Value::as_str),
            Some("completed" | "failed" | "cancelled" | "unknown")
        ) {
            return result;
        }
        assert!(
            Instant::now() < deadline,
            "synthetic workflow terminal deadline"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

fn dispatch_effect_count(events: &Value) -> usize {
    events
        .get("events")
        .and_then(Value::as_array)
        .expect("event page")
        .iter()
        .filter(|event| event.get("type").and_then(Value::as_str) == Some("dispatch.started"))
        .count()
}

fn desktop_status(workflow_id: &str) -> OrchestratorIpcRequest {
    build_desktop_orchestrator_request(DesktopOrchestratorCommand::WorkflowStatus {
        workflow_id: workflow_id.into(),
    })
    .expect("desktop status builder")
}

fn desktop_events(workflow_id: &str, after_cursor: u64) -> OrchestratorIpcRequest {
    build_desktop_orchestrator_request(DesktopOrchestratorCommand::WorkflowEvents {
        workflow_id: workflow_id.into(),
        after_cursor,
        limit: 128,
    })
    .expect("desktop events builder")
}

fn semantic_projection(status: &Value, events: &Value) -> Value {
    let sequence: Vec<Value> = events
        .get("events")
        .and_then(Value::as_array)
        .expect("event page")
        .iter()
        .map(|event| {
            json!({
                "cursor": event.get("cursor").and_then(Value::as_u64).expect("event cursor"),
                "type": event.get("type").and_then(Value::as_str).expect("event type"),
                "state": event.get("state").and_then(Value::as_str).expect("event state"),
            })
        })
        .collect();
    json!({
        "policyRevisionId": required_string(status, "policyRevisionId"),
        "state": required_string(status, "state"),
        "adapterDecision": required_string(status, "adapterDecision"),
        "terminalReceipt": status.get("terminalReceipt").cloned().expect("terminal receipt"),
        "sequence": sequence,
    })
}

fn required_string(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| panic!("missing synthetic field {key}"))
        .to_owned()
}

fn assert_production_builder_linkage_and_real_authority() {
    const DART_BRIDGE: &str = include_str!(
        "../../../apps/desktop/lib/src/platform/native_client/orchestrator_ipc/client.dart"
    );
    const DESKTOP_STDIO_HANDLER: &str = include_str!("../src/bin/licoup/stdio_rpc/server.rs");
    const CLI_HANDLER: &str = include_str!("../src/bin/licoup/orchestrator.rs");
    const MCP_HANDLER: &str = include_str!("../src/bin/lico-codex-mcp.rs");
    const SHARED_BUILDERS: &str = include_str!("../src/platform/orchestrator_control_plane.rs");
    const SERVICE: &str = include_str!("../src/platform/orchestrator_service.rs");
    const SERVICE_TEST_SUPPORT: &str =
        include_str!("../src/platform/orchestrator_service/test_support.rs");

    assert!(DART_BRIDGE.contains("NativeStdioRpcTransport"));
    assert!(DART_BRIDGE.contains("executeStructured("));
    assert!(DART_BRIDGE.contains("orchestrator.request"));
    assert!(!DART_BRIDGE.contains("Socket.connect"));
    assert!(!DART_BRIDGE.contains("Process.start"));
    assert!(DESKTOP_STDIO_HANDLER.contains("orchestrator.request"));
    assert!(
        DESKTOP_STDIO_HANDLER
            .matches("build_desktop_orchestrator_request")
            .count()
            >= 2,
        "shipped desktop stdio bridge must import and call the shared builder"
    );
    assert!(
        CLI_HANDLER
            .matches("build_cli_orchestrator_request")
            .count()
            >= 2,
        "shipped CLI handler must import and call the shared builder"
    );
    assert!(
        MCP_HANDLER
            .matches("build_codex_mcp_orchestrator_request")
            .count()
            >= 2,
        "shipped MCP handler must import and call the shared builder"
    );
    assert!(
        MCP_HANDLER
            .matches("build_codex_mcp_status_event_request")
            .count()
            >= 2,
        "shipped MCP status path must import and call the shared event builder"
    );
    for public_builder in [
        "pub fn build_desktop_orchestrator_request",
        "pub fn build_cli_orchestrator_request",
        "pub fn build_codex_mcp_orchestrator_request",
        "pub fn build_codex_mcp_status_event_request",
    ] {
        assert!(
            SHARED_BUILDERS.contains(public_builder),
            "frozen harness must use a production-shared builder"
        );
    }

    assert!(SERVICE.contains("DurableWorkflowStore::open"));
    assert!(SERVICE.contains("PersistentWorkflowEngine::open_active"));
    assert!(SERVICE.contains("DeterministicGovernedDispatchRegistration"));
    assert!(SERVICE_TEST_SUPPORT.contains("DeterministicGovernedDispatchRegistration"));
    assert!(SERVICE_TEST_SUPPORT.contains("ConversationLane"));
    for forbidden_state_owner in [
        "DurableWorkflowStore",
        "PersistentWorkflowEngine",
        "rusqlite",
        "WorkflowSnapshot",
        "WorkflowCommand",
    ] {
        assert!(
            !SERVICE_TEST_SUPPORT.contains(forbidden_state_owner),
            "deterministic test adapter must not own orchestration state"
        );
    }
}

fn policy_document(schema_version: u64) -> Value {
    json!({
        "schemaVersion": schema_version,
        "id": POLICY_ID,
        "label": "Synthetic cutover policy",
        "commander": null,
        "modelLibrary": [{
            "agentId": "fixture-agent",
            "modelId": "fixture-model",
            "reasoningLevel": "max"
        }],
        "agents": [{
            "id": "fixture-agent",
            "roles": ["implementation"],
            "capabilities": ["conversation.send"]
        }],
        "workflow": {"steps": [{
            "id": "implement",
            "predecessorId": null,
            "purpose": "action",
            "roleId": "implementation",
            "agentId": "fixture-agent",
            "modelId": "fixture-model",
            "reasoningLevel": "max",
            "contextStepIds": [],
            "maxContextBytes": 4096,
            "outputMode": "text",
            "timeoutMs": 1000,
            "maxAttempts": 1,
            "failureAction": "stop",
            "approval": {"required": false},
            "condition": null,
            "validation": null
        }]}
    })
}
