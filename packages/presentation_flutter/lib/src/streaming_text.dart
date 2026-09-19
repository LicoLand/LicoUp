import 'package:flutter/material.dart';

/// Supported types of markdown blocks in [StreamingText].
enum StreamingBlockType {
  paragraph,
  heading,
  code,
  blockquote,
  bulletList,
  orderedList,
}

/// One parsed markdown block in a streaming document.
final class StreamingBlock {
  const StreamingBlock({
    required this.type,
    required this.text,
    this.level = 1,
    this.language = '',
    this.isClosed = true,
  });

  final StreamingBlockType type;
  final String text;
  final int level;
  final String language;
  final bool isClosed;

  int get contentHash => Object.hash(type, text, level, language, isClosed);
}

/// High-performance text and markdown presenter designed for live streaming responses.
///
/// Features:
/// - In streaming mode ([isStreaming] = true), completed blocks are sealed under stable keys
///   to eliminate re-layout of already-rendered lines.
/// - The growing tail block updates reactively; an unclosed code block renders its container frame
///   immediately instead of waiting for the closing fence.
/// - Isolated behind a [RepaintBoundary] so each token does not repaint parent viewports.
/// - Supports headings, fenced code blocks, blockquotes, bullet & numbered lists, and inline styles
///   (bold, italic, code spans, links).
/// - Optional [onCopy] callback and copy interaction.
class StreamingText extends StatelessWidget {
  const StreamingText({
    super.key,
    required this.document,
    this.isStreaming = false,
    this.style,
    this.codeStyle,
    this.quoteStyle,
    this.headingStyle,
    this.onCopy,
    this.blockSpacing = 8.0,
    this.selectable = false,
  });

  /// The text or markdown document to render.
  final String document;

  /// Whether the document is actively receiving streaming tokens.
  final bool isStreaming;

  /// Base text style for ordinary paragraphs.
  final TextStyle? style;

  /// Style for fenced code blocks.
  final TextStyle? codeStyle;

  /// Style for blockquotes.
  final TextStyle? quoteStyle;

  /// Base style for headings.
  final TextStyle? headingStyle;

  /// Callback executed when the user copies or requests copy of the document.
  final VoidCallback? onCopy;

  /// Vertical spacing between markdown blocks.
  final double blockSpacing;

  /// Whether the text is selectable.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    if (document.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final defaultBodyStyle =
        style ??
        theme.textTheme.bodyMedium ??
        const TextStyle(fontSize: 14, height: 1.5);

    final parsedBlocks = _parseBlocks(document, isStreaming);
    if (parsedBlocks.isEmpty) {
      return const SizedBox.shrink();
    }

    final blockWidgets = <Widget>[];

    for (var i = 0; i < parsedBlocks.length; i++) {
      final block = parsedBlocks[i];
      final isTail = isStreaming && i == parsedBlocks.length - 1;

      // Stable key for completed blocks; tail has dynamic key
      final key = isTail
          ? const ValueKey<String>('streaming-tail-block')
          : ValueKey<String>('block-$i-${block.contentHash}');

      final blockWidget = _buildBlockWidget(
        context,
        block,
        defaultBodyStyle,
        isTail: isTail,
      );

      if (blockWidgets.isNotEmpty) {
        blockWidgets.add(SizedBox(height: blockSpacing));
      }

      blockWidgets.add(KeyedSubtree(key: key, child: blockWidget));
    }

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blockWidgets,
    );

    if (onCopy != null) {
      content = GestureDetector(onDoubleTap: onCopy, child: content);
    }

    // Isolate frame repaints during active streaming
    return RepaintBoundary(child: content);
  }

  Widget _buildBlockWidget(
    BuildContext context,
    StreamingBlock block,
    TextStyle baseStyle, {
    required bool isTail,
  }) {
    switch (block.type) {
      case StreamingBlockType.heading:
        final factor = switch (block.level) {
          1 => 1.6,
          2 => 1.4,
          3 => 1.25,
          _ => 1.1,
        };
        final hStyle = (headingStyle ?? baseStyle).copyWith(
          fontSize: (baseStyle.fontSize ?? 14) * factor,
          fontWeight: FontWeight.bold,
          height: 1.3,
        );
        return _buildRichText(block.text, hStyle, context);

      case StreamingBlockType.code:
        final cStyle =
            codeStyle ??
            const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0x0D000000),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0x1A000000)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (block.language.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    block.language,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color:
                          baseStyle.color?.withValues(alpha: 0.6) ??
                          const Color(0x99000000),
                    ),
                  ),
                ),
              SelectableText(block.text, style: cStyle),
            ],
          ),
        );

      case StreamingBlockType.blockquote:
        final qStyle =
            quoteStyle ??
            baseStyle.copyWith(
              fontStyle: FontStyle.italic,
              color:
                  baseStyle.color?.withValues(alpha: 0.8) ??
                  const Color(0xCC000000),
            );
        return Container(
          padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Color(0x4D000000), width: 3),
            ),
          ),
          child: _buildRichText(block.text, qStyle, context),
        );

      case StreamingBlockType.bulletList:
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
              Expanded(child: _buildRichText(block.text, baseStyle, context)),
            ],
          ),
        );

      case StreamingBlockType.orderedList:
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${block.level}. ',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Expanded(child: _buildRichText(block.text, baseStyle, context)),
            ],
          ),
        );

      case StreamingBlockType.paragraph:
        return _buildRichText(block.text, baseStyle, context);
    }
  }

  Widget _buildRichText(
    String text,
    TextStyle baseStyle,
    BuildContext context,
  ) {
    final spans = parseInlineSpans(text, baseStyle);
    if (selectable) {
      return SelectableText.rich(TextSpan(children: spans));
    }
    return Text.rich(TextSpan(children: spans));
  }

  /// Parses inline markdown elements (bold, italic, inline code, link).
  static List<InlineSpan> parseInlineSpans(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    var cursor = 0;

    while (cursor < text.length) {
      // 1. Inline code: `code`
      if (text[cursor] == '`') {
        final end = text.indexOf('`', cursor + 1);
        if (end != -1) {
          final code = text.substring(cursor + 1, end);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0x14000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  code,
                  style: baseStyle.copyWith(
                    fontFamily: 'monospace',
                    fontSize: (baseStyle.fontSize ?? 14) * 0.9,
                  ),
                ),
              ),
            ),
          );
          cursor = end + 1;
          continue;
        }
      }

      // 2. Bold: **bold**
      if (cursor + 1 < text.length &&
          text.substring(cursor, cursor + 2) == '**') {
        final end = text.indexOf('**', cursor + 2);
        if (end != -1) {
          final boldText = text.substring(cursor + 2, end);
          spans.add(
            TextSpan(
              text: boldText,
              style: baseStyle.copyWith(fontWeight: FontWeight.bold),
            ),
          );
          cursor = end + 2;
          continue;
        }
      }

      // 3. Italic: *italic*
      if (text[cursor] == '*' &&
          (cursor + 1 >= text.length || text[cursor + 1] != '*')) {
        final end = text.indexOf('*', cursor + 1);
        if (end != -1) {
          final italicText = text.substring(cursor + 1, end);
          spans.add(
            TextSpan(
              text: italicText,
              style: baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          cursor = end + 1;
          continue;
        }
      }

      // 4. Link: [label](url)
      if (text[cursor] == '[') {
        final closeBracket = text.indexOf(']', cursor + 1);
        if (closeBracket != -1 &&
            closeBracket + 1 < text.length &&
            text[closeBracket + 1] == '(') {
          final closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen != -1) {
            final label = text.substring(cursor + 1, closeBracket);
            spans.add(
              TextSpan(
                text: label,
                style: baseStyle.copyWith(
                  color: const Color(0xFF0066CC),
                  decoration: TextDecoration.underline,
                ),
              ),
            );
            cursor = closeParen + 1;
            continue;
          }
        }
      }

      // Regular text accumulation up to the next special char
      final nextSpecial = _findNextSpecial(text, cursor);
      spans.add(
        TextSpan(text: text.substring(cursor, nextSpecial), style: baseStyle),
      );
      cursor = nextSpecial;
    }

    return spans;
  }

  static int _findNextSpecial(String text, int from) {
    for (var i = from + 1; i < text.length; i++) {
      final ch = text[i];
      if (ch == '`' || ch == '*' || ch == '[') {
        return i;
      }
    }
    return text.length;
  }

  /// Parses markdown document text into [StreamingBlock]s.
  static List<StreamingBlock> _parseBlocks(String doc, bool isStreaming) {
    final blocks = <StreamingBlock>[];
    final lines = doc.split('\n');
    var i = 0;

    while (i < lines.length) {
      final rawLine = lines[i];

      // Code fence start
      if (rawLine.trimLeft().startsWith('```')) {
        final trimmed = rawLine.trim();
        final language = trimmed.length > 3 ? trimmed.substring(3).trim() : '';
        final codeLines = <String>[];
        var closed = false;
        i++;

        while (i < lines.length) {
          if (lines[i].trim() == '```') {
            closed = true;
            i++;
            break;
          }
          codeLines.add(lines[i]);
          i++;
        }

        blocks.add(
          StreamingBlock(
            type: StreamingBlockType.code,
            text: codeLines.join('\n'),
            language: language,
            isClosed: closed,
          ),
        );
        continue;
      }

      final line = rawLine.trim();
      if (line.isEmpty) {
        i++;
        continue;
      }

      // Headings: #, ##, ###
      if (line.startsWith('#')) {
        var level = 0;
        while (level < line.length && line[level] == '#') {
          level++;
        }
        if (level < line.length && line[level] == ' ') {
          blocks.add(
            StreamingBlock(
              type: StreamingBlockType.heading,
              text: line.substring(level + 1).trim(),
              level: level,
            ),
          );
          i++;
          continue;
        }
      }

      // Blockquotes: >
      if (line.startsWith('>')) {
        blocks.add(
          StreamingBlock(
            type: StreamingBlockType.blockquote,
            text: line.substring(1).trim(),
          ),
        );
        i++;
        continue;
      }

      // Bullet lists: - or *
      if ((line.startsWith('- ') || line.startsWith('* ')) && line.length > 2) {
        blocks.add(
          StreamingBlock(
            type: StreamingBlockType.bulletList,
            text: line.substring(2).trim(),
          ),
        );
        i++;
        continue;
      }

      // Ordered lists: 1. 2. etc.
      final dotIndex = line.indexOf('. ');
      if (dotIndex > 0 && dotIndex < 5) {
        final numPart = line.substring(0, dotIndex);
        final parsedNum = int.tryParse(numPart);
        if (parsedNum != null) {
          blocks.add(
            StreamingBlock(
              type: StreamingBlockType.orderedList,
              text: line.substring(dotIndex + 2).trim(),
              level: parsedNum,
            ),
          );
          i++;
          continue;
        }
      }

      // Paragraph: accumulate lines until blank line or special block
      final paraLines = <String>[rawLine];
      i++;
      while (i < lines.length) {
        final next = lines[i];
        final nextTrimmed = next.trim();
        if (nextTrimmed.isEmpty ||
            nextTrimmed.startsWith('```') ||
            nextTrimmed.startsWith('#') ||
            nextTrimmed.startsWith('>') ||
            nextTrimmed.startsWith('- ') ||
            nextTrimmed.startsWith('* ') ||
            (nextTrimmed.indexOf('. ') > 0 &&
                int.tryParse(
                      nextTrimmed.substring(0, nextTrimmed.indexOf('. ')),
                    ) !=
                    null)) {
          break;
        }
        paraLines.add(next);
        i++;
      }

      blocks.add(
        StreamingBlock(
          type: StreamingBlockType.paragraph,
          text: paraLines.join('\n'),
        ),
      );
    }

    return blocks;
  }
}
