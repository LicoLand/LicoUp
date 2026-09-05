import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_inline.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_parser.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

export 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
export 'package:licoup/src/frontend/shared/ui/message_markdown_parser.dart';
export 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

/// Stable composer for parsed message markdown blocks.
final class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({
    super.key,
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    this.renderStyle = const MessageMarkdownStyle(),
    this.isStreaming = false,
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  /// Whether [data] is a partially written streamed reply. Streaming mode
  /// renders the complete block prefix with final styling under stable keys
  /// and the still-growing tail in a quiet in-progress presentation; the
  /// default (false) is the exact finalized rendering.
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
      color: foreground,
      height: renderStyle.bodyLineHeight,
      fontSize: renderStyle.bodyFontSize,
      letterSpacing: 0,
    );
    if (isStreaming) {
      return _buildStreaming(context, baseStyle);
    }
    final blocks = parseMessageMarkdownBlocks(data);
    if (blocks.isEmpty) return Text('', style: baseStyle);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          MessageMarkdownBlockView(
            block: blocks[index],
            baseStyle: baseStyle,
            foreground: foreground,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
          if (index != blocks.length - 1)
            SizedBox(height: renderStyle.blockSpacing),
        ],
      ],
    );
  }

  Widget _buildStreaming(BuildContext context, TextStyle baseStyle) {
    final parsed = parseStreamingMessageMarkdownBlocks(data);
    final tail = parsed.tail;
    if (parsed.complete.isEmpty && tail == null) {
      return Text('', style: baseStyle);
    }
    final children = <Widget>[];
    for (var index = 0; index < parsed.complete.length; index++) {
      if (children.isNotEmpty) {
        children.add(SizedBox(height: renderStyle.blockSpacing));
      }
      final block = parsed.complete[index];
      // Keyed by position + content: a completed block keeps its widget while
      // the stream grows behind it, so only the changed block re-lays out.
      children.add(
        MessageMarkdownBlockView(
          key: ValueKey<String>('stream-block-$index-${block.contentHash}'),
          block: block,
          baseStyle: baseStyle,
          foreground: foreground,
          accent: accent,
          codeBackground: codeBackground,
          blockBackground: blockBackground,
          borderColor: borderColor,
          renderStyle: renderStyle,
        ),
      );
    }
    if (tail != null) {
      if (children.isNotEmpty) {
        children.add(SizedBox(height: renderStyle.blockSpacing));
      }
      children.add(_buildStreamingTail(tail, baseStyle));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// The in-progress tail keeps the calm base body presentation: no premature
  /// heading/table/list styling for half-typed lines. An unclosed code fence
  /// is the one exception — its frame renders from the opening fence and stays
  /// the same frame once the closing fence arrives.
  Widget _buildStreamingTail(MessageMarkdownBlock tail, TextStyle baseStyle) {
    if (tail.type == MessageMarkdownBlockType.code) {
      return MessageMarkdownBlockView(
        key: const ValueKey<String>('stream-tail-code'),
        block: tail,
        baseStyle: baseStyle,
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    return Text.rich(
      key: const ValueKey<String>('stream-tail-text'),
      TextSpan(
        children: messageMarkdownInlineSpans(
          tail.text,
          baseStyle,
          accent: accent,
          codeBackground: codeBackground,
        ),
      ),
    );
  }
}
