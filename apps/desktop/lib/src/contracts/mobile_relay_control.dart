import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

final class MobileRelayOperationGate {
  bool _busy = false;

  bool get busy => _busy;

  bool tryAcquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  void release() {
    _busy = false;
  }
}

final class MobileRelayFeatureStatus {
  const MobileRelayFeatureStatus({
    required this.chinese,
    required this.english,
    required this.caption,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String caption;
  final String errorCode;
}

typedef MobileRelayFeatureStatusSink =
    void Function(MobileRelayFeatureStatus status);

final class MobileRelayAuthorizationRequired implements Exception {
  const MobileRelayAuthorizationRequired();
}

final class SecureMeshCommandExecutionRequest {
  const SecureMeshCommandExecutionRequest({
    required this.payload,
    required this.context,
  });

  final Map<String, dynamic> payload;
  final Map<String, dynamic> context;
}

final class SecureMeshProtocolActionState {
  const SecureMeshProtocolActionState({
    required this.action,
    required this.succeeded,
    required this.updatedAt,
    this.errorCode = '',
  });

  final String action;
  final bool succeeded;
  final String updatedAt;
  final String errorCode;
}

abstract interface class MobileRelayGateway {
  Future<MobileRelayConfig> loadConfig({bool authorizeSecrets = false});
  Future<void> saveConfig(MobileRelayConfig config);
  Future<MobileRelayConfig> configureGateway({
    required bool useCustomGateway,
    required String customGatewayUrl,
  });
  Future<Map<String, dynamic>> createPairing();
  Future<Map<String, dynamic>> refreshPairingStatus();
  Future<Map<String, dynamic>> claimPairing(Map<String, dynamic> invite);
  Future<Map<String, dynamic>> syncCommands({required bool allowInteraction});
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
  });
}

abstract interface class SecureMeshGateway {
  Future<Map<String, dynamic>> status({required bool authorize});
  SecureMeshCapabilityProjection? projectStatus(Map<String, dynamic> status);
  Future<Map<String, dynamic>> evaluateDeviceTrust({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    required String trustState,
    required bool requireVerifiedDevice,
    required bool allowUnverifiedReadOnly,
  });
  Future<Map<String, dynamic>> evaluateFileRoute(Map<String, dynamic> manifest);
  Future<Map<String, dynamic>> evaluateFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
  });
  Future<Map<String, dynamic>> evaluateFileReceiveConfirmation({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required bool userConfirmed,
  });
  Future<Map<String, dynamic>> evaluateApprovalAdapterCapability(
    String agentId,
  );
  Future<Map<String, dynamic>> evaluateApprovalRequest(
    Map<String, dynamic> request,
  );
  Future<Map<String, dynamic>> evaluateApprovalFanout(
    String pendingOperationId,
  );
  Future<Map<String, dynamic>> listApprovalInbox({
    required bool includeResolved,
  });
  Future<Map<String, dynamic>> resolveApproval({
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
  });
  Future<SecureMeshMlsResponse> executeMls(SecureMeshMlsRequest request);
  Future<SecureMeshKtResponse> executeKt(SecureMeshKtRequest request);
}

abstract interface class SecureMeshSkillInstallGateway {
  Future<Map<String, dynamic>> applyInstall({
    required String agent,
    required String sourcePath,
    required String name,
    required bool pin,
  });
}
