import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/agent_feed_comment_sheet.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/agent_feed_following_sheet.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/agent_feed_handoff_dialog.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/agent_feed_post_card.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentFeedHome extends StatefulWidget {
  const AgentFeedHome({super.key, required this.controller});

  final ClientController controller;

  @override
  State<AgentFeedHome> createState() => _AgentFeedHomeState();
}

class _AgentFeedHomeState extends State<AgentFeedHome> {
  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.refreshFeedPosts());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final posts = controller.feedTimeline.posts.toList(growable: false)
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

            return RefreshIndicator(
              onRefresh: controller.refreshFeedPosts,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 14, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              strings.feed,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          IconButton(
                            key: const Key('feed-following-button'),
                            tooltip: strings.following,
                            onPressed: _showFollowingSheet,
                            icon: Icon(
                              Icons.people_outline_rounded,
                              color: colors.text,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (posts.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _FeedEmptyState(strings: strings),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 20),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final post = posts[index];
                          return AgentFeedPostCard(
                            controller: controller,
                            post: post,
                            onComment: () => _showCommentSheet(post),
                            onRepost: () => _showHandoffDialog(post),
                            onToggleFollow: () =>
                                controller.toggleFollowAuthor(post.author),
                            onDelete: () => _confirmDeletePost(post),
                          );
                        }, childCount: posts.length),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showCommentSheet(AgentFeedPost post) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.licoColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          AgentFeedCommentSheet(controller: controller, post: post),
    );
  }

  Future<void> _showHandoffDialog(AgentFeedPost post) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          AgentFeedHandoffDialog(controller: controller, post: post),
    );
  }

  Future<void> _showFollowingSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.licoColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => AgentFeedFollowingSheet(controller: controller),
    );
  }

  Future<void> _confirmDeletePost(AgentFeedPost post) async {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          strings.deletePost,
          style: TextStyle(
            color: colors.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          strings.deletePostConfirm,
          style: TextStyle(color: colors.text, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              strings.cancel,
              style: TextStyle(color: colors.textMuted),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.deleteFeedPost(post.id);
    }
  }
}

class _FeedEmptyState extends StatelessWidget {
  const _FeedEmptyState({required this.strings});

  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 48,
              color: colors.textMuted.withAlpha(120),
            ),
            const SizedBox(height: 16),
            Text(
              strings.feedEmptyTitle,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              strings.feedEmptySubtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
