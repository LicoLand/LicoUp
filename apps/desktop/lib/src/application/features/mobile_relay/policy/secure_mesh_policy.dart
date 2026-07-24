import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

abstract final class SecureMeshPolicy {
  static const int maximumFileTransfers = 12;
  static const int maximumSkillTransfers = 12;
  static const int maximumApprovals = 24;

  static Map<String, dynamic> statusProjection(Map<String, dynamic> value) =>
      _project(value, _statusKeys);

  static Map<String, dynamic> deviceTrustProjection(
    Map<String, dynamic> value,
  ) => _project(value, _deviceTrustKeys);

  static Map<String, dynamic> fileRouteProjection(Map<String, dynamic> value) =>
      _project(value, _fileRouteKeys);

  static Map<String, dynamic> fileDestinationProjection(
    Map<String, dynamic> value,
  ) => _project(value, _fileDestinationKeys);

  static Map<String, dynamic> fileConfirmationProjection(
    Map<String, dynamic> value,
  ) => _project(value, _fileConfirmationKeys);

  static Map<String, dynamic> approvalCapabilityProjection(
    Map<String, dynamic> value,
  ) => _project(value, _approvalCapabilityKeys);

  static Map<String, dynamic> approvalActionProjection(
    Map<String, dynamic> value,
  ) => _project(value, _approvalActionKeys);

  static Map<String, dynamic> installActionProjection(
    Map<String, dynamic> value,
  ) => _project(value, _installActionKeys);

  static SecureMeshApprovalRequest publicApproval(
    SecureMeshApprovalRequest request,
  ) => request.copyWith(
    originEndpointId: '',
    responseNonce: '',
    adapterCallbackTokenRef: '',
    respondingEndpointId: '',
  );

  static List<SecureMeshFileSyncTransfer> upsertFileTransfer(
    List<SecureMeshFileSyncTransfer> current,
    SecureMeshFileSyncTransfer transfer,
  ) => _bounded([
    for (final item in current)
      if (item.id != transfer.id) item,
    transfer,
  ], maximumFileTransfers);

  static List<SecureMeshSkillSyncTransfer> upsertSkillTransfer(
    List<SecureMeshSkillSyncTransfer> current,
    SecureMeshSkillSyncTransfer transfer,
  ) => _bounded([
    for (final item in current)
      if (item.id != transfer.id) item,
    transfer,
  ], maximumSkillTransfers);

  static List<SecureMeshApprovalRequest> upsertApproval(
    List<SecureMeshApprovalRequest> current,
    SecureMeshApprovalRequest request,
  ) => _bounded([
    for (final item in current)
      if (item.pendingOperationId != request.pendingOperationId) item,
    request,
  ], maximumApprovals);

  static String stableCode(Object? value, {required String fallback}) {
    final candidate = value?.toString().trim().toLowerCase() ?? '';
    return RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)
        ? candidate
        : fallback;
  }

  static List<T> _bounded<T>(List<T> values, int maximum) {
    final start = values.length > maximum ? values.length - maximum : 0;
    return List<T>.unmodifiable(values.sublist(start));
  }

  static Map<String, dynamic> _project(
    Map<String, dynamic> value,
    Set<String> allowedKeys,
  ) {
    final output = <String, dynamic>{};
    for (final entry in value.entries) {
      if (!allowedKeys.contains(entry.key)) continue;
      final projected = _safeValue(entry.value, allowedKeys);
      if (projected != null) output[entry.key] = projected;
    }
    return Map<String, dynamic>.unmodifiable(output);
  }

  static Object? _safeValue(Object? value, Set<String> allowedKeys) {
    if (value == null || value is bool || value is num) return value;
    if (value is String) return value.length <= 512 ? value : null;
    if (value is Map) {
      try {
        return _project(Map<String, dynamic>.from(value), allowedKeys);
      } on TypeError {
        return null;
      }
    }
    if (value is List && value.length <= 64) {
      final result = <Object?>[];
      for (final item in value) {
        final projected = _safeValue(item, allowedKeys);
        if (projected != null) result.add(projected);
      }
      return List<Object?>.unmodifiable(result);
    }
    return null;
  }

  static const Set<String> _commonKeys = {
    'ok',
    'protocolVersion',
    'status',
    'state',
    'code',
    'errorCode',
    'reason',
  };
  static const Set<String> _statusKeys = {
    ..._commonKeys,
    'pairwiseCryptoStatus',
    'mlsCryptoStatus',
    'fileCryptoStatus',
    'commandSecurityStatus',
    'deviceTrustStatus',
    'cryptoCoreStatus',
    'ktStatus',
    'mlsStatus',
    'mobileRelayE2eeStatus',
    'mobileRelayE2eeSecretStore',
    'productionReady',
    'persistentBackend',
    'productionBlocker',
    'available',
    'enabled',
    'supported',
  };
  static const Set<String> _deviceTrustKeys = {
    ..._commonKeys,
    'trustState',
    'requestedTrustState',
    'decision',
    'allowedForPrekey',
    'allowedForHighRiskCommand',
    'allowedForReadOnlyCommand',
  };
  static const Set<String> _fileRouteKeys = {
    ..._commonKeys,
    'route',
    'uploadOperation',
    'fetchOperation',
    'plaintextRelayBlocked',
  };
  static const Set<String> _fileDestinationKeys = {
    ..._commonKeys,
    'receivePolicy',
    'destinationApproved',
    'destinationPathRedacted',
    'conflictPolicy',
    'writeOperation',
  };
  static const Set<String> _fileConfirmationKeys = {
    ..._commonKeys,
    'receiveConfirmation',
    'required',
    'writeAllowed',
    'userConfirmed',
    'autoPreviewEnabled',
    'autoIngestionEnabled',
    'destinationPathRedacted',
  };
  static const Set<String> _approvalCapabilityKeys = {
    ..._commonKeys,
    'approvalsSupported',
    'remoteApprovalBridge',
    'adapterStyle',
  };
  static const Set<String> _approvalActionKeys = {
    ..._commonKeys,
    'plaintextRelayBlocked',
    'trustedEndpointCount',
    'itemCount',
  };
  static const Set<String> _installActionKeys = {
    ..._commonKeys,
    'snapshotId',
    'installed',
    'activated',
  };
}
