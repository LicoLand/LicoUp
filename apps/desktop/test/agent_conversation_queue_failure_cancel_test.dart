import 'fixtures/client_controller/support/client_controller_scenario_dependencies.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';

/// M2/M3: the turn teardown must not discard confirmed user messages
/// silently. A failed turn drops the queue but names the count; a cancelled
/// turn stops only itself and never implicates messages sent afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('failed turn drops queued messages with an explicit status', () async {
    final service = FakeAgentService()
      ..runtimeMessageResultQueue = [
        {
          'ok': false,
          'error': {
            'code': 'acp_protocol_timeout',
            'message': 'The ACP agent timed out before completing the turn.',
          },
        },
      ]
      ..runtimeMessageGate = Completer<void>();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.scannedTargets = [_codexTarget()];
    controller.selectedConversationAgentId = 'codex';

    final first = controller.sendConversationMessage('First turn');
    await _settleMicrotasks();
    expect(controller.isSendingConversationMessage, isTrue);

    await controller.sendConversationMessage('Queued one');
    await controller.sendConversationMessage('Queued two');
    expect(controller.queuedConversationTurnCount, 2);

    service.runtimeMessageGate!.complete();
    expect(await first, isFalse);
    await _settleMicrotasks();

    // The queue was dropped, but never silently: the status names the count.
    expect(controller.queuedConversationTurnCount, 0);
    expect(controller.statusMessage, contains('丢弃'));
    expect(
      controller.conversationSendErrorFor('codex'),
      'acp_protocol_timeout',
    );
  });

  test('cancelling a turn does not discard messages sent afterwards', () async {
    final service = FakeAgentService()
      ..runtimeMessageResultQueue = [
        {
          'ok': false,
          'error': {
            'code': 'acp_protocol_timeout',
            'message': 'The ACP agent timed out before completing the turn.',
          },
        },
      ]
      ..runtimeMessageGate = Completer<void>();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.scannedTargets = [_codexTarget()];
    controller.selectedConversationAgentId = 'codex';

    final first = controller.sendConversationMessage('First turn');
    await _settleMicrotasks();
    expect(controller.isSendingConversationMessage, isTrue);

    await controller.sendConversationMessage('Queued before cancel');
    expect(controller.queuedConversationTurnCount, 1);

    // Cancelling stops the active turn and its pre-cancel queue; the message
    // sent afterwards is new user intent and must survive the teardown.
    await controller.cancelActiveConversationTurn();
    expect(controller.queuedConversationTurnCount, 0);

    await controller.sendConversationMessage('Sent after cancel');
    expect(controller.queuedConversationTurnCount, 1);

    service.runtimeMessageGate!.complete();
    expect(await first, isFalse);

    // The post-cancel message drains and sends instead of being discarded.
    await _settleMicrotasks();
    expect(controller.queuedConversationTurnCount, 0);
    expect(service.runtimeMessageCalls, 2);
    expect(controller.statusMessage, isNot(contains('丢弃')));
  });
}

Future<void> _settleMicrotasks() async {
  for (var index = 0; index < 16; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

TargetCandidate _codexTarget() {
  return TargetCandidate(
    target: 'codex',
    label: 'Codex',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/synthetic/bin/codex',
    adapterStatus: 'implemented',
    adapterCapabilities: const <String, dynamic>{
      'conversationDriver': 'implemented',
      'conversationProtocol': 'synthetic-native-protocol',
      'conversationReadiness': 'ready',
    },
  );
}
