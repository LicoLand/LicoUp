export async function checkCommandAndFileTransport(context, { secureMeshMobileFfiRoot }) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
    sourceLineCount,
  } = context;
  const secureMeshCommandRustSource = await readJoinedText([
    "crates/lico-client-native/src/core/secure_mesh_command.rs",
    ...await collectSourceFiles("crates/lico-client-native/src/core/secure_mesh_command", ".rs")
  ]);
  const secureMeshCommandRuntimeRustSource = await readText(
    "crates/lico-client-native/src/domain/secure_mesh_command_runtime.rs"
  );
  assert(secureMeshCommandRustSource.includes("LOCAL_EXECUTION_FAILED_REMOTE_DETAIL") &&
    secureMeshCommandRustSource.includes("secure_mesh_command_execution_redacts_executor_error_detail") &&
    secureMeshCommandRustSource.includes("local-secret-canary") &&
    !secureMeshCommandRustSource.includes("&error.to_string()"),
    "secure_mesh_command.rs must not return raw local executor errors over Secure Mesh results"
  );
  assert(
    secureMeshCommandRuntimeRustSource.includes("dispatch_ready_agent_message") &&
      secureMeshCommandRuntimeRustSource.includes("dispatch_lane_operation") &&
      !secureMeshCommandRuntimeRustSource.includes("runtime_adapters::send_message") &&
      !secureMeshCommandRustSource.includes("crate::platform") &&
      !secureMeshCommandRustSource.includes("crate::domain"),
    "Secure Mesh agent sends must keep the readiness gate and enter the shared conversation lane"
  );
  const secureMeshFileRustSource = await readJoinedText([
    "crates/lico-client-native/src/core/secure_mesh_file.rs",
    ...await collectSourceFiles("crates/lico-client-native/src/core/secure_mesh_file", ".rs")
  ]);
  assert(secureMeshFileRustSource.includes("file_manifest_delivery_json") &&
    secureMeshFileRustSource.includes("file_chunk_delivery_json") &&
    secureMeshFileRustSource.includes("secure_mesh_file_delivery_json_hides_manifest_and_chunk_plaintext") &&
    secureMeshFileRustSource.includes("evaluate_file_handoff_proof_json") &&
    secureMeshFileRustSource.includes("secure_mesh_file_handoff_proof_reseals_distinct_ciphertext_for_multiple_recipients") &&
    secureMeshFileRustSource.includes("multiRecipientIndependentResealReady") &&
    secureMeshFileRustSource.includes("file-body-plaintext-secret-canary-content"),
    "secure_mesh_file.rs must expose tested server-visible delivery JSON and multi-recipient handoff reseal proof without file metadata or chunk plaintext"
  );
  assert(secureMeshFileRustSource.includes("evaluate_file_receive_destination_json") &&
    secureMeshFileRustSource.includes("evaluate_file_receive_confirmation_json") &&
    secureMeshFileRustSource.includes("secure_mesh.file_receive.write") &&
    secureMeshFileRustSource.includes("secure_mesh.file_receive.confirm") &&
    secureMeshFileRustSource.includes("secure_mesh_file_receive_destination_redacts_local_paths_and_metadata") &&
    secureMeshFileRustSource.includes("secure_mesh_file_receive_destination_rejects_unapproved_paths") &&
    secureMeshFileRustSource.includes("secure_mesh_file_receive_confirmation_requires_user_action_and_disables_auto_open"),
    "secure_mesh_file.rs must keep local receive destination and confirmation policy covered by redaction and fail-closed tests"
  );
  const secureMeshCliSource = await readText("crates/lico-client-native/src/ffi/commands/secure_mesh.rs");
  assert(secureMeshCliSource.includes('"receive-destination"') &&
    secureMeshCliSource.includes('"receive-confirmation"') &&
    secureMeshCliSource.includes("evaluate_file_receive_destination_json") &&
    secureMeshCliSource.includes("evaluate_file_receive_confirmation_json") &&
    secureMeshCliSource.includes("secure_mesh_file_receive_destination_cli_redacts_destination_paths") &&
    secureMeshCliSource.includes("secure_mesh_file_receive_confirmation_cli_requires_user_confirmation_without_auto_open"),
    "secure-mesh CLI must expose receive-destination and receive-confirmation policy evaluation without leaking destination paths"
  );
  const secureMeshMobileFfiSource = await readJoinedText([
    "crates/lico-client-native/src/ffi/secure_mesh_mobile_ffi.rs",
    `${secureMeshMobileFfiRoot}/action_catalog.rs`,
    `${secureMeshMobileFfiRoot}/dispatch_context.rs`,
    `${secureMeshMobileFfiRoot}/dispatch_router.rs`,
    `${secureMeshMobileFfiRoot}/feature_status.rs`,
    `${secureMeshMobileFfiRoot}/fixture_envelope.rs`,
    `${secureMeshMobileFfiRoot}/fixture_file.rs`,
    `${secureMeshMobileFfiRoot}/fixture_lifecycle.rs`,
    `${secureMeshMobileFfiRoot}/fixture_payload.rs`,
    `${secureMeshMobileFfiRoot}/fixture_trust.rs`,
    `${secureMeshMobileFfiRoot}/protected_operation.rs`,
    `${secureMeshMobileFfiRoot}/redacted_error.rs`,
    `${secureMeshMobileFfiRoot}/request_validation.rs`,
    `${secureMeshMobileFfiRoot}/tests/fixture_policy.rs`
  ]);
  assert(secureMeshMobileFfiSource.includes('"secure_mesh.file.route"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.file.receiveDestination"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.file.receiveConfirmation"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.file.handoffProof"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.approval.request"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.approval.respond"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.approval.inbox"') &&
    secureMeshMobileFfiSource.includes('"secure_mesh.lifecycle.serviceAction"') &&
    secureMeshMobileFfiSource.includes("FEATURE_LIFECYCLE_SERVICE_ACTIONS") &&
    !secureMeshMobileFfiSource.includes("contentKeyBase64url") &&
    !secureMeshMobileFfiSource.includes("includeBodyBase64url") &&
    secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_file_route_and_receive_destination_policy") &&
    secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_file_handoff_reseal_proof_without_plaintext") &&
    secureMeshMobileFfiSource.includes("mobile_ffi_exposes_shared_lifecycle_service_actions_without_plaintext"),
    "mobile Secure Mesh FFI must expose file, approval, and lifecycle policy actions without raw payload-key or plaintext-body actions"
  );
  return { secureMeshMobileFfiSource };
}
