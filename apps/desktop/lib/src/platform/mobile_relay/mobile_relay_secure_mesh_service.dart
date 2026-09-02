import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_conversation_operations.dart';
import 'package:licoup/src/platform/mobile_relay/secure_mesh_protocol_operations.dart';
import 'package:licoup/src/platform/mobile_relay/secure_mesh_substrate_operations.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

export 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_result_reducer.dart'
    show resolveSecureAgentSessionListResult, resolveSecureRelayPollResult;

/// Compatibility facade over independently injectable Secure Relay,
/// MLS/KT protocol, and file/approval substrate components.
final class MobileRelaySecureMeshOperations {
  const MobileRelaySecureMeshOperations({
    MobileRelaySecureConversationOperations conversationOperations =
        const MobileRelaySecureConversationOperations(),
    SecureMeshProtocolOperations protocolOperations =
        const SecureMeshProtocolOperations(),
    SecureMeshSubstrateOperations substrateOperations =
        const SecureMeshSubstrateOperations(),
  }) : _conversationOperations = conversationOperations,
       _protocolOperations = protocolOperations,
       _substrateOperations = substrateOperations;

  final MobileRelaySecureConversationOperations _conversationOperations;
  final SecureMeshProtocolOperations _protocolOperations;
  final SecureMeshSubstrateOperations _substrateOperations;

  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentCommandRunner agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.sendSecureAgentMessage(
    agentService: agentService,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    model: model,
    reasoningEffort: reasoningEffort,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.listSecureAgentSessions(
    agentId: agentId,
    limit: limit,
    offset: offset,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentCommandRunner agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.describeSecureAgentSession(
    agentId: agentId,
    sessionId: sessionId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> describeSecureAgentSessionPage({
    required AgentCommandRunner agentService,
    required String agentId,
    required String sessionId,
    String messageBefore = '',
    required int messageLimit,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.describeSecureAgentSessionPage(
    agentId: agentId,
    sessionId: sessionId,
    messageBefore: messageBefore,
    messageLimit: messageLimit,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentCommandRunner agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorize = false,
  }) => _conversationOperations.secureMeshStatus(
    agentService: agentService,
    bridge: bridge,
    authorize: authorize,
  );

  Future<Map<String, dynamic>> secureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.secureMeshAndroidRuntimeStatus(bridge: bridge);

  Future<Map<String, dynamic>> writeSecureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _conversationOperations.writeSecureMeshAndroidRuntimeStatus(
    bridge: bridge,
  );

  Future<SecureMeshMlsResponse> executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _protocolOperations.executeSecureMeshMlsRequest(
    request: request,
    bridge: bridge,
  );

  Future<SecureMeshKtResponse> executeSecureMeshKtRequest({
    required SecureMeshKtRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _protocolOperations.executeSecureMeshKtRequest(
    request: request,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) => _substrateOperations.executeSecureMeshCommand(
    agentService: agentService,
    payload: payload,
    context: context,
    ledgerPath: ledgerPath,
    completedAt: completedAt,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) => _substrateOperations.evaluateSecureMeshDeviceTrust(
    agentService: agentService,
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshFileRoute(
    agentService: agentService,
    manifest: manifest,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshFileReceiveDestination(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveConfirmation({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    bool userConfirmed = false,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshFileReceiveConfirmation(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    userConfirmed: userConfirmed,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalRequest({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshApprovalRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalFanout({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshApprovalFanout(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> resolveSecureMeshApproval({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.resolveSecureMeshApproval(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    decision: decision,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureMeshApprovalInbox({
    required AgentCommandRunner agentService,
    bool includeResolved = true,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.listSecureMeshApprovalInbox(
    agentService: agentService,
    includeResolved: includeResolved,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalAdapterCapability({
    required AgentCommandRunner agentService,
    required String agentId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _substrateOperations.evaluateSecureMeshApprovalAdapterCapability(
    agentService: agentService,
    agentId: agentId,
    bridge: bridge,
  );
}
