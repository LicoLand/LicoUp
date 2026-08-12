import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

void main() {
  const image = ConversationAttachment(
    id: 'selection-1',
    name: 'sample.png',
    mediaType: 'image/png',
    path: 'attachment-fixtures/sample.png',
  );

  test('attachment state is scoped and queued turns snapshot it immutably', () {
    final signals = ConversationPresentationSignals();
    signals.replaceComposerAttachments('scope-a', const [image]);

    expect(signals.composerAttachmentsFor('scope-a'), const [image]);
    expect(signals.composerAttachmentsFor('scope-b'), isEmpty);
    expect(
      () => signals.composerAttachmentsFor('scope-a').add(image),
      throwsUnsupportedError,
    );

    final turn = ConversationQueuedTurn(
      submissionId: 1,
      agent: TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'agent',
        status: 'ready',
        configured: true,
        confidence: 1,
        adapterStatus: 'ready',
      ),
      text: '',
      session: null,
      nativeSessionId: '',
      workingDirectory: '',
      model: '',
      reasoningEffort: '',
      throughMobileRelay: false,
      scopeKey: 'scope-a',
      attachments: signals.composerAttachmentsFor('scope-a'),
    );
    signals.replaceComposerAttachments('scope-a', const []);

    expect(turn.attachments, const [image]);
    expect(() => turn.attachments.add(image), throwsUnsupportedError);
    signals.dispose();
  });

  test('queued turn freezes a caller-owned attachment list', () {
    final attachments = <ConversationAttachment>[image];
    final turn = ConversationQueuedTurn(
      submissionId: 1,
      agent: TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'agent',
        status: 'ready',
        configured: true,
        confidence: 1,
        adapterStatus: 'ready',
      ),
      text: '',
      session: null,
      nativeSessionId: '',
      workingDirectory: '',
      model: '',
      reasoningEffort: '',
      throughMobileRelay: false,
      scopeKey: 'scope-a',
      attachments: attachments,
    );

    attachments.clear();

    expect(turn.attachments, const [image]);
  });

  test(
    'conversation service emits one exact ordered attachments field',
    () async {
      final runner = _WireRunner();
      final events = await const AgentConversationService()
          .sendStreaming(
            runner: runner,
            agentId: 'codex',
            text: '',
            sessionId: '',
            attachments: const [image],
          )
          .toList();

      expect(events.last.kind, 'dispatch.turn.completed');
      final body = jsonDecode(runner.stdinText) as Map<String, dynamic>;
      expect(body['text'], '');
      expect(body['attachments'], [image.toJson()]);
      expect(body.toString(), isNot(contains('data:')));
    },
  );
}

final class _WireRunner implements AgentCommandRunner {
  String stdinText = '';

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    this.stdinText = stdinText;
    expect(args, [
      'agent',
      'conversation',
      'send',
      '--stdin-json',
      'true',
      '--stream-events',
      'true',
    ]);
    yield <String, dynamic>{
      'event': 'done',
      'ok': true,
      'nativeSessionId': 'session-1',
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();
}
