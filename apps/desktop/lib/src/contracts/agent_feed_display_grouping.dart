import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/agent_feed_models.dart';

/// One visual card in the desktop home feed stream.
///
/// Consecutive agent posts share a single group. Each user post is always its
/// own group so human and agent updates stay visually distinct.
@immutable
class FeedDisplayGroup {
  const FeedDisplayGroup({required this.posts});

  final List<AgentFeedPost> posts;

  bool get isAgentGroup =>
      posts.isNotEmpty && posts.every((post) => post.author.isAgent);

  bool get isUserGroup =>
      posts.isNotEmpty && posts.every((post) => !post.author.isAgent);
}

/// Groups posts for Threads-style display. Input may be unsorted; output groups
/// follow newest-first order within and across cards.
List<FeedDisplayGroup> groupFeedPostsForDisplay(Iterable<AgentFeedPost> posts) {
  final sorted = posts.toList(growable: false)
    ..sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      if (byUpdated != 0) {
        return byUpdated;
      }
      return b.createdAt.compareTo(a.createdAt);
    });

  final groups = <FeedDisplayGroup>[];
  for (final post in sorted) {
    if (post.author.isAgent && groups.isNotEmpty && groups.last.isAgentGroup) {
      final existing = groups.removeLast();
      groups.add(
        FeedDisplayGroup(
          posts: List<AgentFeedPost>.unmodifiable([...existing.posts, post]),
        ),
      );
      continue;
    }
    groups.add(
      FeedDisplayGroup(posts: List<AgentFeedPost>.unmodifiable([post])),
    );
  }
  return List<FeedDisplayGroup>.unmodifiable(groups);
}
