import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';
import 'package:flutter_client/src/contracts/secure_mesh_capability_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_kt_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_mls_models.dart';
import 'package:flutter_client/src/contracts/skill_hub.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart'
    as platform;
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_capability_service.dart';

/// Application composition adapter around the stable platform facade.
final class MobileRelayGatewayAdapter
    implements MobileRelayGateway, SecureMeshGateway {
  const MobileRelayGatewayAdapter({
    required platform.MobileRelayService relayService,
    required AgentService agentService,
    required SecureMeshCapabilityService capabilityService,
  }) : _relayService = relayService,
       _agentService = agentService,
       _capabilityService = capabilityService;

  final platform.MobileRelayService _relayService;
  final AgentService _agentService;
  final SecureMeshCapabilityService _capabilityService;

  @override
  Future<MobileRelayConfig> loadConfig({bool authorizeSecrets = false}) =>
      _relayService.loadConfig(
        agentService: _agentService,
        authorizeSecrets: authorizeSecrets,
      );

  @override
  Future<void> saveConfig(MobileRelayConfig config) =>
      _relayService.saveConfig(agentService: _agentService, config: config);

  @override
  Future<MobileRelayConfig> configureGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) => _relayService.configureGateway(
    agentService: _agentService,
    useCustomGateway: useCustomGateway,
    customGatewayUrl: customGatewayUrl,
  );

  @override
  Future<Map<String, dynamic>> createPairing() =>
      _relayService.createPairing(agentService: _agentService);

  @override
  Future<Map<String, dynamic>> refreshPairingStatus() =>
      _relayService.refreshPairingStatus(agentService: _agentService);

  @override
  Future<Map<String, dynamic>> claimPairing(Map<String, dynamic> invite) =>
      _relayService.claimPairing(agentService: _agentService, invite: invite);

  @override
  Future<Map<String, dynamic>> syncCommands({
    required bool allowInteraction,
  }) async {
    try {
      return await _relayService.syncCommands(
        agentService: _agentService,
        allowInteraction: allowInteraction,
      );
    } on LicoClientRpcException catch (error) {
      if (error.authorizationRequired) {
        throw const MobileRelayAuthorizationRequired();
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
  }) => _relayService.executeSecureMeshCommand(
    agentService: _agentService,
    payload: payload,
    context: context,
  );

  @override
  Future<Map<String, dynamic>> status({required bool authorize}) =>
      _relayService.secureMeshStatus(
        agentService: _agentService,
        authorize: authorize,
      );

  @override
  SecureMeshCapabilityProjection? projectStatus(Map<String, dynamic> status) =>
      _capabilityService.projectStatus(status);

  @override
  Future<Map<String, dynamic>> evaluateDeviceTrust({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    required String trustState,
    required bool requireVerifiedDevice,
    required bool allowUnverifiedReadOnly,
  }) => _relayService.evaluateSecureMeshDeviceTrust(
    agentService: _agentService,
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  @override
  Future<Map<String, dynamic>> evaluateFileRoute(
    Map<String, dynamic> manifest,
  ) => _relayService.evaluateSecureMeshFileRoute(
    agentService: _agentService,
    manifest: manifest,
  );

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
  }) => _relayService.evaluateSecureMeshFileReceiveDestination(
    agentService: _agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
  );

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveConfirmation({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required bool userConfirmed,
  }) => _relayService.evaluateSecureMeshFileReceiveConfirmation(
    agentService: _agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    userConfirmed: userConfirmed,
  );

  @override
  Future<Map<String, dynamic>> evaluateApprovalAdapterCapability(
    String agentId,
  ) => _relayService.evaluateSecureMeshApprovalAdapterCapability(
    agentService: _agentService,
    agentId: agentId,
  );

  @override
  Future<Map<String, dynamic>> evaluateApprovalRequest(
    Map<String, dynamic> request,
  ) => _relayService.evaluateSecureMeshApprovalRequest(
    agentService: _agentService,
    request: request,
  );

  @override
  Future<Map<String, dynamic>> evaluateApprovalFanout(
    String pendingOperationId,
  ) => _relayService.evaluateSecureMeshApprovalFanout(
    agentService: _agentService,
    pendingOperationId: pendingOperationId,
  );

  @override
  Future<Map<String, dynamic>> listApprovalInbox({
    required bool includeResolved,
  }) => _relayService.listSecureMeshApprovalInbox(
    agentService: _agentService,
    includeResolved: includeResolved,
  );

  @override
  Future<Map<String, dynamic>> resolveApproval({
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
  }) => _relayService.resolveSecureMeshApproval(
    agentService: _agentService,
    pendingOperationId: pendingOperationId,
    decision: decision,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
  );

  @override
  Future<SecureMeshMlsResponse> executeMls(SecureMeshMlsRequest request) =>
      _relayService.executeSecureMeshMlsRequest(request: request);

  @override
  Future<SecureMeshKtResponse> executeKt(SecureMeshKtRequest request) =>
      _relayService.executeSecureMeshKtRequest(
        agentService: _agentService,
        request: request,
      );
}

final class SecureMeshSkillInstallGatewayAdapter
    implements SecureMeshSkillInstallGateway {
  const SecureMeshSkillInstallGatewayAdapter(this._gateway);

  final SkillHubGateway _gateway;

  @override
  Future<Map<String, dynamic>> applyInstall({
    required String agent,
    required String sourcePath,
    required String name,
    required bool pin,
  }) => _gateway.applySkillInstall(
    agent: agent,
    sourcePath: sourcePath,
    name: name,
    pin: pin,
  );
}
