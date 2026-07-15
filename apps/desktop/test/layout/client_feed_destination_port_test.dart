import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/layout/client_feed_destination_port.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/backend/features/feed/services/agent_feed_service.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/presentation/destinations/destinations.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contract identity is injected by surface and Feed destination', () {
    final feed = _port(
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.feed,
    );
    final controlPanel = _port(
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.controlPanel,
    );
    addTearDown(feed.dispose);
    addTearDown(controlPanel.dispose);

    expect(feed.contract.key.surface, LayoutRuntimeSurface.desktop);
    expect(feed.contract.key.destination, ClientSection.feed);
    expect(controlPanel.contract.key.surface, LayoutRuntimeSurface.mobile);
    expect(controlPanel.contract.key.destination, ClientSection.controlPanel);
    expect(
      () => _port(
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
      ),
      throwsArgumentError,
    );
  });

  test('snapshot filters hidden targets and freezes every feed list', () {
    final sourceAgentIds = <String>['agent-a'];
    final attachments = <AgentFeedAttachment>[
      const AgentFeedAttachment(
        id: 'attachment-a',
        name: 'note.txt',
        mediaType: 'text/plain',
        encoding: 'utf-8',
        byteLength: 4,
        privacy: 'explicit-user-selection',
        transfer: AgentFeedAttachmentTransfer.inlineText,
        content: 'note',
      ),
    ];
    final commentIds = <String>['comment-a'];
    final repostIds = <String>['repost-a'];
    final reactionCounts = <String, int>{'ack': 1};
    final posts = <AgentFeedPost>[
      _post(
        sourceAgentIds: sourceAgentIds,
        attachments: attachments,
        commentIds: commentIds,
        repostIds: repostIds,
        reactionCounts: reactionCounts,
      ),
    ];
    final targets = <TargetCandidate>[
      _target('visible', status: 'detected'),
      _target('hidden', status: 'not-detected'),
    ];
    final accounts = <MobileAgentAccount>[
      MobileAgentAccount.create(mobileAgentProviders.first, id: 'account-a'),
    ];
    final controller = _controller()
      ..feedTimeline = AgentFeedTimeline(posts: posts)
      ..scannedTargets = targets
      ..mobileAgentAccounts = accounts;
    final port = ClientFeedDestinationPort(
      controller: controller,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.feed,
    );
    addTearDown(controller.dispose);
    addTearDown(port.dispose);

    final snapshot = port.snapshot;
    expect(snapshot.visibleTargets.map((target) => target.target), ['visible']);
    expect(snapshot.mobileAgentAccounts.map((account) => account.id), [
      'account-a',
    ]);

    posts.clear();
    targets.clear();
    accounts.clear();
    sourceAgentIds.add('agent-b');
    attachments.clear();
    commentIds.clear();
    repostIds.clear();
    reactionCounts['ack'] = 2;

    final frozenPost = snapshot.timeline.posts.single;
    expect(frozenPost.sourceAgentIds, ['agent-a']);
    expect(frozenPost.attachments, hasLength(1));
    expect(frozenPost.commentIds, ['comment-a']);
    expect(frozenPost.repostIds, ['repost-a']);
    expect(frozenPost.reactionCounts, {'ack': 1});
    expect(snapshot.visibleTargets, hasLength(1));
    expect(snapshot.mobileAgentAccounts, hasLength(1));

    expect(() => snapshot.timeline.posts.add(_post()), throwsUnsupportedError);
    expect(
      () => frozenPost.sourceAgentIds.add('agent-c'),
      throwsUnsupportedError,
    );
    expect(() => frozenPost.reactionCounts['ack'] = 3, throwsUnsupportedError);
    expect(() => snapshot.visibleTargets.clear(), throwsUnsupportedError);
    expect(() => snapshot.mobileAgentAccounts.clear(), throwsUnsupportedError);
  });

  test(
    'projection changes notify once and subscriptions cancel independently',
    () {
      final controller = _controller();
      final port = ClientFeedDestinationPort(
        controller: controller,
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.feed,
      );
      addTearDown(controller.dispose);
      addTearDown(port.dispose);
      final observed = <FeedDestinationSnapshot>[];
      final subscription = port.listen(observed.add);

      controller.notifyListeners();
      controller.scannedTargets = [_target('hidden', status: 'not-detected')];
      controller.notifyListeners();
      expect(observed, hasLength(1));

      controller.feedTimeline = AgentFeedTimeline(posts: [_post()]);
      controller.notifyListeners();
      expect(observed, hasLength(2));
      expect(observed.last.timeline.posts, hasLength(1));

      final frozenTimeline = observed.last.timeline;
      controller.scannedTargets = [_target('visible', status: 'detected')];
      controller.notifyListeners();
      expect(observed, hasLength(3));
      expect(observed.last.timeline, same(frozenTimeline));

      subscription.cancel();
      controller.feedTimeline = const AgentFeedTimeline();
      controller.notifyListeners();

      expect(subscription.isCancelled, isTrue);
      expect(observed, hasLength(3));
    },
  );

  test('all semantic actions forward to the controller', () async {
    final store = _MemoryAgentFeedStore();
    final controller = _controller(store: store);
    final port = ClientFeedDestinationPort(
      controller: controller,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.controlPanel,
    );
    addTearDown(controller.dispose);
    addTearDown(port.dispose);

    controller.conversationSessionsByAgent = {
      'agent-a': [
        AgentConversationSession(
          id: 'session-a',
          agentId: 'agent-a',
          title: 'Agent update',
          createdAt: '2026-07-15T08:00:00Z',
          updatedAt: '2026-07-15T08:01:00Z',
          messages: const [
            AgentConversationMessage(
              id: 'message-a',
              role: 'assistant',
              text: 'Work completed',
              createdAt: '2026-07-15T08:01:00Z',
            ),
          ],
          messageCount: 1,
        ),
      ],
    };

    await port.refreshFeedPosts();
    expect(port.snapshot.timeline.posts.single.sourceSessionId, 'session-a');

    await port.createUserFeedPost(body: 'User request');
    final userPost = port.snapshot.timeline.posts.firstWhere(
      (post) => post.author.id == 'user:local',
    );
    await port.addFeedComment(
      userPost.id,
      'A comment',
      replyToCommentId: 'parent-comment',
    );
    await port.repostFeedPost(
      userPost.id,
      'unavailable-agent',
      note: 'Take it',
    );
    await port.toggleFollowAuthor(userPost.author);

    expect(port.snapshot.timeline.comments.single.text, 'A comment');
    expect(
      port.snapshot.timeline.comments.single.replyToCommentId,
      'parent-comment',
    );
    expect(
      port.snapshot.timeline.reposts.single.toAgentId,
      'unavailable-agent',
    );
    expect(port.snapshot.timeline.following.single.author.id, 'user:local');

    await port.deleteFeedPost(userPost.id);

    expect(
      port.snapshot.timeline.posts.where((post) => post.id == userPost.id),
      isEmpty,
    );
    expect(port.snapshot.timeline.comments, isEmpty);
    expect(port.snapshot.timeline.reposts, isEmpty);
    expect(store.writeCount, greaterThanOrEqualTo(6));
  });

  test(
    'dispose cancels listeners and rejects snapshots, actions, and listen',
    () {
      final controller = _controller();
      final port = ClientFeedDestinationPort(
        controller: controller,
        surface: LayoutRuntimeSurface.mobile,
        destination: ClientSection.feed,
      );
      addTearDown(controller.dispose);
      final observed = <FeedDestinationSnapshot>[];
      final subscription = port.listen(observed.add);

      port.dispose();
      port.dispose();
      controller.feedTimeline = AgentFeedTimeline(posts: [_post()]);
      controller.notifyListeners();

      expect(port.isDisposed, isTrue);
      expect(subscription.isCancelled, isTrue);
      expect(observed, hasLength(1));
      expect(() => port.snapshot, throwsStateError);
      expect(() => port.listen(observed.add), throwsStateError);
      expect(port.refreshFeedPosts, throwsStateError);
      expect(() => port.createUserFeedPost(body: 'body'), throwsStateError);
      expect(() => port.addFeedComment('post', 'text'), throwsStateError);
      expect(() => port.repostFeedPost('post', 'agent'), throwsStateError);
      expect(() => port.toggleFollowAuthor(_author), throwsStateError);
      expect(() => port.deleteFeedPost('post'), throwsStateError);
    },
  );
}

const _author = AgentFeedAuthor(
  id: 'agent:agent-a',
  displayName: 'Agent A',
  isAgent: true,
  targetId: 'agent-a',
);

AgentFeedPost _post({
  List<String> sourceAgentIds = const ['agent-a'],
  List<AgentFeedAttachment> attachments = const [],
  List<String> commentIds = const [],
  List<String> repostIds = const [],
  Map<String, int> reactionCounts = const {},
}) {
  return AgentFeedPost(
    id: 'post-a',
    author: _author,
    createdAt: '2026-07-15T08:00:00Z',
    updatedAt: '2026-07-15T08:01:00Z',
    title: 'Update',
    body: 'Work completed',
    sourceAgentId: 'agent-a',
    sourceAgentIds: sourceAgentIds,
    sourceSessionId: 'session-a',
    attachments: attachments,
    status: AgentFeedPostStatus.done,
    commentIds: commentIds,
    repostIds: repostIds,
    reactionCounts: reactionCounts,
  );
}

TargetCandidate _target(String id, {required String status}) {
  return TargetCandidate(
    target: id,
    label: id,
    kind: 'cli',
    status: status,
    configured: true,
    confidence: 1,
    adapterStatus: 'ready',
  );
}

ClientFeedDestinationPort _port({
  required LayoutRuntimeSurface surface,
  required ClientSection destination,
}) {
  final controller = _controller();
  final port = ClientFeedDestinationPort(
    controller: controller,
    surface: surface,
    destination: destination,
  );
  addTearDown(controller.dispose);
  return port;
}

ClientController _controller({_MemoryAgentFeedStore? store}) {
  return ClientController(
    agentService: _NoopAgentService(),
    agentFeedService: AgentFeedService(store: store ?? _MemoryAgentFeedStore()),
    mobileClientRuntimePlatformOverride: true,
  );
}

final class _MemoryAgentFeedStore extends AgentFeedStore {
  Object? value;
  int writeCount = 0;

  @override
  Future<Object?> read(Object portableData) async => value;

  @override
  Future<void> write(Object portableData, Object? payload) async {
    value = payload;
    writeCount += 1;
  }
}

final class _NoopAgentService extends AgentService {
  @override
  Future<List<TargetCandidate>> scanTargets() async => const [];
}
