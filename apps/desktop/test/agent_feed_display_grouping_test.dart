import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/agent_feed_display_grouping.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';

AgentFeedPost _post({
  required String id,
  required bool isAgent,
  required String updatedAt,
  String authorName = 'Author',
}) {
  return AgentFeedPost(
    id: id,
    author: AgentFeedAuthor(
      id: isAgent ? 'agent:$id' : 'user:$id',
      displayName: authorName,
      isAgent: isAgent,
    ),
    createdAt: updatedAt,
    updatedAt: updatedAt,
    title: id,
    body: id,
    sourceAgentId: isAgent ? 'agent-a' : '',
    sourceSessionId: isAgent ? 'session-$id' : '',
  );
}

void main() {
  test('consecutive agent posts share one display group', () {
    final groups = groupFeedPostsForDisplay([
      _post(id: 'a1', isAgent: true, updatedAt: '2026-07-11T12:00:00Z'),
      _post(id: 'a2', isAgent: true, updatedAt: '2026-07-11T11:00:00Z'),
      _post(id: 'a3', isAgent: true, updatedAt: '2026-07-11T10:00:00Z'),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.isAgentGroup, isTrue);
    expect(groups.single.posts.map((p) => p.id), ['a1', 'a2', 'a3']);
  });

  test('user posts break agent groups into separate cards', () {
    final groups = groupFeedPostsForDisplay([
      _post(id: 'a-new', isAgent: true, updatedAt: '2026-07-11T14:00:00Z'),
      _post(
        id: 'u1',
        isAgent: false,
        updatedAt: '2026-07-11T13:00:00Z',
        authorName: 'Me',
      ),
      _post(id: 'a-old', isAgent: true, updatedAt: '2026-07-11T12:00:00Z'),
      _post(id: 'a-older', isAgent: true, updatedAt: '2026-07-11T11:00:00Z'),
    ]);

    expect(groups, hasLength(3));
    expect(groups[0].isAgentGroup, isTrue);
    expect(groups[0].posts.map((p) => p.id), ['a-new']);
    expect(groups[1].isUserGroup, isTrue);
    expect(groups[1].posts.map((p) => p.id), ['u1']);
    expect(groups[2].isAgentGroup, isTrue);
    expect(groups[2].posts.map((p) => p.id), ['a-old', 'a-older']);
  });

  test('consecutive user posts stay as separate cards', () {
    final groups = groupFeedPostsForDisplay([
      _post(id: 'u2', isAgent: false, updatedAt: '2026-07-11T13:00:00Z'),
      _post(id: 'u1', isAgent: false, updatedAt: '2026-07-11T12:00:00Z'),
    ]);

    expect(groups, hasLength(2));
    expect(groups.every((g) => g.isUserGroup), isTrue);
    expect(groups[0].posts.single.id, 'u2');
    expect(groups[1].posts.single.id, 'u1');
  });

  test('groups sort newest first even when input is unsorted', () {
    final groups = groupFeedPostsForDisplay([
      _post(id: 'old', isAgent: true, updatedAt: '2026-07-11T10:00:00Z'),
      _post(id: 'new', isAgent: true, updatedAt: '2026-07-11T12:00:00Z'),
    ]);

    expect(groups.single.posts.map((p) => p.id), ['new', 'old']);
  });
}
