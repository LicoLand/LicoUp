import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentFeedCommentSheet extends StatefulWidget {
  const AgentFeedCommentSheet({
    super.key,
    required this.controller,
    required this.post,
  });

  final ClientController controller;
  final AgentFeedPost post;

  @override
  State<AgentFeedCommentSheet> createState() => _AgentFeedCommentSheetState();
}

class _AgentFeedCommentSheetState extends State<AgentFeedCommentSheet> {
  final TextEditingController _textController = TextEditingController();
  bool _posting = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final comments =
        widget.controller.feedTimeline.comments
            .where((c) => c.postId == widget.post.id)
            .toList(growable: false)
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.line.withAlpha(100)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.comments,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: colors.textMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: comments.isEmpty
                ? _EmptyComments(strings: strings)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      return _CommentTile(comment: comments[index]);
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  top: BorderSide(color: colors.line.withAlpha(100)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      enabled: !_posting,
                      maxLines: null,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        hintText: strings.addCommentHint,
                        hintStyle: TextStyle(color: colors.textMuted),
                        filled: true,
                        fillColor: colors.background,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      style: TextStyle(color: colors.text, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _posting ? null : _submit,
                    icon: _posting
                        ? SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.primary,
                            ),
                          )
                        : Icon(Icons.send_rounded, color: colors.primary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _posting) {
      return;
    }
    setState(() => _posting = true);
    await widget.controller.addFeedComment(widget.post.id, text);
    if (!mounted) {
      return;
    }
    _textController.clear();
    setState(() => _posting = false);
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment});

  final AgentFeedComment comment;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(
                comment.author.isAgent
                    ? Icons.smart_toy_outlined
                    : Icons.person_outline,
                size: 16,
                color: colors.textMuted,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      comment.author.displayName,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _timeLabel(context, comment.createdAt),
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  comment.text,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
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
}

class _EmptyComments extends StatelessWidget {
  const _EmptyComments({required this.strings});

  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          strings.noCommentsYet,
          style: TextStyle(color: colors.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}
