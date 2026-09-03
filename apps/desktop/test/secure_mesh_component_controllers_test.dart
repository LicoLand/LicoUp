import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeSecureMeshGateway gateway;
  late SecureMeshController controller;

  setUp(() {
    gateway = _FakeSecureMeshGateway();
    controller = SecureMeshController(
      gateway: gateway,
      operationGate: MobileRelayOperationGate(),
      onStatus: (_) {},
      now: () => DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
  });

  tearDown(() => controller.dispose());

  test(
    'file component closes route, destination, and confirmation locally',
    () async {
      controller.setFileDraft(fileName: 'folder/report.pdf', totalSize: 16);
      controller.setFileDestination('/approved');

      await controller.prepareFileTransfer();

      expect(controller.fileDraft?.fileName, 'report.pdf');
      expect(
        controller.fileDraft?.status,
        SecureMeshFileSyncStatus.awaitingConfirmation,
      );
      expect(gateway.fileRouteCalls, 1);
      expect(gateway.fileDestinationCalls, 1);
      expect(gateway.fileConfirmationCalls, 1);

      await controller.confirmFileReceive(userConfirmed: true);

      expect(controller.fileDraft?.status, SecureMeshFileSyncStatus.confirmed);
      expect(gateway.fileConfirmationCalls, 2);
    },
  );

  test(
    'approval component resolves with secrets retained outside public state',
    () async {
      await controller.ingestApproval(
        pendingOperationId: 'operation-1',
        requesterAgentId: 'requester-agent',
        targetClientId: 'target-client',
        originEndpointId: 'private-endpoint',
        displaySummary: 'Approve a bounded operation',
        adapterCallbackTokenRef: 'private-token',
        responseNonce: 'private-nonce',
        expiresAt: '2099-01-01T00:00:00Z',
        trustedEndpointIds: const ['private-endpoint'],
      );

      final public = controller.approvalInbox.single;
      expect(public.originEndpointId, isEmpty);
      expect(public.responseNonce, isEmpty);
      expect(public.adapterCallbackTokenRef, isEmpty);
      expect(controller.canResolveApproval('operation-1'), isTrue);

      await controller.resolveApproval(
        pendingOperationId: 'operation-1',
        allow: true,
      );

      expect(gateway.resolvedEndpointId, 'private-endpoint');
      expect(gateway.resolvedNonce, 'private-nonce');
      expect(controller.approvalInbox.single.isPending, isFalse);
      expect(controller.canResolveApproval('operation-1'), isFalse);
    },
  );

  test(
    'protocol component tracks KT and MLS action states independently',
    () async {
      final kt = await controller.executeKt(const SecureMeshKtRequest.status());
      final mls = await controller.executeMls(
        const SecureMeshMlsRequest.status(),
      );

      expect(kt?.value['ok'], isTrue);
      expect(mls?.value['ok'], isTrue);
      expect(controller.ktState?.action, SecureMeshKtAction.status.wireName);
      expect(controller.ktState?.succeeded, isTrue);
      expect(controller.mlsState?.action, SecureMeshMlsAction.status.wireName);
      expect(controller.mlsState?.succeeded, isTrue);
    },
  );
}

final class _FakeSecureMeshGateway implements SecureMeshGateway {
  int fileRouteCalls = 0;
  int fileDestinationCalls = 0;
  int fileConfirmationCalls = 0;
  String resolvedEndpointId = '';
  String resolvedNonce = '';

  @override
  Future<Map<String, dynamic>> status({required bool authorize}) async =>
      const {'ok': true};

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
  }) async => const {'ok': true, 'trustState': 'verified'};

  @override
  Future<Map<String, dynamic>> evaluateFileRoute(
    Map<String, dynamic> manifest,
  ) async {
    fileRouteCalls += 1;
    return const {
      'ok': true,
      'route': {'uploadOperation': 'secure_mesh.file_chunk.upload'},
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
  }) async {
    fileDestinationCalls += 1;
    return const {
      'ok': true,
      'receivePolicy': {'destinationApproved': true},
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateFileReceiveConfirmation({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required bool userConfirmed,
  }) async {
    fileConfirmationCalls += 1;
    return {
      'ok': true,
      'receiveConfirmation': {
        'required': true,
        'writeAllowed': userConfirmed,
        'userConfirmed': userConfirmed,
        'autoPreviewEnabled': false,
        'autoIngestionEnabled': false,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateApprovalAdapterCapability(
    String agentId,
  ) async => const {'approvalsSupported': true, 'remoteApprovalBridge': true};

  @override
  Future<Map<String, dynamic>> evaluateApprovalRequest(
    Map<String, dynamic> request,
  ) async => const {'ok': true};

  @override
  Future<Map<String, dynamic>> evaluateApprovalFanout(
    String pendingOperationId,
  ) async => const {
    'ok': true,
    'plaintextRelayBlocked': true,
    'trustedEndpointCount': 1,
  };

  @override
  Future<Map<String, dynamic>> listApprovalInbox({
    required bool includeResolved,
  }) async => const {
    'ok': true,
    'plaintextRelayBlocked': true,
    'items': <Object>[],
  };

  @override
  Future<Map<String, dynamic>> resolveApproval({
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
  }) async {
    resolvedEndpointId = respondingEndpointId;
    resolvedNonce = responseNonce;
    return const {'ok': true};
  }

  @override
  Future<SecureMeshMlsResponse> executeMls(
    SecureMeshMlsRequest request,
  ) async => SecureMeshMlsResponse.fromJson(const {'ok': true});

  @override
  Future<SecureMeshKtResponse> executeKt(SecureMeshKtRequest request) async =>
      SecureMeshKtResponse.fromJson(const {'ok': true});
}
