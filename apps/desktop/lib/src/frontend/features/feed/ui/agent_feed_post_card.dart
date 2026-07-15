import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/feed_author_avatar.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentFeedPostCard extends StatelessWidget {
  const AgentFeedPostCard({
    super.key,
    required this.controller,
    required this.post,
    required this.onComment,
    required this.onRepost,
    required this.onToggleFollow,
    required this.onDelete,
  });

  final ClientController controller;
  final AgentFeedPost post;
  final VoidCallback onComment;
  final VoidCallback onRepost;
  final VoidCallback onToggleFollow;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final timeLabel = _timeLabel(context, post.updatedAt);
    final isFollowing = controller.feedTimeline.following.any(
      (f) => f.author.id == post.author.id,
    );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: colors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line.withAlpha(80)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              post: post,
              timeLabel: timeLabel,
              statusLabel: _statusLabel(strings, post.status),
              statusColor: _statusColor(colors, post.status),
              isFollowing: isFollowing,
              onToggleFollow: onToggleFollow,
              onDelete: onDelete,
            ),
            const SizedBox(height: 10),
            Text(
              post.title,
              style: TextStyle(
                color: colors.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
            if (post.body.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              _Body(body: post.body),
            ],
            if (post.metrics.stepCount > 0 ||
                post.metrics.durationMillis > 0) ...[
              const SizedBox(height: 10),
              _Metrics(post: post, strings: strings),
            ],
            const SizedBox(height: 12),
            _ActionBar(
              post: post,
              strings: strings,
              onComment: onComment,
              onRepost: onRepost,
            ),
          ],
        ),
      ),
    );
  }

  String _timeLabel(BuildContext context, String iso) {
    final updated = DateTime.tryParse(iso)?.toLocal();
    if (updated == null) {
      return '';
    }
    final now = DateTime.now();
    final sameDay =
        updated.year == now.year &&
        updated.month == now.month &&
        updated.day == now.day;
    if (sameDay) {
      return '${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
    }
    return '${updated.month}/${updated.day}';
  }

  String _statusLabel(LicoStrings strings, AgentFeedPostStatus status) {
    return switch (status) {
      AgentFeedPostStatus.working => strings.agentWorking,
      AgentFeedPostStatus.partial => strings.agentPartial,
      AgentFeedPostStatus.done => strings.agentDone,
      AgentFeedPostStatus.error => strings.agentError,
    };
  }

  Color _statusColor(LicoThemeColors colors, AgentFeedPostStatus status) {
    return switch (status) {
      AgentFeedPostStatus.working => colors.warning,
      AgentFeedPostStatus.partial => colors.info,
      AgentFeedPostStatus.done => colors.success,
      AgentFeedPostStatus.error => colors.error,
    };
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.post,
    required this.timeLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.isFollowing,
    required this.onToggleFollow,
    required this.onDelete,
  });

  final AgentFeedPost post;
  final String timeLabel;
  final String statusLabel;
  final Color statusColor;
  final bool isFollowing;
  final VoidCallback onToggleFollow;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);

    return Row(
      children: [
        FeedAuthorAvatar(author: post.author, size: 40, iconSize: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                post.author.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (timeLabel.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '· $timeLabel',
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        _FollowButton(isFollowing: isFollowing, onToggle: onToggleFollow),
        _MoreMenu(strings: strings, onDelete: onDelete),
      ],
    );
  }
}

class _FollowButton extends StatelessWidget {
  const _FollowButton({required this.isFollowing, required this.onToggle});

  final bool isFollowing;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return TextButton(
      onPressed: onToggle,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        isFollowing ? strings.unfollow : strings.follow,
        style: TextStyle(
          color: isFollowing ? colors.textMuted : colors.primary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.strings, required this.onDelete});

  final LicoStrings strings;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return PopupMenuButton<VoidCallback>(
      icon: Icon(Icons.more_vert_rounded, size: 20, color: colors.textMuted),
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: onDelete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: colors.error),
              const SizedBox(width: 10),
              Text(strings.deletePost, style: TextStyle(color: colors.error)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    // Keep feed cards compact: collapse long bodies visually.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 180),
      child: ShaderMask(
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.text, colors.text, Colors.transparent],
            stops: const [0.0, 0.85, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: MessageMarkdown(
            data: body,
            foreground: colors.text,
            accent: colors.primary,
            codeBackground: colors.surfaceLow,
            blockBackground: colors.surfaceLow,
            borderColor: colors.line,
            renderStyle: const MessageMarkdownStyle(bodyFontSize: 13),
          ),
        ),
      ),
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.post, required this.strings});

  final AgentFeedPost post;
  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final elapsedSeconds = (post.metrics.durationMillis / 1000).round();
    final durationLabel = elapsedSeconds < 60
        ? strings.feedDurationSeconds(elapsedSeconds)
        : strings.feedDurationMinutes(
            elapsedSeconds ~/ 60,
            elapsedSeconds % 60,
          );
    return Wrap(
      spacing: 10,
      children: [
        _MetricChip(icon: Icons.timer_outlined, label: durationLabel),
        if (post.metrics.stepCount > 0)
          _MetricChip(
            icon: Icons.format_list_numbered_outlined,
            label: strings.feedMetrics(
              post.metrics.stepCount,
              post.metrics.tokenCount,
            ),
          ),
        if (post.metrics.issueCount > 0)
          _MetricChip(
            icon: Icons.error_outline_rounded,
            label: '${post.metrics.issueCount}',
            color: colors.error,
          ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color ?? colors.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color ?? colors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.post,
    required this.strings,
    required this.onComment,
    required this.onRepost,
  });

  final AgentFeedPost post;
  final LicoStrings strings;
  final VoidCallback onComment;
  final VoidCallback onRepost;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      children: [
        _ActionButton(
          icon: Icons.chat_bubble_outline_rounded,
          count: post.commentIds.length,
          onTap: onComment,
        ),
        const SizedBox(width: 18),
        _ActionButton(
          icon: Icons.repeat_rounded,
          count: post.repostIds.length,
          onTap: onRepost,
        ),
        const Spacer(),
        Text(
          strings.comments,
          style: TextStyle(color: colors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: colors.textMuted),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
