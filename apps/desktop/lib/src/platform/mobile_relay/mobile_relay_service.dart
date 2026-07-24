import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_mesh_service.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service_ops.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

export 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
export 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
export 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_mesh_service.dart'
    show resolveSecureAgentSessionListResult, resolveSecureRelayPollResult;

/// Stable application-facing facade for independently testable relay and
/// Secure Mesh platform components.
class MobileRelayService {
  const MobileRelayService({
    MobileRelayOperations relayOperations = const MobileRelayOperations(),
    MobileRelaySecureMeshOperations secureMeshOperations =
        const MobileRelaySecureMeshOperations(),
  }) : _relayOperations = relayOperations,
       _secureMeshOperations = secureMeshOperations;

  final MobileRelayOperations _relayOperations;
  final MobileRelaySecureMeshOperations _secureMeshOperations;

  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) => _relayOperations.loadConfig(
    agentService: agentService,
    bridge: bridge,
    authorizeSecrets: authorizeSecrets,
  );

  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _relayOperations.saveConfig(
    agentService: agentService,
    config: config,
    bridge: bridge,
  );

  Future<MobileRelayConfig> resetPairing({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) =>
      _relayOperations.resetPairing(agentService: agentService, bridge: bridge);

  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _relayOperations.configureGateway(
    agentService: agentService,
    useCustomGateway: useCustomGateway,
    customGatewayUrl: customGatewayUrl,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) => _relayOperations.createPairing(agentService: agentService);

  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _relayOperations.refreshPairingStatus(
    agentService: agentService,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> syncCommands({
    required AgentService agentService,
    bool allowInteraction = true,
  }) => _relayOperations.syncCommands(
    agentService: agentService,
    allowInteraction: allowInteraction,
  );

  Future<Map<String, dynamic>> claimPairing({
    required AgentService agentService,
    required Map<String, dynamic> invite,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _relayOperations.claimPairing(
    agentService: agentService,
    invite: invite,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> openExternalUrl({
    required AgentService agentService,
    required String url,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _relayOperations.openExternalUrl(
    agentService: agentService,
    url: url,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.sendSecureAgentMessage(
    agentService: agentService,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    model: model,
    reasoningEffort: reasoningEffort,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.listSecureAgentSessions(
    agentService: agentService,
    agentId: agentId,
    limit: limit,
    offset: offset,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.describeSecureAgentSession(
    agentService: agentService,
    agentId: agentId,
    sessionId: sessionId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorize = false,
  }) => _secureMeshOperations.secureMeshStatus(
    agentService: agentService,
    bridge: bridge,
    authorize: authorize,
  );

  Future<Map<String, dynamic>> secureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.secureMeshAndroidRuntimeStatus(bridge: bridge);

  Future<Map<String, dynamic>> writeSecureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) =>
      _secureMeshOperations.writeSecureMeshAndroidRuntimeStatus(bridge: bridge);

  Future<SecureMeshMlsResponse> executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.executeSecureMeshMlsRequest(
    request: request,
    bridge: bridge,
  );

  Future<SecureMeshKtResponse> executeSecureMeshKtRequest({
    required AgentService agentService,
    required SecureMeshKtRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.executeSecureMeshKtRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentService agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) => _secureMeshOperations.executeSecureMeshCommand(
    agentService: agentService,
    payload: payload,
    context: context,
    ledgerPath: ledgerPath,
    completedAt: completedAt,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentService agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) => _secureMeshOperations.evaluateSecureMeshDeviceTrust(
    agentService: agentService,
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshFileRoute(
    agentService: agentService,
    manifest: manifest,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshFileReceiveDestination(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveConfirmation({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    bool userConfirmed = false,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshFileReceiveConfirmation(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    userConfirmed: userConfirmed,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalRequest({
    required AgentService agentService,
    required Map<String, dynamic> request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshApprovalRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalFanout({
    required AgentService agentService,
    required String pendingOperationId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshApprovalFanout(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> resolveSecureMeshApproval({
    required AgentService agentService,
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.resolveSecureMeshApproval(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    decision: decision,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureMeshApprovalInbox({
    required AgentService agentService,
    bool includeResolved = true,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.listSecureMeshApprovalInbox(
    agentService: agentService,
    includeResolved: includeResolved,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalAdapterCapability({
    required AgentService agentService,
    required String agentId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _secureMeshOperations.evaluateSecureMeshApprovalAdapterCapability(
    agentService: agentService,
    agentId: agentId,
    bridge: bridge,
  );
}
