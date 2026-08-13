import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bounded driver failures must close the live turn in the transcript and
/// surface their precise code; an unclosed process card was the "endless
/// retry" symptom.
class _FailingConversationService extends AgentConversationService {
  const _FailingConversationService();

  @override
  Stream<AgentDispatchEvent> sendStreaming({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    yield const AgentDispatchEvent(
      kind: 'dispatch.turn.bound',
      sessionId: 'native-1',
      turnId: 't-1',
    );
    yield const AgentDispatchEvent(
      kind: 'dispatch.turn.failed',
      sessionId: 'native-1',
      turnId: 't-1',
      payload: <String, dynamic>{
        'ok': false,
        'nativeSessionId': 'native-1',
        'turnStatus': 'timeout',
        'error': <String, dynamic>{
          'code': 'acp_protocol_timeout',
          'message': 'The ACP agent timed out before completing the turn.',
          'stage': 'session/prompt',
          'userInteractionRequired': false,
        },
      },
    );
  }
}

TargetCandidate _copilotTarget() => TargetCandidate(
  target: 'copilot',
  label: 'GitHub Copilot',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/usr/bin/false',
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationReadiness': 'ready',
    'conversationDriver': 'implemented',
  },
  supportedActions: const ['runtime.message.send'],
  location: 'local',
);

void main() {
  testWidgets('bounded driver failure closes the live turn with an error', (
    tester,
  ) async {
    final controller = ClientController(
      conversationService: const _FailingConversationService(),
    );
    addTearDown(controller.dispose);
    controller.scannedTargets = [_copilotTarget()];
    controller.selectedConversationAgentId = 'copilot';

    final sent = await controller.sendConversationMessage('hi');

    expect(sent, isFalse);
    expect(controller.isSendingConversationMessage, isFalse);
    expect(
      controller.conversationSendErrorFor('copilot'),
      'acp_protocol_timeout',
    );
    final live =
        controller.liveConversationMessagesByScope[controller
            .conversationComposerScopeKey]!;
    final markers = live.where(
      (message) =>
          message.role == 'error' &&
          message.cardTitle == 'dispatch.turn.failed',
    );
    expect(markers, hasLength(1));
    expect(markers.single.text, contains('timed out'));
    expect(markers.single.text, contains('timeout'));
  });
}
