import '../../agent_feed_models.dart';
import '../../agent_feed_timeline.dart';
import '../../mobile_agent_account.dart';
import '../../target_candidate.dart';
import 'layout_destination_port.dart';

/// Immutable semantic data rendered by the Feed and Control Panel destinations.
final class FeedDestinationSnapshot {
  factory FeedDestinationSnapshot({
    required AgentFeedTimeline timeline,
    required Iterable<TargetCandidate> visibleTargets,
    required Iterable<MobileAgentAccount> mobileAgentAccounts,
  }) {
    return FeedDestinationSnapshot._(
      timeline: _freezeTimeline(timeline),
      visibleTargets: List<TargetCandidate>.unmodifiable(
        visibleTargets.where((target) => target.visibleInClient),
      ),
      mobileAgentAccounts: List<MobileAgentAccount>.unmodifiable(
        mobileAgentAccounts,
      ),
    );
  }

  const FeedDestinationSnapshot._({
    required this.timeline,
    required this.visibleTargets,
    required this.mobileAgentAccounts,
  });

  final AgentFeedTimeline timeline;
  final List<TargetCandidate> visibleTargets;
  final List<MobileAgentAccount> mobileAgentAccounts;

  FeedDestinationSnapshot copyWith({
    AgentFeedTimeline? timeline,
    Iterable<TargetCandidate>? visibleTargets,
    Iterable<MobileAgentAccount>? mobileAgentAccounts,
  }) {
    return FeedDestinationSnapshot._(
      timeline: timeline == null ? this.timeline : _freezeTimeline(timeline),
      visibleTargets: visibleTargets == null
          ? this.visibleTargets
          : List<TargetCandidate>.unmodifiable(
              visibleTargets.where((target) => target.visibleInClient),
            ),
      mobileAgentAccounts: mobileAgentAccounts == null
          ? this.mobileAgentAccounts
          : List<MobileAgentAccount>.unmodifiable(mobileAgentAccounts),
    );
  }
}

/// Pure semantic port shared by Feed and Control Panel renderers.
///
/// Presentation and application implementation types must not cross this
/// boundary. A layout owns its renderer while this port owns only data and
/// intent.
abstract interface class FeedDestinationPort
    implements LayoutDestinationPort<FeedDestinationSnapshot> {
  Future<void> refreshFeedPosts();

  Future<void> createUserFeedPost({
    required String body,
    List<String> mentionedAgentIds = const [],
    List<String> attachmentPaths = const [],
  });

  Future<void> addFeedComment(
    String postId,
    String text, {
    String? replyToCommentId,
  });

  Future<void> repostFeedPost(String postId, String toAgentId, {String? note});

  Future<void> toggleFollowAuthor(AgentFeedAuthor author);

  Future<void> deleteFeedPost(String postId);
}

AgentFeedTimeline _freezeTimeline(AgentFeedTimeline source) {
  return AgentFeedTimeline(
    posts: List<AgentFeedPost>.unmodifiable(source.posts.map(_freezePost)),
    dispatchOutcomes: List<AgentFeedDispatchOutcome>.unmodifiable(
      source.dispatchOutcomes,
    ),
    comments: List<AgentFeedComment>.unmodifiable(source.comments),
    reposts: List<AgentFeedRepost>.unmodifiable(source.reposts),
    following: List<AgentFeedFollowing>.unmodifiable(source.following),
  );
}

AgentFeedPost _freezePost(AgentFeedPost source) {
  return source.copyWith(
    sourceAgentIds: List<String>.unmodifiable(source.sourceAgentIds),
    attachments: List<AgentFeedAttachment>.unmodifiable(source.attachments),
    commentIds: List<String>.unmodifiable(source.commentIds),
    repostIds: List<String>.unmodifiable(source.repostIds),
    reactionCounts: Map<String, int>.unmodifiable(source.reactionCounts),
  );
}
