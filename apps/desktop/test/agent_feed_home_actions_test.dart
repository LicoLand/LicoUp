import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

void main() {
  test(
    'refreshFeedPosts upserts one post per session and bumps updates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-home-feed-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _NoopAgentService(),
      );
      addTearDown(controller.dispose);

      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'ready',
          adapterCapabilities: const {
            'conversationDriver': 'implemented',
            'conversationProtocol': 'test',
            'conversationReadiness': 'ready',
          },
          supportedActions: const ['runtime.message.send'],
          scanSource: 'test',
        ),
      ];
      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'session-1',
            agentId: 'codex',
            title: 'First task',
            createdAt: '2026-07-11T10:00:00Z',
            updatedAt: '2026-07-11T10:00:00Z',
            messages: const [
              AgentConversationMessage(
                id: 'm1',
                role: 'assistant',
                text: 'Done with first task',
                createdAt: '2026-07-11T10:00:00Z',
              ),
            ],
            messageCount: 1,
          ),
          AgentConversationSession(
            id: 'session-2',
            agentId: 'codex',
            title: 'Second task',
            createdAt: '2026-07-11T11:00:00Z',
            updatedAt: '2026-07-11T11:00:00Z',
            messages: const [
              AgentConversationMessage(
                id: 'm2',
                role: 'assistant',
                text: 'Done with second task',
                createdAt: '2026-07-11T11:00:00Z',
              ),
            ],
            messageCount: 1,
          ),
        ],
      };

      await controller.refreshFeedPosts();
      expect(controller.feedTimeline.posts, hasLength(2));
      expect(
        controller.feedTimeline.posts.map((p) => p.sourceSessionId).toSet(),
        {'session-1', 'session-2'},
      );

      controller.conversationSessionsByAgent = {
        'codex': [
          AgentConversationSession(
            id: 'session-1',
            agentId: 'codex',
            title: 'First task updated',
            createdAt: '2026-07-11T10:00:00Z',
            updatedAt: '2026-07-11T12:00:00Z',
            messages: const [
              AgentConversationMessage(
                id: 'm1b',
                role: 'assistant',
                text: 'Re-reported first task',
                createdAt: '2026-07-11T12:00:00Z',
              ),
            ],
            messageCount: 2,
          ),
          AgentConversationSession(
            id: 'session-2',
            agentId: 'codex',
            title: 'Second task',
            createdAt: '2026-07-11T11:00:00Z',
            updatedAt: '2026-07-11T11:00:00Z',
            messages: const [
              AgentConversationMessage(
                id: 'm2',
                role: 'assistant',
                text: 'Done with second task',
                createdAt: '2026-07-11T11:00:00Z',
              ),
            ],
            messageCount: 1,
          ),
        ],
      };

      await controller.refreshFeedPosts();
      final bumped = controller.feedTimeline.posts.firstWhere(
        (p) => p.sourceSessionId == 'session-1',
      );
      expect(bumped.updatedAt, '2026-07-11T12:00:00.000Z');
      expect(bumped.title, 'First task updated');
      expect(bumped.body, contains('Re-reported'));
    },
  );

  test('createUserFeedPost adds a non-agent post at the top', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-home-feed-user-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _NoopAgentService(),
    );
    addTearDown(controller.dispose);

    controller.feedTimeline = controller.feedTimeline.copyWith(
      posts: [
        AgentFeedPost(
          id: 'post:codex:old',
          author: const AgentFeedAuthor(
            id: 'target:codex',
            displayName: 'Codex',
            isAgent: true,
            targetId: 'codex',
          ),
          createdAt: '2026-07-11T09:00:00Z',
          updatedAt: '2026-07-11T09:00:00Z',
          title: 'Old report',
          body: 'Earlier work',
          sourceAgentId: 'codex',
          sourceSessionId: 'old',
        ),
      ],
    );

    await controller.createUserFeedPost(
      body: '@Codex please summarize the repo',
      mentionedAgentIds: const ['codex'],
      attachmentPaths: const ['/tmp/notes.md'],
    );

    expect(controller.feedTimeline.posts, hasLength(2));
    final userPost = controller.feedTimeline.posts.first;
    expect(userPost.author.isAgent, isFalse);
    expect(userPost.body, contains('@Codex please summarize the repo'));
    expect(userPost.body, contains('- notes.md'));
    expect(userPost.sourceAgentId, 'codex');
  });

  test(
    'feed fan-out delivers every target and persists composite outcomes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-feed-fanout-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final conversations = _ScriptedConversationService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: _NoopAgentService(),
        conversationService: conversations,
      )..scannedTargets = [_readyTarget('codex'), _readyTarget('opencode')];
      addTearDown(controller.dispose);

      await controller.createUserFeedPost(
        body: 'review this change',
        mentionedAgentIds: const ['codex', 'opencode'],
      );

      expect(conversations.calls, ['codex', 'opencode']);
      final post = controller.feedTimeline.posts.single;
      final outcomes = controller.feedDispatchOutcomesForPost(post.id);
      expect(outcomes.map((outcome) => outcome.key).toSet(), {
        (dispatchId: post.dispatchId, targetId: 'codex'),
        (dispatchId: post.dispatchId, targetId: 'opencode'),
      });
      expect(
        outcomes.every(
          (outcome) => outcome.status == AgentFeedDispatchStatus.succeeded,
        ),
        isTrue,
      );
      expect(post.status, AgentFeedPostStatus.done);
    },
  );

  test(
    'feed derives partial failure from allowed and denied targets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-feed-partial-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final conversations = _ScriptedConversationService();
      final controller =
          ClientController(
              portableData: PortableDataRoot(dataDirectoryOverride: directory),
              agentService: _NoopAgentService(),
              conversationService: conversations,
            )
            ..scannedTargets = [
              _readyTarget('codex'),
              _readyTarget('blocked', readiness: 'unverified'),
            ];
      addTearDown(controller.dispose);

      await controller.createUserFeedPost(
        body: 'review independently',
        mentionedAgentIds: const ['codex', 'blocked'],
      );

      final post = controller.feedTimeline.posts.single;
      final outcomes = {
        for (final outcome in controller.feedDispatchOutcomesForPost(post.id))
          outcome.targetId: outcome,
      };
      expect(conversations.calls, ['codex']);
      expect(outcomes['codex']?.status, AgentFeedDispatchStatus.succeeded);
      expect(outcomes['blocked']?.status, AgentFeedDispatchStatus.failed);
      expect(
        outcomes['blocked']?.errorCode,
        'native_conversation_parity_unverified',
      );
      expect(post.status, AgentFeedPostStatus.partial);
    },
  );

  test(
    'feed retry is bounded, restart-safe, and suppresses duplicates',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-feed-retry-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final firstConversations = _ScriptedConversationService(
        results: {
          'codex': [
            const AgentDispatchTurnResult(
              ok: false,
              errorCode: 'native_agent_transport_failed',
            ),
          ],
        },
      );
      final first = ClientController(
        portableData: portableData,
        agentService: _NoopAgentService(),
        conversationService: firstConversations,
      )..scannedTargets = [_readyTarget('codex')];
      addTearDown(first.dispose);

      await first.createUserFeedPost(
        body: 'retry safely',
        mentionedAgentIds: const ['codex'],
      );
      final postId = first.feedTimeline.posts.single.id;
      expect(
        first.feedDispatchOutcomesForPost(postId).single.status,
        AgentFeedDispatchStatus.retryable,
      );

      final retryConversations = _ScriptedConversationService();
      final restarted = ClientController(
        portableData: portableData,
        agentService: _NoopAgentService(),
        conversationService: retryConversations,
      )..scannedTargets = [_readyTarget('codex')];
      addTearDown(restarted.dispose);
      await restarted.loadFeedTimeline();

      expect(await restarted.retryFeedDispatch(postId, 'codex'), isTrue);
      expect(await restarted.retryFeedDispatch(postId, 'codex'), isFalse);
      final outcome = restarted.feedDispatchOutcomesForPost(postId).single;
      expect(outcome.status, AgentFeedDispatchStatus.succeeded);
      expect(outcome.attemptCount, 2);
      expect(retryConversations.calls, ['codex']);
      expect(
        restarted.feedTimeline.posts.single.status,
        AgentFeedPostStatus.done,
      );
    },
  );

  test('feed attachments enforce typed text binary and size bounds', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-feed-attachments-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final textFile = File('${directory.path}/notes.txt');
    final binaryFile = File('${directory.path}/image.png');
    final oversizeFile = File('${directory.path}/large.txt');
    await textFile.writeAsString('bounded text');
    await binaryFile.writeAsBytes(const [0x89, 0x50, 0x4e, 0x47]);
    await oversizeFile.writeAsBytes(List<int>.filled(256 * 1024 + 1, 0x61));
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: _NoopAgentService(),
    );
    addTearDown(controller.dispose);

    await controller.createUserFeedPost(
      body: 'inspect attachments',
      attachmentPaths: [textFile.path, binaryFile.path, oversizeFile.path],
    );

    final post = controller.feedTimeline.posts.single;
    final attachments = {for (final item in post.attachments) item.name: item};
    expect(attachments['notes.txt']?.accepted, isTrue);
    expect(attachments['notes.txt']?.encoding, 'utf-8');
    expect(attachments['notes.txt']?.content, 'bounded text');
    expect(
      attachments['image.png']?.errorCode,
      'binary_attachment_not_supported',
    );
    expect(attachments['large.txt']?.errorCode, 'attachment_too_large');
    expect(post.toJson().toString(), isNot(contains(directory.path)));
  });

  test('legacy aggregate completion migrates fail-closed per target', () {
    final timeline = AgentFeedTimeline.fromJson({
      'schemaVersion': 1,
      'posts': [
        {
          'id': 'legacy-post',
          'author': {'id': 'user', 'displayName': 'User'},
          'createdAt': '2026-07-11T00:00:00Z',
          'updatedAt': '2026-07-11T00:00:00Z',
          'title': 'legacy',
          'body': 'legacy',
          'sourceAgentId': 'codex',
          'sourceAgentIds': ['codex', 'opencode'],
          'sourceSessionId': '',
          'dispatchId': 'legacy-dispatch',
          'status': 'done',
        },
      ],
    });

    expect(timeline.dispatchOutcomes, hasLength(2));
    expect(
      timeline.dispatchOutcomes.every(
        (outcome) =>
            outcome.status == AgentFeedDispatchStatus.failed &&
            outcome.errorCode == 'legacy_dispatch_outcome_unknown',
      ),
      isTrue,
    );
    expect(timeline.posts.single.status, AgentFeedPostStatus.error);
  });
}

TargetCandidate _readyTarget(String id, {String readiness = 'ready'}) {
  return TargetCandidate(
    target: id,
    label: id,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: readiness == 'ready' ? 'ready' : 'blocked',
    adapterCapabilities: {
      'conversationDriver': 'implemented',
      'conversationProtocol': 'test',
      'conversationReadiness': readiness,
    },
    supportedActions: const ['runtime.message.send'],
    scanSource: 'test',
  );
}

class _ScriptedConversationService extends AgentConversationService {
  _ScriptedConversationService({
    Map<String, List<AgentDispatchTurnResult>>? results,
  }) : results = {
         for (final entry in (results ?? const {}).entries)
           entry.key: List<AgentDispatchTurnResult>.from(entry.value),
       };

  final Map<String, List<AgentDispatchTurnResult>> results;
  final List<String> calls = [];

  @override
  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  }) async {
    calls.add(agentId);
    final queued = results[agentId];
    if (queued != null && queued.isNotEmpty) {
      return queued.removeAt(0);
    }
    return AgentDispatchTurnResult(
      ok: true,
      sessionId: sessionId.isEmpty ? 'native-$agentId' : sessionId,
      raw: const {'ok': true},
    );
  }
}

class _NoopAgentService extends AgentService {
  @override
  Future<List<TargetCandidate>> scanTargets() async {
    return const [];
  }
}
