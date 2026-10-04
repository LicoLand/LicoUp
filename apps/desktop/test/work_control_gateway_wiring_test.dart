import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/binding_shell_renderer.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/work_control_presentation.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/contracts/work_control_gateway.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import 'support/fake_conversation_transport.dart';

/// The composed client must hand the work-control surface a lane that reaches
/// the native owner, and must keep the fail-closed answer when no lane exists.
///
/// These cases drive the composition root, not a hand-built controller, because
/// the defect they falsify lived exactly there: the root accepted a gateway and
/// then composed the surface over the fail-closed stub, so every work-control
/// action in the running client landed on `unavailable`.
void main() {
  test('the composed client reaches the native force-stop owner', () async {
    final transport = _forceStopTransport();
    final composition = _compose(transport);
    addTearDown(composition.dispose);

    final workControl = _workControlOf(composition);
    expect(
      workControl,
      isNotNull,
      reason: 'the composed shell must expose a work-control surface',
    );

    final preview = await workControl!.previewForceStop();

    expect(
      transport.requests.map((request) => request.method),
      contains(ConversationProtocolMethod.agentConversationForcePreview),
      reason: 'the surface must reach the native preview owner, not a stub',
    );
    expect(
      preview.confirmable,
      isTrue,
      reason: 'a real preview makes the force-stop dialog offerable',
    );
    expect(preview.scopeId, 'scope-1');
    expect(preview.diagnosticReference, 'force:corr-preview-1');

    final confirmation = await workControl.confirmForceStop();

    expect(
      transport.requests.last.method,
      ConversationProtocolMethod.agentConversationForceConfirm,
      reason: 'the confirm must reach the native owner over the same lane',
    );
    expect(transport.requests.last.params, const {
      'scopeId': 'scope-1',
      'confirmationToken': 'token-1',
      'confirmed': true,
    });
    expect(confirmation.stopped, isTrue);
  });

  test('a gateway the caller explicitly withholds stays fail closed', () async {
    final transport = _forceStopTransport();
    final composition = _compose(
      transport,
      workControlGateway: const UnavailableWorkControlGateway(),
    );
    addTearDown(composition.dispose);

    final workControl = _workControlOf(composition)!;
    final preview = await workControl.previewForceStop();

    expect(
      transport.requests,
      isEmpty,
      reason: 'an explicitly absent lane must not reach the native owner',
    );
    expect(preview.status, ForceStopPreviewStatus.unavailable);
    expect(preview.confirmable, isFalse);
    expect(preview.failureCode, 'force_stop_preview_unavailable');
  });

  test(
    'a host refusal through the composition is never shown as stopped',
    () async {
      final transport = FakeConversationTransport(
        command: (method, params) async => const {
          'ok': false,
          'status': 'owner-unavailable',
          'ownerKind': 'conversationTurn',
          'disposition': 'unavailable',
          'correlationId': 'corr-refused-1',
          'error': {'code': 'owner_unavailable', 'stage': 'work/stop'},
        },
      );
      final composition = _compose(transport);
      addTearDown(composition.dispose);

      final workControl = _workControlOf(composition)!;
      final preview = await workControl.previewForceStop();

      expect(
        transport.requests.single.method,
        ConversationProtocolMethod.agentConversationForcePreview,
      );
      // The host answered a bounded refusal for the stop lane; the surface must
      // not turn an unavailable owner into a confirmable force stop.
      expect(preview.confirmable, isFalse);
      expect(preview.status, ForceStopPreviewStatus.unavailable);
    },
  );
}

/// A composed client whose only native peer is the recording transport, so
/// every assertion below is about what the composed surface actually sent.
ClientAppComposition _compose(
  FakeConversationTransport transport, {
  WorkControlGateway? workControlGateway,
}) => ClientAppComposition(
  controller: ClientController(
    agentService: AgentService(
      stdioRpcTransport: transport,
      // The composition must never need a real binary to answer these cases.
      runCliExecutable: (executable, arguments, environment) async =>
          ProcessResult(0, 0, '{}', ''),
    ),
  ),
  workControlGateway: workControlGateway,
);

WorkControlPresentation? _workControlOf(ClientAppComposition composition) =>
    (composition.renderer as BindingShellRenderer).workControl;

FakeConversationTransport _forceStopTransport() => FakeConversationTransport(
  command: (method, params) async => switch (method) {
    ConversationProtocolMethod.agentConversationForcePreview => const {
      'status': 'preview',
      'correlationId': 'corr-preview-1',
      'scope': {
        'scopeId': 'scope-1',
        'kind': 'local-service',
        'ownerRef': 'scope-1',
        'processGroupVerified': true,
        'affectedTaskCount': 1,
      },
      'affectedTasks': [
        {'taskKind': 'agent-turn', 'taskRef': 'opencode:session-1'},
      ],
      'riskCodes': ['unsaved-agent-progress'],
      'riskSummary': 'Terminating this owned process group stops local work.',
      'confirmationToken': 'token-1',
    },
    ConversationProtocolMethod.agentConversationForceConfirm => const {
      'status': 'observed-exit',
      'correlationId': 'corr-confirm-1',
      'scopeId': 'scope-1',
      'signalled': true,
      'termination': {'observedExit': true, 'forced': true},
    },
    _ => const {'ok': true},
  },
);
