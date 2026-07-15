import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/agent_feed_models.dart';

/// Immutable container for all feed data persisted on the client.
@immutable
class AgentFeedTimeline {
  const AgentFeedTimeline({
    this.posts = const [],
    this.dispatchOutcomes = const [],
    this.comments = const [],
    this.reposts = const [],
    this.following = const [],
  });

  static const currentSchemaVersion = 2;

  final List<AgentFeedPost> posts;
  final List<AgentFeedDispatchOutcome> dispatchOutcomes;
  final List<AgentFeedComment> comments;
  final List<AgentFeedRepost> reposts;
  final List<AgentFeedFollowing> following;

  static AgentFeedTimeline defaults() => const AgentFeedTimeline();

  AgentFeedTimeline copyWith({
    List<AgentFeedPost>? posts,
    List<AgentFeedDispatchOutcome>? dispatchOutcomes,
    List<AgentFeedComment>? comments,
    List<AgentFeedRepost>? reposts,
    List<AgentFeedFollowing>? following,
  }) {
    return AgentFeedTimeline(
      posts: posts ?? this.posts,
      dispatchOutcomes: dispatchOutcomes ?? this.dispatchOutcomes,
      comments: comments ?? this.comments,
      reposts: reposts ?? this.reposts,
      following: following ?? this.following,
    );
  }

  factory AgentFeedTimeline.fromJson(Map<String, dynamic> json) {
    final posts = _parseList(json['posts'], AgentFeedPost.fromJson);
    final schemaVersion = _parseSchemaVersion(json['schemaVersion']);
    final outcomesByKey =
        <({String dispatchId, String targetId}), AgentFeedDispatchOutcome>{};
    for (final outcome in _parseList(
      json['dispatchOutcomes'],
      AgentFeedDispatchOutcome.fromJson,
    )) {
      if (outcome.dispatchId.trim().isEmpty ||
          outcome.targetId.trim().isEmpty) {
        continue;
      }
      outcomesByKey[outcome.key] =
          outcome.status == AgentFeedDispatchStatus.running
          ? outcome.copyWith(
              status: AgentFeedDispatchStatus.retryable,
              errorCode: 'dispatch_interrupted',
            )
          : outcome;
    }
    if (schemaVersion < currentSchemaVersion) {
      for (final post in posts) {
        final dispatchId = post.dispatchId.trim();
        if (dispatchId.isEmpty) {
          continue;
        }
        final targets = post.sourceAgentIds.isNotEmpty
            ? post.sourceAgentIds
            : [if (post.sourceAgentId.trim().isNotEmpty) post.sourceAgentId];
        for (final targetId in targets) {
          final normalizedTarget = targetId.trim();
          if (normalizedTarget.isEmpty) {
            continue;
          }
          final key = (dispatchId: dispatchId, targetId: normalizedTarget);
          outcomesByKey.putIfAbsent(
            key,
            () => AgentFeedDispatchOutcome(
              dispatchId: dispatchId,
              targetId: normalizedTarget,
              status: post.status == AgentFeedPostStatus.working
                  ? AgentFeedDispatchStatus.retryable
                  : AgentFeedDispatchStatus.failed,
              attemptCount: 0,
              updatedAt: post.updatedAt,
              errorCode: 'legacy_dispatch_outcome_unknown',
            ),
          );
        }
      }
    }
    final outcomes = List<AgentFeedDispatchOutcome>.unmodifiable(
      outcomesByKey.values,
    );
    return AgentFeedTimeline(
      posts: [
        for (final post in posts)
          post.dispatchId.trim().isEmpty
              ? post
              : post.copyWith(
                  status: deriveAgentFeedPostStatus(post, outcomes),
                ),
      ],
      dispatchOutcomes: outcomes,
      comments: _parseList(json['comments'], AgentFeedComment.fromJson),
      reposts: _parseList(json['reposts'], AgentFeedRepost.fromJson),
      following: _parseList(json['following'], AgentFeedFollowing.fromJson),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': currentSchemaVersion,
      'posts': posts.map((p) => p.toJson()).toList(growable: false),
      'dispatchOutcomes': dispatchOutcomes
          .map((outcome) => outcome.toJson())
          .toList(growable: false),
      'comments': comments.map((c) => c.toJson()).toList(growable: false),
      'reposts': reposts.map((r) => r.toJson()).toList(growable: false),
      'following': following.map((f) => f.toJson()).toList(growable: false),
    };
  }
}

AgentFeedPostStatus deriveAgentFeedPostStatus(
  AgentFeedPost post,
  Iterable<AgentFeedDispatchOutcome> outcomes,
) {
  final dispatchId = post.dispatchId.trim();
  if (dispatchId.isEmpty) {
    return post.status;
  }
  final matching = [
    for (final outcome in outcomes)
      if (outcome.dispatchId == dispatchId) outcome,
  ];
  if (matching.isEmpty) {
    return AgentFeedPostStatus.error;
  }
  final anySucceeded = matching.any(
    (outcome) => outcome.status == AgentFeedDispatchStatus.succeeded,
  );
  final anyFailed = matching.any(
    (outcome) => outcome.status == AgentFeedDispatchStatus.failed,
  );
  final anyInProgress = matching.any(
    (outcome) =>
        outcome.status == AgentFeedDispatchStatus.pending ||
        outcome.status == AgentFeedDispatchStatus.running ||
        outcome.status == AgentFeedDispatchStatus.retryable,
  );
  if (anyInProgress) {
    return anySucceeded || anyFailed
        ? AgentFeedPostStatus.partial
        : AgentFeedPostStatus.working;
  }
  if (matching.every(
    (outcome) => outcome.status == AgentFeedDispatchStatus.succeeded,
  )) {
    return post.attachments.any((attachment) => !attachment.accepted)
        ? AgentFeedPostStatus.partial
        : AgentFeedPostStatus.done;
  }
  return anySucceeded ? AgentFeedPostStatus.partial : AgentFeedPostStatus.error;
}

abstract class AgentFeedStore {
  const AgentFeedStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}

List<T> _parseList<T>(
  dynamic value,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

int _parseSchemaVersion(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString() ?? '') ?? 1;
}
