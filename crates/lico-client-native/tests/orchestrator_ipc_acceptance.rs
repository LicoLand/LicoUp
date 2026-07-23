//! Frozen external acceptance harness for the private orchestrator IPC boundary.

use lico_client_native::platform::orchestrator_ipc::{
    OrchestratorIpcServer, OrchestratorIpcServerConfig,
    test_support::{
        AcceptanceFault, AcceptanceLimits, CountingMutationHandler, FaultInjectingLocalTransport,
        SyntheticPeer,
    },
};
use serde_json::{Value, json};
use std::{
    sync::{Arc, mpsc},
    thread,
    time::Duration,
};

const PROTOCOL: &str = "lico.orchestrator.ipc.v1";

fn peer(id: &str, operations: &[&str]) -> SyntheticPeer {
    SyntheticPeer::owner_bound(id, "cli", PROTOCOL, operations.iter().copied())
}

fn request(id: &str, method: &str, params: Value, idempotency_key: Option<&str>) -> Vec<u8> {
    let mut value = json!({
        "protocolVersion": PROTOCOL,
        "requestId": id,
        "clientKind": "cli",
        "method": method,
        "params": params,
    });
    if let Some(key) = idempotency_key {
        value["idempotencyKey"] = Value::String(key.to_owned());
    }
    serde_json::to_vec(&value).expect("synthetic request must encode")
}

fn limits() -> AcceptanceLimits {
    AcceptanceLimits {
        max_frame_bytes: 1_024,
        max_connections: 2,
        max_queued_requests: 1,
        max_requests_per_window: 2,
    }
}

fn server() -> (OrchestratorIpcServer, CountingMutationHandler) {
    let handler = CountingMutationHandler::new();
    let server = OrchestratorIpcServer::with_fault_transport_for_test(
        OrchestratorIpcServerConfig::synthetic(limits()),
        FaultInjectingLocalTransport::new(),
        handler.clone(),
    )
    .expect("real IPC server test boundary must bind");
    (server, handler)
}

#[test]
fn server_side_peer_and_capability_binding_precede_handler_mutation() {
    let (server, handler) = server();
    let submit = request(
        "submit-1",
        "workflow.submit",
        json!({"policyRevisionId": "policy-synthetic", "inputDigest": "a".repeat(64)}),
        Some("submit-key-1"),
    );

    let admitted = server.inject_test_exchange(
        peer("owner-client", &["workflow.submit"]),
        &submit,
        AcceptanceFault::None,
    );
    assert_eq!(admitted.error_code(), None);
    assert_eq!(admitted.handler_mutations(), 1);
    assert_eq!(admitted.receipt()["ok"], true);

    let before = handler.mutations();
    let capability_rejected = server.inject_test_exchange(
        peer("status-only", &["service.status"]),
        &submit,
        AcceptanceFault::None,
    );
    assert_eq!(
        capability_rejected.error_code(),
        Some("operation_forbidden")
    );
    assert_eq!(capability_rejected.handler_mutations(), before);
    assert_eq!(handler.mutations(), before);

    let foreign = server.inject_test_exchange(
        SyntheticPeer::foreign("foreign-client", "cli", PROTOCOL, ["workflow.submit"]),
        &submit,
        AcceptanceFault::None,
    );
    assert_eq!(foreign.error_code(), Some("peer_rejected"));
    assert_eq!(foreign.handler_mutations(), before);

    let stale = server.inject_test_exchange(
        SyntheticPeer::owner_bound(
            "stale-client",
            "cli",
            "lico.orchestrator.ipc.v0",
            ["workflow.submit"],
        ),
        &submit,
        AcceptanceFault::None,
    );
    assert_eq!(stale.error_code(), Some("protocol_mismatch"));
    assert_eq!(stale.handler_mutations(), before);

    let unknown_method = request("unknown-1", "workflow.unknown", json!({}), None);
    let unknown = server.inject_test_exchange(
        peer("unknown-method", &["workflow.unknown"]),
        &unknown_method,
        AcceptanceFault::None,
    );
    assert_eq!(unknown.error_code(), Some("unknown_method"));
    assert_eq!(unknown.handler_mutations(), before);
    assert_eq!(handler.mutations(), before);
}

#[test]
fn frame_rate_connection_and_queue_faults_are_pre_handler_and_stable() {
    let (server, handler) = server();
    let status = request("status-1", "service.status", json!({}), None);
    let owner = peer("bounded-client", &["service.status"]);
    let before = handler.mutations();

    let oversized = vec![b'x'; limits().max_frame_bytes + 1];
    let cases = [
        (
            owner.clone(),
            oversized.as_slice(),
            AcceptanceFault::None,
            "frame_too_large",
        ),
        (
            owner.clone(),
            status.as_slice(),
            AcceptanceFault::TruncatedFrame,
            "frame_truncated",
        ),
        (
            owner.clone(),
            status.as_slice(),
            AcceptanceFault::BrokenTransport,
            "transport_closed",
        ),
        (
            owner.clone(),
            status.as_slice(),
            AcceptanceFault::ConnectionCapacitySaturated,
            "capacity_exceeded",
        ),
        (
            owner.clone(),
            status.as_slice(),
            AcceptanceFault::RequestQueueSaturated,
            "capacity_exceeded",
        ),
    ];
    for (peer, frame, fault, expected) in cases {
        let observed = server.inject_test_exchange(peer, frame, fault);
        assert_eq!(observed.error_code(), Some(expected));
        assert_eq!(observed.handler_mutations(), before);
        assert_eq!(handler.mutations(), before);
    }

    assert_eq!(
        server
            .inject_test_exchange(owner.clone(), &status, AcceptanceFault::None)
            .error_code(),
        None,
    );
    assert_eq!(
        server
            .inject_test_exchange(owner.clone(), &status, AcceptanceFault::None)
            .error_code(),
        None,
    );
    let rate_limited = server.inject_test_exchange(owner, &status, AcceptanceFault::None);
    assert_eq!(rate_limited.error_code(), Some("rate_limited"));
    assert_eq!(rate_limited.handler_mutations(), before);
}

#[test]
fn invalid_private_payload_is_rejected_without_projection() {
    let (server, handler) = server();
    let canaries = [
        "synthetic-account@example.invalid",
        "synthetic-credential-canary",
        "/synthetic/private-path-canary",
        "synthetic-native-session-canary",
        "synthetic raw provider output",
    ];
    let invalid = request(
        "private-invalid",
        "workflow.cancel",
        json!({
            "workflowId": "workflow-synthetic",
            "prompt": canaries[4],
            "credential": canaries[1],
            "accountIdentifier": canaries[0],
            "nativeSessionId": canaries[3],
            "filePath": canaries[2],
        }),
        Some("cancel-private-invalid"),
    );
    let observed = server.inject_test_exchange(
        peer("privacy-client", &["workflow.cancel"]),
        &invalid,
        AcceptanceFault::None,
    );
    assert_eq!(observed.error_code(), Some("invalid_request"));
    assert_eq!(observed.handler_mutations(), 0);
    assert_eq!(handler.mutations(), 0);
    let projection = observed.redacted_json().to_string();
    for canary in canaries {
        assert!(!projection.contains(canary));
    }
}

#[test]
fn real_server_connection_and_request_queue_permits_saturate_without_mutation() {
    let handler = CountingMutationHandler::new();
    let permit_limits = AcceptanceLimits {
        max_frame_bytes: 1_024,
        max_connections: 3,
        max_queued_requests: 1,
        max_requests_per_window: 16,
    };
    let server = Arc::new(
        OrchestratorIpcServer::with_fault_transport_for_test(
            OrchestratorIpcServerConfig::synthetic(permit_limits),
            FaultInjectingLocalTransport::new(),
            handler.clone(),
        )
        .expect("real IPC server permit boundary must bind"),
    );
    let first = server
        .open_test_connection(peer("permit-1", &["service.status"]))
        .expect("first connection permit");
    let second = server
        .open_test_connection(peer("permit-2", &["service.status"]))
        .expect("second connection permit");
    let third = server
        .open_test_connection(peer("permit-3", &["service.status"]))
        .expect("third connection permit");
    let connection_rejected = server
        .open_test_connection(peer("permit-4", &["service.status"]))
        .expect_err("fourth connection must saturate real permit table");
    assert_eq!(connection_rejected.code(), "capacity_exceeded");
    assert_eq!(handler.mutations(), 0);

    handler.block_next_request();
    let (active_tx, active_rx) = mpsc::sync_channel(1);
    let active = thread::spawn(move || {
        active_tx
            .send(first.exchange(&request("active", "service.status", json!({}), None)))
            .expect("active result receiver");
    });
    assert!(handler.wait_until_blocked(Duration::from_secs(2)));
    let (queued_tx, queued_rx) = mpsc::sync_channel(1);
    let queued = thread::spawn(move || {
        queued_tx
            .send(second.exchange(&request("queued", "service.status", json!({}), None)))
            .expect("queued result receiver");
    });
    assert!(server.wait_for_queued_requests(1, Duration::from_secs(2)));
    let queue_rejected = third.exchange(&request("overflow", "service.status", json!({}), None));
    assert_eq!(queue_rejected.error_code(), Some("capacity_exceeded"));
    assert_eq!(handler.mutations(), 0);

    handler.release_blocked_request();
    assert_eq!(
        active_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("active request deadline")
            .error_code(),
        None,
    );
    assert_eq!(
        queued_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("queued request deadline")
            .error_code(),
        None,
    );
    active.join().expect("active request must not panic");
    queued.join().expect("queued request must not panic");
    assert_eq!(handler.mutations(), 0);
}

#[test]
fn wakeable_wait_never_blocks_a_concurrent_child_message() {
    let handler = CountingMutationHandler::new();
    let server = Arc::new(
        OrchestratorIpcServer::with_fault_transport_for_test(
            OrchestratorIpcServerConfig::synthetic(AcceptanceLimits {
                max_frame_bytes: 2_048,
                max_connections: 4,
                max_queued_requests: 2,
                max_requests_per_window: 16,
            }),
            FaultInjectingLocalTransport::new(),
            handler.clone(),
        )
        .expect("concurrent Level-2 IPC boundary must bind"),
    );
    let wait_connection = server
        .open_test_connection(peer("wait-client", &["workflow.wait"]))
        .unwrap();
    let message_connection = server
        .open_test_connection(peer("message-client", &["workflow.message"]))
        .unwrap();
    handler.block_next_request();
    let (wait_tx, wait_rx) = mpsc::sync_channel(1);
    let wait = thread::spawn(move || {
        wait_tx
            .send(wait_connection.exchange(&request(
                "wait-1",
                "workflow.wait",
                json!({
                    "workflowId": "workflow-level-2",
                    "afterCursor": 0,
                    "limit": 64,
                    "timeoutMs": 30_000,
                }),
                None,
            )))
            .unwrap();
    });
    assert!(handler.wait_until_blocked(Duration::from_secs(2)));

    let message = message_connection.exchange(&request(
        "message-1",
        "workflow.message",
        json!({
            "workflowId": "workflow-level-2",
            "messageArtifactHandle": "message-artifact",
            "messageDigest": "a".repeat(64),
        }),
        Some("message-once"),
    ));
    assert_eq!(message.error_code(), None);
    assert_eq!(handler.mutations(), 1);

    handler.release_blocked_request();
    assert_eq!(
        wait_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("wait request must resume")
            .error_code(),
        None
    );
    wait.join().unwrap();
}

#[test]
fn graceful_drain_rejects_new_admission_and_completes_in_flight_request() {
    let handler = CountingMutationHandler::new();
    handler.block_next_request();
    let server = Arc::new(
        OrchestratorIpcServer::with_fault_transport_for_test(
            OrchestratorIpcServerConfig::synthetic(limits()),
            FaultInjectingLocalTransport::new(),
            handler.clone(),
        )
        .expect("real IPC server test boundary must bind"),
    );
    let in_flight_server = Arc::clone(&server);
    let (completed_tx, completed_rx) = mpsc::sync_channel(1);
    let in_flight = thread::spawn(move || {
        let observed = in_flight_server.inject_test_exchange(
            peer("in-flight", &["workflow.submit"]),
            &request(
                "in-flight-submit",
                "workflow.submit",
                json!({
                    "policyRevisionId": "policy-synthetic",
                    "inputDigest": "a".repeat(64),
                }),
                Some("in-flight-key"),
            ),
            AcceptanceFault::None,
        );
        completed_tx
            .send(observed)
            .expect("acceptance receiver must remain available");
    });
    assert!(handler.wait_until_blocked(Duration::from_secs(2)));
    server.begin_graceful_drain(Duration::from_secs(2));

    let rejected = server.inject_test_exchange(
        peer("new-admission", &["service.status"]),
        &request("new-status", "service.status", json!({}), None),
        AcceptanceFault::None,
    );
    assert_eq!(rejected.error_code(), Some("service_draining"));
    assert_eq!(handler.mutations(), 0);

    handler.release_blocked_request();
    let completed = completed_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("in-flight request must complete before deadline");
    in_flight.join().expect("in-flight request must not panic");
    assert_eq!(completed.error_code(), None);
    assert_eq!(completed.receipt()["ok"], true);
    assert_eq!(handler.mutations(), 1);
    assert!(server.wait_for_drain(Duration::from_secs(2)));
}
