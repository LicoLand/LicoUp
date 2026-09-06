import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:licoup/src/application/features/mobile_relay/policy/secure_mesh_policy.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

/// Owns Secure Mesh runtime status, capability projection, and device trust.
final class SecureMeshStatusController extends ApplicationStateOwner {
  SecureMeshStatusController({
    required SecureMeshGateway gateway,
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusReporter report,
  }) : _gateway = gateway,
       _operationGate = operationGate,
       _report = report;

  final SecureMeshGateway _gateway;
  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusReporter _report;

  Map<String, dynamic>? _status;
  SecureMeshCapabilityProjection? _capabilityProjection;
  Map<String, dynamic>? _deviceTrustPolicy;

  Map<String, dynamic>? get status => _status;
  SecureMeshCapabilityProjection? get capabilityProjection =>
      _capabilityProjection;
  Map<String, dynamic>? get deviceTrustPolicy => _deviceTrustPolicy;

  void replaceStatus(Map<String, dynamic>? value) {
    _status = value == null ? null : SecureMeshPolicy.statusProjection(value);
    publishChange();
  }

  void replaceCapabilityProjection(SecureMeshCapabilityProjection? value) {
    _capabilityProjection = value;
    publishChange();
  }

  void replaceDeviceTrustPolicy(Map<String, dynamic>? value) {
    _deviceTrustPolicy = value == null
        ? null
        : SecureMeshPolicy.deviceTrustProjection(value);
    publishChange();
  }

  Future<void> refreshStatus({
    bool authorize = true,
    bool showProgress = true,
  }) async {
    if (!_operationGate.tryAcquire()) return;
    if (showProgress) {
      _report('正在刷新 Secure Mesh 状态。', 'Refreshing Secure Mesh status.');
    }
    publishChange();
    try {
      final raw = await _gateway.status(authorize: authorize);
      _capabilityProjection = _gateway.projectStatus(raw);
      _status = SecureMeshPolicy.statusProjection(raw);
      if (showProgress) {
        _report('Secure Mesh 状态已刷新。', 'Secure Mesh status refreshed.');
      }
    } catch (_) {
      _status = const {
        'ok': false,
        'errorCode': 'secure_mesh_status_refresh_failed',
      };
      _capabilityProjection = null;
      if (showProgress) {
        _report(
          'Secure Mesh 状态刷新失败。',
          'Failed to refresh Secure Mesh status.',
          errorCode: 'secure_mesh_status_refresh_failed',
        );
      }
    } finally {
      _operationGate.release();
      publishChange();
    }
  }

  Future<void> evaluateDeviceTrust({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) async {
    if (!_operationGate.tryAcquire()) return;
    _report(
      '正在评估 Secure Mesh 设备信任策略。',
      'Evaluating the Secure Mesh device trust policy.',
    );
    publishChange();
    try {
      _deviceTrustPolicy = SecureMeshPolicy.deviceTrustProjection(
        await _gateway.evaluateDeviceTrust(
          identity: identity,
          previousIdentity: previousIdentity,
          trustState: trustState,
          requireVerifiedDevice: requireVerifiedDevice,
          allowUnverifiedReadOnly: allowUnverifiedReadOnly,
        ),
      );
      _report(
        'Secure Mesh 设备信任策略已评估。',
        'Secure Mesh device trust policy evaluated.',
      );
    } catch (_) {
      _deviceTrustPolicy = const {
        'ok': false,
        'errorCode': 'secure_mesh_device_trust_failed',
      };
      _report(
        'Secure Mesh 设备信任策略评估失败。',
        'Failed to evaluate the Secure Mesh device trust policy.',
        errorCode: 'secure_mesh_device_trust_failed',
      );
    } finally {
      _operationGate.release();
      publishChange();
    }
  }
}
