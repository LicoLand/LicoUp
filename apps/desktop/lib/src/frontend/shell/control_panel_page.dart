import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_display_grouping.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/agent_feed_comment_sheet.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/desktop_home_feed_compose_bar.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/desktop_home_feed_post_row.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Desktop home entry: left feed stream, right reserved panes, floating compose.
class ControlPanelPage extends StatefulWidget {
  const ControlPanelPage({super.key, required this.controller});

  final ClientController controller;

  @override
  State<ControlPanelPage> createState() => _ControlPanelPageState();
}

class _ControlPanelPageState extends State<ControlPanelPage> {
  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(controller.refreshFeedPosts());
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 1,
            child: _HomeFeedColumn(
              controller: controller,
              onReply: _showCommentSheet,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 1,
            child: Column(
              children: [
                Expanded(
                  child: _ReservedPane(
                    key: const Key('desktop-home-right-top-pane'),
                    colors: colors,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _ReservedPane(
                    key: const Key('desktop-home-right-bottom-pane'),
                    colors: colors,
                  ),
                ),
              ],
            ),
          ),
        ],
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
}

class _HomeFeedColumn extends StatelessWidget {
  const _HomeFeedColumn({required this.controller, required this.onReply});

  final ClientController controller;
  final ValueChanged<AgentFeedPost> onReply;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.line.withAlpha(70)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final groups = groupFeedPostsForDisplay(
                  controller.feedTimeline.posts,
                );
                return RefreshIndicator(
                  onRefresh: controller.refreshFeedPosts,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (groups.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyHomeFeed(
                            strings: strings,
                            colors: colors,
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 108),
                          sliver: SliverList(
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final group = groups[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _FeedGroupCard(
                                  group: group,
                                  onReply: onReply,
                                ),
                              );
                            }, childCount: groups.length),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: DesktopHomeFeedComposeBar(controller: controller),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReservedPane extends StatelessWidget {
  const _ReservedPane({super.key, required this.colors});

  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withAlpha(120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.line.withAlpha(70)),
      ),
    );
  }
}

class _FeedGroupCard extends StatelessWidget {
  const _FeedGroupCard({required this.group, required this.onReply});

  final FeedDisplayGroup group;
  final ValueChanged<AgentFeedPost> onReply;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isAgent = group.isAgentGroup;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isAgent ? colors.surface : colors.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAgent
              ? colors.line.withAlpha(90)
              : colors.info.withAlpha(120),
          width: isAgent ? 1 : 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < group.posts.length; i++)
            DesktopHomeFeedPostRow(
              post: group.posts[i],
              onReply: () => onReply(group.posts[i]),
              showDividerBelow: i < group.posts.length - 1,
            ),
        ],
      ),
    );
  }
}

class _EmptyHomeFeed extends StatelessWidget {
  const _EmptyHomeFeed({required this.strings, required this.colors});

  final LicoStrings strings;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dynamic_feed_outlined,
              size: 40,
              color: colors.textMuted.withAlpha(160),
            ),
            const SizedBox(height: 14),
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
