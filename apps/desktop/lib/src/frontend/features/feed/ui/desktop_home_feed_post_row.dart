import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/feed_author_avatar.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Single Threads-style post row used inside desktop home feed cards.
class DesktopHomeFeedPostRow extends StatelessWidget {
  const DesktopHomeFeedPostRow({
    super.key,
    required this.post,
    required this.onReply,
    this.showDividerBelow = false,
  });

  final AgentFeedPost post;
  final VoidCallback onReply;
  final bool showDividerBelow;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final timeLabel = _relativeTimeLabel(post.updatedAt);
    final commentCount = post.commentIds.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FeedAuthorAvatar(author: post.author),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            post.author.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (timeLabel.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '·',
                              style: TextStyle(color: colors.textMuted),
                            ),
                          ),
                          Text(
                            timeLabel,
                            style: TextStyle(
                              color: colors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (post.title.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        post.title,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (post.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: MessageMarkdown(
                            data: post.body,
                            foreground: colors.text,
                            accent: colors.primary,
                            codeBackground: colors.surfaceLow,
                            blockBackground: colors.surfaceLow,
                            borderColor: colors.line,
                            renderStyle: const MessageMarkdownStyle(
                              bodyFontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    InkWell(
                      key: Key('desktop-home-feed-reply-${post.id}'),
                      onTap: onReply,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 18,
                              color: colors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              commentCount > 0
                                  ? '$commentCount'
                                  : strings.reply,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showDividerBelow)
          Divider(
            height: 1,
            thickness: 1,
            color: colors.line.withAlpha(70),
            indent: 16,
            endIndent: 16,
          ),
      ],
    );
  }

  String _relativeTimeLabel(String iso) {
    final updated = DateTime.tryParse(iso)?.toLocal();
    if (updated == null) {
      return '';
    }
    final diff = DateTime.now().difference(updated);
    if (diff.inMinutes < 1) {
      return 'now';
    }
    if (diff.inHours < 1) {
      return '${diff.inMinutes}m';
    }
    if (diff.inDays < 1) {
      return '${diff.inHours}h';
    }
    if (diff.inDays < 7) {
      return '${diff.inDays}d';
    }
    return '${updated.month}/${updated.day}';
  }
}
