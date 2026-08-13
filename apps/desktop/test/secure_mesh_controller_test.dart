import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status failures expose only a stable error code', () async {
    final statuses = <MobileRelayFeatureStatus>[];
    final controller = SecureMeshController(
      gateway: _FailingSecureMeshGateway(),
      operationGate: MobileRelayOperationGate(),
      onStatus: statuses.add,
    );
    addTearDown(controller.dispose);

    await controller.refreshStatus();

    expect(controller.status, const {
      'ok': false,
      'errorCode': 'secure_mesh_status_refresh_failed',
    });
    expect(controller.status.toString(), isNot(contains('sensitive-detail')));
    expect(statuses.last.errorCode, 'secure_mesh_status_refresh_failed');
  });

  test('approval state strips endpoint secrets from its public projection', () {
    final controller = SecureMeshController(
      gateway: _FailingSecureMeshGateway(),
      operationGate: MobileRelayOperationGate(),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    controller.replaceApprovalInbox(const [
      SecureMeshApprovalRequest(
        pendingOperationId: 'operation-1',
        requesterAgentId: 'agent-1',
        targetClientId: 'client-1',
        originEndpointId: 'private-endpoint',
        riskLevel: 'local_effect',
        displaySummary: 'Approve a bounded operation',
        expiresAt: '2026-01-01T00:00:00Z',
        responseNonce: 'private-nonce',
        adapterCallbackTokenRef: 'private-token',
        adapterStyle: 'callback',
        status: SecureMeshApprovalStatus.pending,
      ),
    ]);

    final public = controller.approvalInbox.single;
    expect(public.originEndpointId, isEmpty);
    expect(public.responseNonce, isEmpty);
    expect(public.adapterCallbackTokenRef, isEmpty);
  });
}

final class _FailingSecureMeshGateway implements SecureMeshGateway {
  @override
  Future<Map<String, dynamic>> status({required bool authorize}) async =>
      throw StateError('sensitive-detail');

  @override
  SecureMeshCapabilityProjection? projectStatus(Map<String, dynamic> status) =>
      null;

  @override
  Future<Map<String, dynamic>> evaluateDeviceTrust({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    required String trustState,
    required bool requireVerifiedDevice,
    required bool allowUnverifiedReadOnly,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateFileRoute(
    Map<String, dynamic> manifest,
  ) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveConfirmation({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required bool userConfirmed,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateApprovalAdapterCapability(
    String agentId,
  ) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateApprovalRequest(
    Map<String, dynamic> request,
  ) async => const {};

  @override
  Future<Map<String, dynamic>> evaluateApprovalFanout(
    String pendingOperationId,
  ) async => const {};

  @override
  Future<Map<String, dynamic>> listApprovalInbox({
    required bool includeResolved,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> resolveApproval({
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
  }) async => const {};

  @override
  Future<SecureMeshMlsResponse> executeMls(SecureMeshMlsRequest request) =>
      throw UnimplementedError();

  @override
  Future<SecureMeshKtResponse> executeKt(SecureMeshKtRequest request) =>
      throw UnimplementedError();
}
