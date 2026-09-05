import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_queue.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    'attachment projection exposes semantic metadata without payload bytes',
    () async {
      const secondImage = ConversationAttachment(
        id: 'selection-2',
        name: 'second.png',
        mediaType: 'image/png',
        path: 'attachment-fixtures/second.png',
      );
      final controller = ClientController(agentService: FakeAgentService())
        ..selectedConversationAgentId = 'codex';
      final scopeKey = controller.conversationComposerScopeKey;
      controller.conversationPresentationSignals.replaceComposerAttachments(
        scopeKey,
        const [image, secondImage],
      );
      final producer = ConversationProjectionProducer(controller);

      expect(
        producer.attachments.current.attachments.map(
          (attachment) =>
              (attachment.id, attachment.displayName, attachment.mediaKind),
        ),
        [
          ('selection-1', 'sample.png', 'image/png'),
          ('selection-2', 'second.png', 'image/png'),
        ],
      );

      controller.conversationPresentationSignals.replaceComposerAttachments(
        scopeKey,
        const [secondImage],
      );
      producer.publishLocalChange();
      controller.conversationPresentationSignals.replaceComposerAttachments(
        scopeKey,
        const [image, secondImage],
      );
      producer.publishLocalChange();

      expect(
        producer.attachments.current.attachments.map(
          (attachment) => attachment.id,
        ),
        ['selection-1', 'selection-2'],
      );

      await producer.close();
      await controller.close();
    },
  );

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

  test(
    'semantic send keeps queued attachments until terminal success',
    () async {
      final gate = Completer<void>();
      final service = FakeAgentService()..runtimeMessageGate = gate;
      final clipboard = _RecordingClipboardService();
      final controller =
          ClientController(
              agentService: service,
              clientClipboardService: clipboard,
            )
            ..scannedTargets = [_conversationTarget()]
            ..selectedConversationAgentId = 'codex';
      final composition = ConversationFeatureComposition(controller);
      final first = controller.sendConversationMessage('first');
      await _settleUntil(() => service.runtimeMessageCalls == 1);
      expect(controller.isSendingConversationMessage, isTrue);

      final scopeKey = controller.conversationComposerScopeKey;
      controller.replaceConversationComposerAttachments(const [image]);
      composition.binding.intents.send(
        PostConversationMessage(
          conversationId: scopeKey,
          content: 'queued',
          addressedMembershipIds: const [],
          dispatchCanonical: false,
        ),
      );
      await _settleUntil(() => controller.queuedConversationTurnCount == 1);

      expect(
        controller.conversationPresentationSignals.composerAttachmentsFor(
          scopeKey,
        ),
        const [image],
      );
      expect(clipboard.releasedIds, isEmpty);

      gate.complete();
      expect(await first, isTrue);
      await _settleUntil(
        () =>
            service.runtimeMessageCalls == 2 &&
            !controller.isSendingConversationMessage,
        attempts: 80,
      );

      expect(
        controller.conversationPresentationSignals.composerAttachmentsFor(
          scopeKey,
        ),
        isEmpty,
      );
      expect(clipboard.releasedIds, ['selection-1']);

      await composition.close();
      await controller.close();
    },
  );

  test('canonical send releases staged attachments after success', () async {
    final service = _CanonicalAttachmentAgentService();
    final clipboard = _RecordingClipboardService();
    final controller = ClientController(
      agentService: service,
      clientClipboardService: clipboard,
    );
    await controller.clientConversationController.initialize();
    await controller.clientConversationController.selectConversation(
      'conversation:group',
    );
    final composition = ConversationFeatureComposition(controller);
    const scopeKey = 'group:conversation:group';
    controller.conversationPresentationSignals.replaceComposerAttachments(
      scopeKey,
      const [image],
    );

    composition.binding.intents.send(
      PostConversationMessage(
        conversationId: scopeKey,
        content: 'group message',
        addressedMembershipIds: [],
        dispatchCanonical: false,
      ),
    );
    await _settleUntil(() => clipboard.releasedIds.isNotEmpty, attempts: 80);

    expect(
      controller.conversationPresentationSignals.composerAttachmentsFor(
        scopeKey,
      ),
      isEmpty,
    );
    expect(clipboard.releasedIds, ['selection-1']);
    expect(service.postedAttachments, [
      {
        'path': 'attachment-fixtures/sample.png',
        'name': 'sample.png',
        'mediaType': 'image/png',
      },
    ]);

    await composition.close();
    await controller.close();
  });
}

Future<void> _settleUntil(
  bool Function() predicate, {
  int attempts = 30,
}) async {
  for (var attempt = 0; attempt < attempts && !predicate(); attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue);
}

TargetCandidate _conversationTarget() => TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/codex',
  adapterStatus: 'implemented',
  adapterCapabilities: <String, dynamic>{
    'conversationDriver': 'implemented',
    'conversationProtocol': 'synthetic-native-protocol',
    'conversationReadiness': 'ready',
    'conversationCapabilityMatrix': <String, dynamic>{'multimodal': true},
  },
);

final class _RecordingClipboardService extends ClientClipboardService {
  final List<String> releasedIds = [];

  @override
  Future<void> releaseAttachments(
    Iterable<ConversationAttachment> attachments,
  ) async {
    releasedIds.addAll(attachments.map((attachment) => attachment.id));
  }
}

final class _CanonicalAttachmentAgentService extends FakeAgentService {
  List<Object?> postedAttachments = const [];

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    if (args.length < 2 || args[0] != 'conversation') {
      return super.runCliWithStdin(args, stdinText);
    }
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    final action = (request['action'] ?? '').toString();
    if (action == 'conversation.message.post') {
      postedAttachments = List<Object?>.from(
        request['attachments'] as List? ?? const [],
      );
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [_canonicalSummary],
        'conversation.get' => _canonicalConversation,
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        'conversation.message.post' => {
          'event': {'id': 'event:new'},
          'directTurns': <Map<String, dynamic>>[],
          'turns': <Map<String, dynamic>>[],
          'dispatchPending': false,
        },
        _ => <String, dynamic>{},
      },
    };
  }
}

const Map<String, dynamic> _canonicalSummary = {
  'id': 'conversation:group',
  'title': 'Synthetic group',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'updatedAtUnixMs': 10,
  'membershipCount': 2,
  'eventCount': 0,
};

const Map<String, dynamic> _canonicalConversation = {
  'id': 'conversation:group',
  'title': 'Synthetic group',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 1,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 10,
  'eventCount': 0,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'Local User',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:agent',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:synthetic',
        'kind': 'agent',
        'displayName': 'Synthetic Agent',
        'agentId': 'synthetic',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
};

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
