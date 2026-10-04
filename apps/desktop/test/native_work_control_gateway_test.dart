import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_work_control_gateway.dart';

import 'support/fake_conversation_transport.dart';

/// The production work-control lane is the only owner that reaches the native
/// control plane. Every case here states what it sends on the wire and what it
/// answers for a host that is unreachable or refuses: a stop this client could
/// not confirm must never be presented as a completion.
void main() {
  test(
    'a manual stop reaches agent.conversation.stop with the exact identity',
    () async {
      final transport = FakeConversationTransport(
        command: (method, params) async => const {
          'ok': true,
          'status': 'stop-requested',
          'ownerKind': 'conversationTurn',
          'disposition': 'acknowledged',
          'correlationId': 'corr-stop-1',
        },
      );
      final gateway = NativeWorkControlGateway(
        transport: transport,
        desktopRuntime: true,
      );

      final result = await gateway.stopWork(
        const WorkStopRequest(turnHandle: 'turn-1', conversationId: 'c-1'),
      );

      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.method,
        ConversationProtocolMethod.agentConversationStop,
      );
      expect(transport.requests.single.params, const {
        'turnHandle': 'turn-1',
        'conversationId': 'c-1',
      });
      expect(result.requested, isTrue);
      expect(result.disposition, WorkStopDisposition.acknowledged);
      expect(result.ownerKind, WorkStopOwnerKind.conversationTurn);
      expect(result.diagnosticReference, 'stop:corr-stop-1');
    },
  );

  test(
    'a preview with no scope asks the host to name its own scopes',
    () async {
      final transport = FakeConversationTransport(
        command: (method, params) async => const {
          'status': 'scope-required',
          'candidates': [
            {
              'scopeId': 'scope-a',
              'kind': 'local-service',
              'ownerRef': 'scope-a',
            },
          ],
        },
      );
      final gateway = NativeWorkControlGateway(
        transport: transport,
        desktopRuntime: true,
      );

      final preview = await gateway.previewForceStop();

      expect(
        transport.requests.single.method,
        ConversationProtocolMethod.agentConversationForcePreview,
      );
      // An omitted scope is what makes the host answer `scope-required` instead
      // of this client guessing which process group the user meant.
      expect(transport.requests.single.params, isEmpty);
      expect(preview.status, ForceStopPreviewStatus.scopeRequired);
      expect(preview.confirmable, isFalse);
      expect(preview.candidates.single.scopeId, 'scope-a');
    },
  );

  test('a confirm sends back the exact previewed scope and token', () async {
    final transport = FakeConversationTransport(
      command: (method, params) async => switch (method) {
        ConversationProtocolMethod.agentConversationForcePreview => const {
          'status': 'preview',
          'scope': {
            'scopeId': 'scope-a',
            'kind': 'local-service',
            'ownerRef': 'scope-a',
            'processGroupVerified': true,
          },
          'confirmationToken': 'token-7',
        },
        _ => const {
          'status': 'observed-exit',
          'scopeId': 'scope-a',
          'signalled': true,
          'termination': {'observedExit': true, 'forced': true},
        },
      },
    );
    final gateway = NativeWorkControlGateway(
      transport: transport,
      desktopRuntime: true,
    );

    final preview = await gateway.previewForceStop(scopeId: '  scope-a  ');
    expect(
      transport.requests.last.params,
      const {'scopeId': 'scope-a'},
      reason: 'the scope the user chose is sent trimmed and verbatim',
    );
    expect(preview.confirmable, isTrue);

    final confirmation = await gateway.confirmForceStop(
      scopeId: preview.scopeId,
      confirmationToken: preview.confirmationToken,
      confirmed: true,
    );

    expect(
      transport.requests.last.method,
      ConversationProtocolMethod.agentConversationForceConfirm,
    );
    expect(transport.requests.last.params, const {
      'scopeId': 'scope-a',
      'confirmationToken': 'token-7',
      'confirmed': true,
    });
    expect(confirmation.stopped, isTrue);
    expect(confirmation.signalled, isTrue);
  });

  test('an unreachable host never produces a fabricated completion', () async {
    final transport = FakeConversationTransport(
      command: (method, params) async =>
          throw const LicoClientRpcException('transport_failed'),
    );
    final gateway = NativeWorkControlGateway(
      transport: transport,
      desktopRuntime: true,
    );

    final stop = await gateway.stopWork(
      const WorkStopRequest(turnHandle: 'turn-1'),
    );
    final preview = await gateway.previewForceStop();
    final confirmation = await gateway.confirmForceStop(
      scopeId: 'scope-a',
      confirmationToken: 'token-7',
      confirmed: true,
    );

    // The request did leave the client; only the answer is unknown.
    expect(transport.requests, hasLength(3));
    expect(stop.ok, isFalse);
    expect(stop.requested, isFalse);
    expect(stop.disposition, WorkStopDisposition.unavailable);
    expect(stop.failureCode, 'work_stop_transport_failed');
    expect(preview.status, ForceStopPreviewStatus.unavailable);
    expect(preview.confirmable, isFalse);
    expect(preview.failureCode, 'force_stop_preview_transport_failed');
    expect(confirmation.status, ForceStopConfirmationStatus.unavailable);
    expect(confirmation.stopped, isFalse);
    expect(confirmation.signalled, isFalse);
    expect(confirmation.failureCode, 'force_stop_confirm_transport_failed');
  });

  test('a host with no local owned runtime sends nothing at all', () async {
    final transport = FakeConversationTransport();
    final gateway = NativeWorkControlGateway(
      transport: transport,
      desktopRuntime: false,
    );

    final stop = await gateway.stopWork(
      const WorkStopRequest(turnHandle: 'turn-1'),
    );
    final preview = await gateway.previewForceStop();
    final confirmation = await gateway.confirmForceStop(
      scopeId: 'scope-a',
      confirmationToken: 'token-7',
      confirmed: true,
    );

    expect(transport.requests, isEmpty);
    expect(stop.failureCode, NativeWorkControlGateway.unsupportedHostCode);
    expect(preview.failureCode, NativeWorkControlGateway.unsupportedHostCode);
    expect(
      confirmation.failureCode,
      NativeWorkControlGateway.unsupportedHostCode,
    );
    expect(confirmation.stopped, isFalse);
  });

  test('a host that refuses the stop is reported, never upgraded', () async {
    final transport = FakeConversationTransport(
      command: (method, params) async => const {
        'ok': false,
        'status': 'owner-unavailable',
        'ownerKind': 'conversationTurn',
        'disposition': 'unavailable',
        'correlationId': 'corr-9',
        'error': {'code': 'owner_unavailable', 'stage': 'work/stop'},
      },
    );
    final gateway = NativeWorkControlGateway(
      transport: transport,
      desktopRuntime: true,
    );

    final result = await gateway.stopWork(
      const WorkStopRequest(turnHandle: 'turn-1'),
    );

    expect(result.requested, isFalse);
    expect(result.failureCode, 'owner_unavailable');
    expect(
      projectWorkStopStage(result: result, observedActive: false),
      WorkStopStage.unconfirmed,
      reason: 'a refused stop is never a stopped task',
    );
  });
}
