import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/runtime_control/controller/work_control_controller.dart';
import 'package:licoup/src/contracts/work_control_gateway.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';

void main() {
  test(
    'an accepted stop keeps stopping while the work is still observed',
    () async {
      final gateway = _FakeWorkControlGateway();
      final controller = WorkControlController(gateway: gateway);
      addTearDown(controller.dispose);

      final result = await controller.stopWork(
        const WorkStopRequest(turnHandle: 'turn-1', conversationId: 'c-1'),
      );

      expect(result.requested, isTrue);
      expect(gateway.stopRequests, hasLength(1));
      expect(gateway.stopRequests.single.turnHandle, 'turn-1');
      expect(controller.stageFor(observedActive: true), WorkStopStage.stopping);
      expect(controller.stageFor(observedActive: false), WorkStopStage.stopped);
      expect(controller.stopDiagnosticReference, 'stop:corr-1');
    },
  );

  test('an unreachable owner never becomes a fabricated completion', () async {
    final gateway = _FakeWorkControlGateway()
      ..stopJson = const {
        'ok': false,
        'status': 'owner-unavailable',
        'ownerKind': 'conversationTurn',
        'correlationId': 'corr-9',
        'disposition': 'unavailable',
        'error': {'code': 'owner_unavailable', 'stage': 'work/stop'},
      };
    final controller = WorkControlController(gateway: gateway);
    addTearDown(controller.dispose);

    final result = await controller.stopWork(
      const WorkStopRequest(turnHandle: 'turn-1'),
    );

    expect(result.ok, isFalse);
    expect(result.failureCode, 'owner_unavailable');
    expect(result.diagnosticReference, 'stop:corr-9');
    expect(
      controller.stageFor(observedActive: true),
      WorkStopStage.unconfirmed,
    );
    expect(
      controller.stageFor(observedActive: false),
      WorkStopStage.unconfirmed,
    );
  });

  test(
    'an ambiguous stop target is refused locally without a native call',
    () async {
      final gateway = _FakeWorkControlGateway();
      final controller = WorkControlController(gateway: gateway);
      addTearDown(controller.dispose);

      final result = await controller.stopWork(
        const WorkStopRequest(turnHandle: 'turn-1', runId: 'run-1'),
      );

      expect(result.failureCode, 'work_stop_target_ambiguous');
      expect(gateway.stopRequests, isEmpty);
      expect(controller.stopRequestCount, 0);
    },
  );

  test(
    'confirm sends exactly one native force stop for the previewed scope',
    () async {
      final gateway = _FakeWorkControlGateway();
      final controller = WorkControlController(gateway: gateway);
      addTearDown(controller.dispose);

      final preview = await controller.previewForceStop();
      expect(preview.confirmable, isTrue);
      expect(preview.affectedTaskCount, 2);
      expect(preview.riskCodes, contains('unsaved-agent-progress'));
      expect(controller.forceStopDiagnosticReference, 'force:preview-1');

      final confirmation = await controller.confirmForceStop();

      expect(gateway.confirmations, hasLength(1));
      expect(gateway.confirmations.single.scopeId, 'local-service.opencode');
      expect(gateway.confirmations.single.confirmationToken, 'token-1');
      expect(gateway.confirmations.single.confirmed, isTrue);
      expect(confirmation.stopped, isTrue);
      expect(
        controller.lastConfirmation?.diagnosticReference,
        'force:confirm-1',
      );
      expect(controller.preview, isNull);
    },
  );

  test('declining a force stop sends nothing at all', () async {
    final gateway = _FakeWorkControlGateway();
    final controller = WorkControlController(gateway: gateway);
    addTearDown(controller.dispose);

    await controller.previewForceStop();
    controller.declineForceStop();

    expect(gateway.confirmations, isEmpty);
    expect(gateway.stopRequests, isEmpty);
    expect(controller.preview, isNull);
    expect(controller.lastConfirmation, isNull);
  });

  test('confirming without a confirmable preview sends nothing', () async {
    final gateway = _FakeWorkControlGateway();
    final controller = WorkControlController(gateway: gateway);
    addTearDown(controller.dispose);

    final confirmation = await controller.confirmForceStop();

    expect(confirmation.status, ForceStopConfirmationStatus.invalid);
    expect(confirmation.failureCode, 'force_stop_preview_required');
    expect(gateway.confirmations, isEmpty);
  });

  test(
    'an unobserved exit stays unconfirmed and keeps its reference',
    () async {
      final gateway = _FakeWorkControlGateway()
        ..confirmJson = const {
          'ok': false,
          'status': 'unconfirmed',
          'correlationId': 'corr-exit',
          'scopeId': 'local-service.opencode',
          'signalled': true,
          'termination': {
            'requested': true,
            'observedExit': false,
            'forced': true,
            'reasonCode': 'exit_not_observed',
          },
        };
      final controller = WorkControlController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.previewForceStop();
      final confirmation = await controller.confirmForceStop();

      expect(confirmation.status, ForceStopConfirmationStatus.unconfirmed);
      expect(confirmation.signalled, isTrue);
      expect(confirmation.stopped, isFalse);
      expect(confirmation.reasonCode, 'exit_not_observed');
      expect(controller.forceStopDiagnosticReference, 'force:corr-exit');
    },
  );

  test(
    'a preview that asks for a scope reports the choice instead of guessing',
    () async {
      final gateway = _FakeWorkControlGateway()
        ..previewJson = const {
          'ok': true,
          'status': 'scope-required',
          'correlationId': 'preview-2',
          'candidates': [
            {
              'scopeId': 'local-service.opencode',
              'kind': 'local-service',
              'ownerRef': 'opencode',
            },
            {
              'scopeId': 'local-service.kilo',
              'kind': 'local-service',
              'ownerRef': 'kilo',
            },
          ],
        };
      final controller = WorkControlController(gateway: gateway);
      addTearDown(controller.dispose);

      final preview = await controller.previewForceStop();

      expect(preview.status, ForceStopPreviewStatus.scopeRequired);
      expect(preview.confirmable, isFalse);
      expect(preview.candidates, hasLength(2));

      final confirmation = await controller.confirmForceStop();
      expect(confirmation.status, ForceStopConfirmationStatus.invalid);
      expect(gateway.confirmations, isEmpty);
    },
  );

  test(
    'the fail-closed lane reports unavailable instead of inventing state',
    () async {
      final controller = WorkControlController(
        gateway: const UnavailableWorkControlGateway(),
      );
      addTearDown(controller.dispose);

      final stop = await controller.stopWork(
        const WorkStopRequest(turnHandle: 'turn-1'),
      );
      final preview = await controller.previewForceStop();

      expect(stop.failureCode, 'work_stop_unavailable');
      expect(preview.status, ForceStopPreviewStatus.unavailable);
      expect(preview.confirmable, isFalse);
      expect(
        controller.stageFor(observedActive: true),
        WorkStopStage.unconfirmed,
      );
    },
  );
}

final class _RecordedConfirmation {
  const _RecordedConfirmation({
    required this.scopeId,
    required this.confirmationToken,
    required this.confirmed,
  });

  final String scopeId;
  final String confirmationToken;
  final bool confirmed;
}

final class _FakeWorkControlGateway implements WorkControlGateway {
  final List<WorkStopRequest> stopRequests = [];
  final List<_RecordedConfirmation> confirmations = [];

  Map<String, dynamic> stopJson = const {
    'ok': true,
    'status': 'stop-requested',
    'ownerKind': 'conversationTurn',
    'correlationId': 'corr-1',
    'disposition': 'acknowledged',
  };

  Map<String, dynamic> previewJson = const {
    'ok': true,
    'status': 'preview',
    'correlationId': 'preview-1',
    'scope': {
      'scopeId': 'local-service.opencode',
      'kind': 'local-service',
      'ownerRef': 'opencode',
      'pid': 4242,
      'processGroupVerified': true,
      'affectedTaskCount': 2,
    },
    'affectedTasks': [
      {'taskKind': 'agent-turn', 'taskRef': 'opencode:session-1'},
      {'taskKind': 'agent-turn', 'taskRef': 'opencode:session-2'},
    ],
    'riskCodes': ['unsaved-agent-progress', 'service-restart-required'],
    'riskSummary': 'Terminating the opencode process group stops the service.',
    'confirmationToken': 'token-1',
  };

  Map<String, dynamic> confirmJson = const {
    'ok': true,
    'status': 'observed-exit',
    'correlationId': 'confirm-1',
    'scopeId': 'local-service.opencode',
    'signalled': true,
    'termination': {
      'requested': true,
      'observedExit': true,
      'forced': true,
      'reasonCode': 'killed',
    },
    'convergedRevision': 4242,
  };

  @override
  Future<WorkStopResult> stopWork(WorkStopRequest request) async {
    stopRequests.add(request);
    return WorkStopResult.fromJson(stopJson);
  }

  @override
  Future<ForceStopPreview> previewForceStop({String scopeId = ''}) async =>
      ForceStopPreview.fromJson(previewJson);

  @override
  Future<ForceStopConfirmation> confirmForceStop({
    required String scopeId,
    required String confirmationToken,
    required bool confirmed,
  }) async {
    confirmations.add(
      _RecordedConfirmation(
        scopeId: scopeId,
        confirmationToken: confirmationToken,
        confirmed: confirmed,
      ),
    );
    return ForceStopConfirmation.fromJson(confirmJson);
  }
}
