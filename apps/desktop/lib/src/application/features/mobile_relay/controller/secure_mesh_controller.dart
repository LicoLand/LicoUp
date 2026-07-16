import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_approval_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_file_transfer_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_protocol_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_skill_transfer_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_status_controller.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';
import 'package:flutter_client/src/contracts/secure_mesh_approval_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_capability_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_file_sync_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_kt_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_mls_models.dart';
import 'package:flutter_client/src/contracts/secure_mesh_skill_sync_models.dart';

/// Stable facade over independent Secure Mesh application components.
final class SecureMeshController extends ChangeNotifier {
  factory SecureMeshController({
    required SecureMeshGateway gateway,
    required SecureMeshSkillInstallGateway skillInstaller,
    required MobileRelayOperationGate operationGate,
    required MobileRelayFeatureStatusSink onStatus,
    required void Function(Map<String, dynamic>? result) onSkillInstallResult,
    DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    final reporter = SecureMeshStatusReporter(onStatus);
    final fileController = SecureMeshFileTransferController(
      gateway: gateway,
      operationGate: operationGate,
      report: reporter,
      now: clock,
    );
    return SecureMeshController._(
      operationGate: operationGate,
      statusController: SecureMeshStatusController(
        gateway: gateway,
        operationGate: operationGate,
        report: reporter,
      ),
      fileController: fileController,
      skillController: SecureMeshSkillTransferController(
        skillInstaller: skillInstaller,
        fileController: fileController,
        operationGate: operationGate,
        report: reporter,
        onInstallResult: onSkillInstallResult,
        now: clock,
      ),
      approvalController: SecureMeshApprovalController(
        gateway: gateway,
        operationGate: operationGate,
        report: reporter,
      ),
      protocolController: SecureMeshProtocolController(
        gateway: gateway,
        operationGate: operationGate,
        report: reporter,
        now: clock,
      ),
    );
  }

  SecureMeshController._({
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusController statusController,
    required SecureMeshFileTransferController fileController,
    required SecureMeshSkillTransferController skillController,
    required SecureMeshApprovalController approvalController,
    required SecureMeshProtocolController protocolController,
  }) : _operationGate = operationGate,
       _statusController = statusController,
       _fileController = fileController,
       _skillController = skillController,
       _approvalController = approvalController,
       _protocolController = protocolController {
    for (final component in _components) {
      component.addListener(_notifyChanged);
    }
  }

  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusController _statusController;
  final SecureMeshFileTransferController _fileController;
  final SecureMeshSkillTransferController _skillController;
  final SecureMeshApprovalController _approvalController;
  final SecureMeshProtocolController _protocolController;

  List<ChangeNotifier> get _components => [
    _statusController,
    _fileController,
    _skillController,
    _approvalController,
    _protocolController,
  ];

  bool get busy => _operationGate.busy;
  Map<String, dynamic>? get status => _statusController.status;
  SecureMeshCapabilityProjection? get capabilityProjection =>
      _statusController.capabilityProjection;
  Map<String, dynamic>? get deviceTrustPolicy =>
      _statusController.deviceTrustPolicy;
  Map<String, dynamic>? get fileRoute => _fileController.route;
  Map<String, dynamic>? get fileDestination => _fileController.destination;
  Map<String, dynamic>? get fileConfirmation => _fileController.confirmation;
  List<SecureMeshFileSyncTransfer> get fileTransfers =>
      _fileController.transfers;
  SecureMeshFileSyncTransfer? get fileDraft => _fileController.draft;
  List<SecureMeshSkillSyncTransfer> get skillTransfers =>
      _skillController.transfers;
  SecureMeshSkillSyncTransfer? get skillDraft => _skillController.draft;
  List<SecureMeshApprovalRequest> get approvalInbox =>
      _approvalController.inbox;
  Map<String, dynamic>? get approvalLastAction =>
      _approvalController.lastAction;
  Map<String, dynamic>? get approvalAdapterCapability =>
      _approvalController.adapterCapability;
  SecureMeshProtocolActionState? get ktState => _protocolController.ktState;
  SecureMeshProtocolActionState? get mlsState => _protocolController.mlsState;

  void replaceStatus(Map<String, dynamic>? value) =>
      _statusController.replaceStatus(value);

  void replaceCapabilityProjection(SecureMeshCapabilityProjection? value) =>
      _statusController.replaceCapabilityProjection(value);

  void replaceDeviceTrustPolicy(Map<String, dynamic>? value) =>
      _statusController.replaceDeviceTrustPolicy(value);

  void replaceFileRoute(Map<String, dynamic>? value) =>
      _fileController.replaceRoute(value);

  void replaceFileDestination(Map<String, dynamic>? value) =>
      _fileController.replaceDestination(value);

  void replaceFileConfirmation(Map<String, dynamic>? value) =>
      _fileController.replaceConfirmation(value);

  void replaceFileTransfers(List<SecureMeshFileSyncTransfer> value) =>
      _fileController.replaceTransfers(value);

  void replaceFileDraft(SecureMeshFileSyncTransfer? value) =>
      _fileController.replaceDraft(value);

  void replaceSkillTransfers(List<SecureMeshSkillSyncTransfer> value) =>
      _skillController.replaceTransfers(value);

  void replaceSkillDraft(SecureMeshSkillSyncTransfer? value) =>
      _skillController.replaceDraft(value);

  void replaceApprovalInbox(List<SecureMeshApprovalRequest> value) =>
      _approvalController.replaceInbox(value);

  void replaceApprovalLastAction(Map<String, dynamic>? value) =>
      _approvalController.replaceLastAction(value);

  void replaceApprovalAdapterCapability(Map<String, dynamic>? value) =>
      _approvalController.replaceAdapterCapability(value);

  Future<void> refreshStatus({bool authorize = true}) =>
      _statusController.refreshStatus(authorize: authorize);

  Future<void> evaluateDeviceTrust({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) => _statusController.evaluateDeviceTrust(
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  Future<void> evaluateFileRoute(Map<String, dynamic> manifest) =>
      _fileController.evaluateRoute(manifest);

  Future<void> evaluateFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
  }) => _fileController.evaluateReceiveDestination(
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
  );

  void setFileDraft({
    required String fileName,
    required int totalSize,
    String mimeType = 'application/octet-stream',
    String relativePath = '.',
    String conflictPolicy = 'fail_if_exists',
  }) => _fileController.setDraft(
    fileName: fileName,
    totalSize: totalSize,
    mimeType: mimeType,
    relativePath: relativePath,
    conflictPolicy: conflictPolicy,
  );

  void setFileDestination(String destinationRoot) =>
      _fileController.setDestination(destinationRoot);

  Future<void> prepareFileTransfer() => _fileController.prepareTransfer();

  Future<void> confirmFileReceive({required bool userConfirmed}) =>
      _fileController.confirmReceive(userConfirmed: userConfirmed);

  void beginSkillDraft({
    required String skillId,
    required String version,
    required String sourceAgentId,
    required String targetAgentId,
    required String packageDigest,
    required String packageFileName,
    required int packageSize,
    String mimeType = 'application/zip',
    bool activate = false,
  }) => _skillController.beginDraft(
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

  Future<void> prepareSkillTransfer() => _skillController.prepareTransfer();

  Future<void> confirmSkillInstall({required bool userConfirmed}) =>
      _skillController.confirmInstall(userConfirmed: userConfirmed);

  Future<void> ingestApproval({
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
  }) => _approvalController.ingest(
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

  Future<void> refreshApprovalInbox({bool includeResolved = true}) =>
      _approvalController.refreshInbox(includeResolved: includeResolved);

  Future<void> resolveApproval({
    required String pendingOperationId,
    required bool allow,
    String respondingEndpointId = '',
    String responseNonce = '',
  }) => _approvalController.resolve(
    pendingOperationId: pendingOperationId,
    allow: allow,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
  );

  Future<SecureMeshMlsResponse?> executeMls(SecureMeshMlsRequest request) =>
      _protocolController.executeMls(request);

  Future<SecureMeshKtResponse?> executeKt(SecureMeshKtRequest request) =>
      _protocolController.executeKt(request);

  void _notifyChanged() => notifyListeners();

  @override
  void dispose() {
    for (final component in _components) {
      component.removeListener(_notifyChanged);
      component.dispose();
    }
    super.dispose();
  }
}
