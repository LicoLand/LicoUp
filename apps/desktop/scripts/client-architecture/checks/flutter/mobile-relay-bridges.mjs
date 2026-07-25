export async function checkMobileRelayBridges(context, { secureMeshMobileFfiSource }) {
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
  const mobileRelayServiceSource = await readJoinedDartSourcesByBasename([
    "mobile_relay_service.dart",
    "mobile_relay_service_ops.dart",
    "mobile_relay_config_projector.dart",
    "mobile_relay_native_dispatch.dart"
  ]);
  assert(mobileRelayServiceSource.includes("'mobile'") &&
    mobileRelayServiceSource.includes("'relay'") &&
    mobileRelayServiceSource.includes("_dispatch.runCli") &&
    mobileRelayServiceSource.includes("MobileRelayOperations"),
    "mobile relay config and provider operations must delegate through the injectable native dispatch boundary"
  );
  const mobileRelaySecureMeshServiceSource = await readJoinedDartSourcesByBasename([
    "mobile_relay_secure_mesh_service.dart",
    "mobile_relay_secure_conversation_operations.dart",
    "mobile_relay_secure_result_reducer.dart",
    "secure_mesh_protocol_operations.dart",
    "secure_mesh_substrate_operations.dart"
  ]);
  assert(mobileRelayServiceSource.includes("evaluateSecureMeshFileReceiveDestination") &&
    mobileRelayServiceSource.includes("evaluateSecureMeshFileReceiveConfirmation") &&
    mobileRelaySecureMeshServiceSource.includes("'mobile.relay.e2ee.status'") &&
    mobileRelaySecureMeshServiceSource.includes("mobileRelayE2eeSecretStore") &&
    mobileRelaySecureMeshServiceSource.includes("'secure_mesh.file.receiveDestination'") &&
    mobileRelaySecureMeshServiceSource.includes("'secure_mesh.file.receiveConfirmation'") &&
    mobileRelaySecureMeshServiceSource.includes("'receive-destination'") &&
    mobileRelaySecureMeshServiceSource.includes("'receive-confirmation'"),
    "mobile relay service must route E2EE status and file receive-destination/confirmation policy through mobile native FFI and desktop CLI"
  );
  assert(!mobileRelayServiceSource.includes("part of") &&
    !mobileRelaySecureMeshServiceSource.includes("part of") &&
    mobileRelaySecureMeshServiceSource.includes("MobileRelaySecureConversationOperations") &&
    mobileRelaySecureMeshServiceSource.includes("SecureMeshProtocolOperations") &&
    mobileRelaySecureMeshServiceSource.includes("SecureMeshSubstrateOperations"),
    "mobile relay must use normal-import, independently injectable ordinary, conversation, protocol, and substrate components"
  );
  const secureMeshCapabilityModelsSource =
    await readText("apps/desktop/lib/src/contracts/generated/secure_mesh.g.dart");
  const secureMeshCapabilityServiceSource =
    await readText("apps/desktop/lib/src/platform/secure_mesh/secure_mesh_capability_service.dart");
  const secureMeshCapabilityCardSource =
    await readText("apps/desktop/lib/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart");
  const mobileRelayControlSource = await readDartSourceByBasename(
    "mobile_relay_control.dart"
  );
  const mobileRelayControllerSource = await readJoinedText([
    "apps/desktop/lib/src/application/features/mobile_relay/controller/mobile_relay_controller.dart"
  ]);
  const secureMeshControllerSource = await readJoinedText([
    "apps/desktop/lib/src/application/features/mobile_relay/controller/secure_mesh_controller.dart",
    ...await collectSourceFiles(
      "apps/desktop/lib/src/application/features/mobile_relay/controller",
      ".dart"
    )
  ]);
  const mobileRelayGatewayAdapterSource = await readDartSourceByBasename(
    "mobile_relay_gateway_adapter.dart"
  );
  assert(
    mobileRelayControlSource.includes("abstract interface class MobileRelayGateway") &&
      mobileRelayControlSource.includes("abstract interface class SecureMeshGateway") &&
      mobileRelayControllerSource.includes("final MobileRelayGateway _gateway") &&
      secureMeshControllerSource.includes("final SecureMeshGateway _gateway") &&
      mobileRelayGatewayAdapterSource.includes("implements MobileRelayGateway, SecureMeshGateway") &&
      mobileRelayGatewayAdapterSource.includes("_relayService.loadConfig(") &&
      mobileRelayGatewayAdapterSource.includes("_relayService.secureMeshStatus("),
    "Mobile Relay and Secure Mesh controllers must depend on separate application ports implemented by the composition adapter"
  );
  for (const [relativePath, source] of [
    ["mobile_relay_controller.dart", mobileRelayControllerSource],
    ["secure_mesh_controller.dart", secureMeshControllerSource]
  ]) {
    assert(
      !source.includes("package:licoup/src/backend/") &&
        !source.includes("package:licoup/src/platform/"),
      `${relativePath} must depend on contracts and policies, not backend or platform implementations`
    );
  }
  assert(secureMeshMobileFfiSource.includes('"secure_mesh.status"') &&
    mobileRelaySecureMeshServiceSource.includes("action: 'secure_mesh.status'") &&
    mobileRelaySecureMeshServiceSource.includes("verifiedSessionProjection") &&
    secureMeshCapabilityModelsSource.includes("negotiatedProtocolCapabilities") &&
    secureMeshCapabilityModelsSource.includes("exact protocol intersection") &&
    secureMeshCapabilityServiceSource.includes("SecureMeshCapabilityProjection.fromJson") &&
    mobileRelayGatewayAdapterSource.includes("_capabilityService.projectStatus(status)") &&
    secureMeshControllerSource.includes("_gateway.projectStatus(raw)") &&
    secureMeshCapabilityCardSource.includes("keyPrefix: 'secure-mesh-local'") &&
    secureMeshCapabilityCardSource.includes("keyPrefix: 'secure-mesh-peer'") &&
    secureMeshCapabilityCardSource.includes("Key('$keyPrefix-enabled')") &&
    secureMeshCapabilityCardSource.includes("secure-mesh-negotiated-protocol-capabilities") &&
    !secureMeshCapabilityCardSource.includes("securityTier") &&
    !secureMeshCapabilityCardSource.includes("securityLevel") &&
    !secureMeshCapabilityCardSource.includes("productionReady"),
    "Secure Mesh capability projection must flow through native FFI into strict Dart contracts and exact-set UI"
  );
  return { mobileRelayServiceSource, secureMeshControllerSource, mobileRelayGatewayAdapterSource };
}
