import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

/// Owns the independent KT and MLS protocol action projections.
final class SecureMeshProtocolController extends ApplicationStateOwner {
  SecureMeshProtocolController({
    required SecureMeshGateway gateway,
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusReporter report,
    required DateTime Function() now,
  }) : _gateway = gateway,
       _operationGate = operationGate,
       _report = report,
       _now = now;

  final SecureMeshGateway _gateway;
  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusReporter _report;
  final DateTime Function() _now;

  SecureMeshProtocolActionState? _ktState;
  SecureMeshProtocolActionState? _mlsState;

  SecureMeshProtocolActionState? get ktState => _ktState;
  SecureMeshProtocolActionState? get mlsState => _mlsState;

  Future<SecureMeshMlsResponse?> executeMls(
    SecureMeshMlsRequest request,
  ) async {
    if (!_operationGate.tryAcquire()) return null;
    publishChange();
    try {
      final response = await _gateway.executeMls(request);
      _mlsState = _state(request.action.wireName, true);
      _report('Secure Mesh MLS 操作已完成。', 'Secure Mesh MLS action completed.');
      return response;
    } catch (_) {
      _mlsState = _state(
        request.action.wireName,
        false,
        'secure_mesh_mls_action_failed',
      );
      _report(
        'Secure Mesh MLS 操作失败。',
        'Secure Mesh MLS action failed.',
        errorCode: 'secure_mesh_mls_action_failed',
      );
      return null;
    } finally {
      _operationGate.release();
      publishChange();
    }
  }

  Future<SecureMeshKtResponse?> executeKt(SecureMeshKtRequest request) async {
    if (!_operationGate.tryAcquire()) return null;
    publishChange();
    try {
      final response = await _gateway.executeKt(request);
      _ktState = _state(request.action.wireName, true);
      _report('Secure Mesh KT 操作已完成。', 'Secure Mesh KT action completed.');
      return response;
    } catch (_) {
      _ktState = _state(
        request.action.wireName,
        false,
        'secure_mesh_kt_action_failed',
      );
      _report(
        'Secure Mesh KT 操作失败。',
        'Secure Mesh KT action failed.',
        errorCode: 'secure_mesh_kt_action_failed',
      );
      return null;
    } finally {
      _operationGate.release();
      publishChange();
    }
  }

  SecureMeshProtocolActionState _state(
    String action,
    bool succeeded, [
    String errorCode = '',
  ]) => SecureMeshProtocolActionState(
    action: action,
    succeeded: succeeded,
    updatedAt: _now().toUtc().toIso8601String(),
    errorCode: errorCode,
  );
}
