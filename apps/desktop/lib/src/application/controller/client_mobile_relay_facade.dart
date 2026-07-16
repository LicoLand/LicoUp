import 'package:flutter_client/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_pairing_presentation.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_approval_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_capability_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_file_sync_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_skill_sync_models.dart';

mixin ClientMobileRelayFacade on AgentWorkspaceCoordinator {
  MobileHomeLayoutController get mobileHomeLayoutController;
  MobileRelayController get mobileRelayController;
  SecureMeshController get secureMeshController;

  MobileRelayConfig get mobileRelayConfig => mobileRelayController.config;

  set mobileRelayConfig(MobileRelayConfig value) {
    mobileRelayController.replaceConfig(value);
  }

  Map<String, dynamic>? get mobileRelayActionResult =>
      mobileRelayController.actionResult;

  set mobileRelayActionResult(Map<String, dynamic>? value) {
    mobileRelayController.replaceActionResult(value);
  }

  MobilePairingPresentation? get mobilePairingPresentation =>
      mobileRelayController.pairingPresentation;

  Map<String, dynamic>? get secureMeshStatus => secureMeshController.status;

  set secureMeshStatus(Map<String, dynamic>? value) {
    secureMeshController.replaceStatus(value);
  }

  SecureMeshCapabilityProjection? get secureMeshCapabilityProjection =>
      secureMeshController.capabilityProjection;

  set secureMeshCapabilityProjection(SecureMeshCapabilityProjection? value) {
    secureMeshController.replaceCapabilityProjection(value);
  }

  Map<String, dynamic>? get secureMeshDeviceTrustPolicy =>
      secureMeshController.deviceTrustPolicy;

  set secureMeshDeviceTrustPolicy(Map<String, dynamic>? value) {
    secureMeshController.replaceDeviceTrustPolicy(value);
  }

  Map<String, dynamic>? get secureMeshFileRoute =>
      secureMeshController.fileRoute;

  set secureMeshFileRoute(Map<String, dynamic>? value) {
    secureMeshController.replaceFileRoute(value);
  }

  Map<String, dynamic>? get secureMeshFileReceiveDestination =>
      secureMeshController.fileDestination;

  set secureMeshFileReceiveDestination(Map<String, dynamic>? value) {
    secureMeshController.replaceFileDestination(value);
  }

  Map<String, dynamic>? get secureMeshFileReceiveConfirmation =>
      secureMeshController.fileConfirmation;

  set secureMeshFileReceiveConfirmation(Map<String, dynamic>? value) {
    secureMeshController.replaceFileConfirmation(value);
  }

  List<SecureMeshFileSyncTransfer> get secureMeshFileSyncTransfers =>
      secureMeshController.fileTransfers;

  set secureMeshFileSyncTransfers(List<SecureMeshFileSyncTransfer> value) {
    secureMeshController.replaceFileTransfers(value);
  }

  SecureMeshFileSyncTransfer? get secureMeshFileSyncDraft =>
      secureMeshController.fileDraft;

  set secureMeshFileSyncDraft(SecureMeshFileSyncTransfer? value) {
    secureMeshController.replaceFileDraft(value);
  }

  List<SecureMeshSkillSyncTransfer> get secureMeshSkillSyncTransfers =>
      secureMeshController.skillTransfers;

  set secureMeshSkillSyncTransfers(List<SecureMeshSkillSyncTransfer> value) {
    secureMeshController.replaceSkillTransfers(value);
  }

  SecureMeshSkillSyncTransfer? get secureMeshSkillSyncDraft =>
      secureMeshController.skillDraft;

  set secureMeshSkillSyncDraft(SecureMeshSkillSyncTransfer? value) {
    secureMeshController.replaceSkillDraft(value);
  }

  @override
  List<SecureMeshApprovalRequest> get secureMeshApprovalInbox =>
      secureMeshController.approvalInbox;

  @override
  set secureMeshApprovalInbox(List<SecureMeshApprovalRequest> value) {
    secureMeshController.replaceApprovalInbox(value);
  }

  Map<String, dynamic>? get secureMeshApprovalLastAction =>
      secureMeshController.approvalLastAction;

  set secureMeshApprovalLastAction(Map<String, dynamic>? value) {
    secureMeshController.replaceApprovalLastAction(value);
  }

  Map<String, dynamic>? get secureMeshApprovalAdapterCapability =>
      secureMeshController.approvalAdapterCapability;

  set secureMeshApprovalAdapterCapability(Map<String, dynamic>? value) {
    secureMeshController.replaceApprovalAdapterCapability(value);
  }

  MobileHomeLayout get mobileHomeLayout => mobileHomeLayoutController.layout;

  set mobileHomeLayout(MobileHomeLayout value) {
    mobileHomeLayoutController.replaceLayout(value);
  }

  List<Map<String, dynamic>> get lastSecureMeshCommandExecutions =>
      mobileRelayController.secureExecutions;
  List<MobileRelayCommand> get lastMobileRelayCommands =>
      mobileRelayController.commands;
  bool get isMobileRelayBusy => mobileRelayController.busy;
  bool get isMobileRelayPolling => mobileRelayController.polling;
  Future<void> configureMobileRelayGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  }) => mobileRelayController.configureGateway(
    useCustomGateway: useCustomGateway,
    customGatewayUrl: customGatewayUrl,
  );

  Future<void> createMobilePairing() => mobileRelayController.createPairing();

  void dismissMobilePairingPresentation() =>
      mobileRelayController.dismissPairingPresentation();

  Future<bool> copyMobilePairingCode(String code) =>
      mobileRelayController.copyPairingCode(code);

  Future<void> refreshMobilePairingStatus() =>
      mobileRelayController.refreshPairingStatus();

  Future<void> claimMobilePairingInvite(String inviteText) =>
      mobileRelayController.claimPairingInvite(inviteText);

  Future<void> selectMobileRelayDevice(String deviceId) =>
      mobileRelayController.selectDevice(deviceId);

  void startMobileRelayPolling() => mobileRelayController.startPolling();

  void stopMobileRelayPolling() => mobileRelayController.stopPolling();

  Future<void> pollMobileRelayOnce({bool showProgress = false}) =>
      mobileRelayController.pollOnce(showProgress: showProgress);

  Future<void> refreshSecureMeshStatus({bool authorize = true}) =>
      secureMeshController.refreshStatus(authorize: authorize);

  Future<void> evaluateSecureMeshDeviceTrustPolicy({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) => secureMeshController.evaluateDeviceTrust(
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  Future<void> evaluateSecureMeshFileRoute({
    required Map<String, dynamic> manifest,
  }) => secureMeshController.evaluateFileRoute(manifest);

  Future<void> evaluateSecureMeshFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
  }) => secureMeshController.evaluateFileReceiveDestination(
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
  );

  void setSecureMeshFileSyncDraft({
    required String fileName,
    required int totalSize,
    String mimeType = 'application/octet-stream',
    String relativePath = '.',
    String conflictPolicy = 'fail_if_exists',
  }) => secureMeshController.setFileDraft(
    fileName: fileName,
    totalSize: totalSize,
    mimeType: mimeType,
    relativePath: relativePath,
    conflictPolicy: conflictPolicy,
  );

  void setSecureMeshFileSyncDestination(String destinationRoot) =>
      secureMeshController.setFileDestination(destinationRoot);

  Future<void> prepareSecureMeshFileSyncTransfer() =>
      secureMeshController.prepareFileTransfer();

  Future<void> confirmSecureMeshFileSyncReceive({
    required bool userConfirmed,
  }) => secureMeshController.confirmFileReceive(userConfirmed: userConfirmed);

  void beginSecureMeshSkillSyncDraft({
    required String skillId,
    required String version,
    required String sourceAgentId,
    required String targetAgentId,
    required String packageDigest,
    required String packageFileName,
    required int packageSize,
    String mimeType = 'application/zip',
    bool activate = false,
  }) => secureMeshController.beginSkillDraft(
    skillId: skillId,
    version: version,
    sourceAgentId: sourceAgentId,
    targetAgentId: targetAgentId,
    packageDigest: packageDigest,
    packageFileName: packageFileName,
    packageSize: packageSize,
    mimeType: mimeType,
    activate: activate,
  );

  Future<void> prepareSecureMeshSkillSyncTransfer() =>
      secureMeshController.prepareSkillTransfer();

  Future<void> confirmSecureMeshSkillSyncInstall({
    required bool userConfirmed,
  }) => secureMeshController.confirmSkillInstall(userConfirmed: userConfirmed);

  Future<void> ingestSecureMeshApprovalRequest({
    required String pendingOperationId,
    required String requesterAgentId,
    required String targetClientId,
    required String originEndpointId,
    required String displaySummary,
    required String adapterCallbackTokenRef,
    required String responseNonce,
    required String expiresAt,
    required List<String> trustedEndpointIds,
    String riskLevel = 'local_effect',
    String policyReason = '',
    String adapterStyle = 'callback',
    List<String> requestedTools = const [],
  }) => secureMeshController.ingestApproval(
    pendingOperationId: pendingOperationId,
    requesterAgentId: requesterAgentId,
    targetClientId: targetClientId,
    originEndpointId: originEndpointId,
    displaySummary: displaySummary,
    adapterCallbackTokenRef: adapterCallbackTokenRef,
    responseNonce: responseNonce,
    expiresAt: expiresAt,
    trustedEndpointIds: trustedEndpointIds,
    riskLevel: riskLevel,
    policyReason: policyReason,
    adapterStyle: adapterStyle,
    requestedTools: requestedTools,
  );

  @override
  Future<void> refreshSecureMeshApprovalInbox({bool includeResolved = true}) =>
      secureMeshController.refreshApprovalInbox(
        includeResolved: includeResolved,
      );

  Future<void> resolveSecureMeshApproval({
    required String pendingOperationId,
    required bool allow,
    required String respondingEndpointId,
    required String responseNonce,
  }) => secureMeshController.resolveApproval(
    pendingOperationId: pendingOperationId,
    allow: allow,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
  );

  @override
  String get relaySourceClientId => mobileRelayConfig.pcClientId;

  @override
  String get relaySourceClientLabel => mobileRelayConfig.pcClientName;

  Future<void> reorderMobileHomePinnedEntries(
    List<String> pinnedEntryIds,
    int oldIndex,
    int newIndex,
  ) => mobileHomeLayoutController.reorderPinnedEntries(
    pinnedEntryIds,
    oldIndex,
    newIndex,
  );

  Future<void> toggleMobileHomeEntryPinned(String entryId) =>
      mobileHomeLayoutController.togglePinned(entryId);
}
