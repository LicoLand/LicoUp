import 'dart:collection';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_inline.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

/// Bounded cache for table intrinsic-width measurements. Measuring runs one
/// [TextPainter] layout per cell on every build; the prepared cell list keeps
/// its identity through the block payload, so the measured widths are reusable
/// whenever the table and its style are unchanged.
final LinkedHashMap<
  (List<List<MessageMarkdownInline>>, TextStyle, Color, Color, int),
  List<double>
>
_tableIntrinsicWidthCache = LinkedHashMap();
const int _tableIntrinsicWidthCacheLimit = 128;

/// The widest intrinsic cell width per column, measured with the same prepared
/// inline runs and base style the table renders with, so column choices match
/// the layout.
///
/// [rowCount] limits the measurement to the settled leading rows of a growing
/// table; null measures every row. This function maps prepared runs to spans
/// and measures them; it never tokenizes Markdown.
@visibleForTesting
List<double> messageMarkdownTableIntrinsicColumnWidths(
  List<List<MessageMarkdownInline>> cells,
  TextStyle baseStyle, {
  required Color accent,
  required Color codeBackground,
  int? rowCount,
}) {
  final measuredRows = rowCount ?? cells.length;
  final key = (cells, baseStyle, accent, codeBackground, measuredRows);
  final cached = _tableIntrinsicWidthCache.remove(key);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _tableIntrinsicWidthCache[key] = cached;
    return cached;
  }
  final columnCount = cells.isEmpty ? 0 : cells.first.length;
  final widths = List<double>.filled(columnCount, 0);
  for (final row in cells.take(measuredRows)) {
    for (var column = 0; column < columnCount; column += 1) {
      final painter = TextPainter(
        text: TextSpan(
          style: baseStyle,
          children: messageMarkdownInlineSpans(
            row[column],
            baseStyle,
            accent: accent,
            codeBackground: codeBackground,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (painter.width > widths[column]) {
        widths[column] = painter.width;
      }
    }
  }
  final result = List<double>.unmodifiable(widths);
  if (_tableIntrinsicWidthCache.length >= _tableIntrinsicWidthCacheLimit) {
    _tableIntrinsicWidthCache.remove(_tableIntrinsicWidthCache.keys.first);
  }
  _tableIntrinsicWidthCache[key] = result;
  return result;
}

/// Prepared cell runs of one table block, in the authored shape.
///
/// A block that carries no prepared runs (a value built outside the prepared
/// pipeline) is wrapped as plain text: the renderer shows it literally and
/// never parses it.
List<List<MessageMarkdownInline>> messageMarkdownTableCells(
  MessageMarkdownBlock block,
) {
  if (block.cellInline.length == block.rows.length) return block.cellInline;
  return <List<MessageMarkdownInline>>[
    for (final row in block.rows)
      <MessageMarkdownInline>[
        for (final cell in row) MessageMarkdownInline.plain(cell),
      ],
  ];
}

/// Prepared runs of one list item, or null when the block carries none.
MessageMarkdownInline? messageMarkdownItemInline(
  MessageMarkdownBlock block,
  int index,
) => index < block.itemInline.length ? block.itemInline[index] : null;

final class MessageMarkdownBlockView extends StatelessWidget {
  const MessageMarkdownBlockView({
    super.key,
    required this.block,
    required this.baseStyle,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final MessageMarkdownBlock block;
  final TextStyle baseStyle;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  /// The prepared display of one text field, rendered without parsing.
  ///
  /// A field without prepared runs renders literally; no path here reads
  /// Markdown structure.
  Widget _inlineText(
    MessageMarkdownInline? inline,
    String text,
    TextStyle style,
  ) {
    if (inline == null) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        children: messageMarkdownInlineSpans(
          inline,
          style,
          accent: accent,
          codeBackground: codeBackground,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return switch (block.type) {
      MessageMarkdownBlockType.heading => _inlineText(
        block.inline,
        block.text,
        messageMarkdownHeadingStyle(baseStyle, block.level, renderStyle),
      ),
      MessageMarkdownBlockType.code => _CodeBlock(
        code: block.text,
        language: block.language,
        foreground: foreground,
        background: codeBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      ),
      MessageMarkdownBlockType.quote => DecoratedBox(
        decoration: continuousHairlineDecoration(
          color: blockBackground,
          borderRadius: BorderRadius.circular(renderStyle.quoteRadius),
          stroke: borderColor,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: renderStyle.quotePaddingX,
            vertical: renderStyle.quotePaddingY,
          ),
          child: _inlineText(block.inline, block.text, baseStyle),
        ),
      ),
      MessageMarkdownBlockType.warning => _WarningBlock(
        inline: block.inline,
        text: block.text,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
      ),
      MessageMarkdownBlockType.unorderedList => _MarkdownList(
        block: block,
        ordered: false,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        renderStyle: renderStyle,
      ),
      MessageMarkdownBlockType.orderedList => _MarkdownList(
        block: block,
        ordered: true,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        renderStyle: renderStyle,
      ),
      MessageMarkdownBlockType.table => _MarkdownTable(
        cells: messageMarkdownTableCells(block),
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
      ),
      MessageMarkdownBlockType.paragraph => _inlineText(
        block.inline,
        block.text,
        baseStyle,
      ),
    };
  }
}

/// Renders one still-growing prepared block.
///
/// A block whose boundary is not settled renders calmly from its own prepared
/// display: an open heading shows its title without the marker, an open
/// paragraph its body, and an open code fence keeps its frame. A partially
/// settled list or table renders its completed items/rows with final styling
/// and only the growing remainder calmly. Every value here was prepared in the
/// worker; the view never slices or scans the source text.
final class MessageMarkdownStreamingBlockView extends StatelessWidget {
  const MessageMarkdownStreamingBlockView({
    super.key,
    required this.block,
    required this.baseStyle,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final MessageMarkdownBlock block;
  final TextStyle baseStyle;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    if (block.type == MessageMarkdownBlockType.code) {
      // An unclosed fence keeps the frame it will have when it closes.
      return MessageMarkdownBlockView(
        block: block,
        baseStyle: baseStyle,
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    final split = block.streaming;
    if (split == null) {
      return _calmText(block.inline, block.text, baseStyle);
    }
    if (split.tail == null) {
      // Every entry is settled even though the block can still grow: the
      // content renders with final styling and no calm remainder exists.
      return MessageMarkdownBlockView(
        block: block,
        baseStyle: baseStyle,
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    final children = <Widget>[];
    if (split.settledCount > 0) {
      children.add(_settledPart(split.settledCount));
    }
    if (children.isNotEmpty) {
      children.add(SizedBox(height: renderStyle.blockSpacing));
    }
    children.add(_calmText(split.tail!.inline, split.tail!.text, baseStyle));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _settledPart(int settledCount) {
    switch (block.type) {
      case MessageMarkdownBlockType.unorderedList:
        return _MarkdownList(
          block: block,
          ordered: false,
          count: settledCount,
          baseStyle: baseStyle,
          accent: accent,
          codeBackground: codeBackground,
          renderStyle: renderStyle,
        );
      case MessageMarkdownBlockType.orderedList:
        return _MarkdownList(
          block: block,
          ordered: true,
          count: settledCount,
          baseStyle: baseStyle,
          accent: accent,
          codeBackground: codeBackground,
          renderStyle: renderStyle,
        );
      case MessageMarkdownBlockType.table:
        return _MarkdownTable(
          cells: messageMarkdownTableCells(block),
          rowCount: settledCount,
          baseStyle: baseStyle,
          accent: accent,
          codeBackground: codeBackground,
          blockBackground: blockBackground,
          borderColor: borderColor,
        );
      case MessageMarkdownBlockType.paragraph:
      case MessageMarkdownBlockType.heading:
      case MessageMarkdownBlockType.code:
      case MessageMarkdownBlockType.quote:
      case MessageMarkdownBlockType.warning:
        return const SizedBox.shrink();
    }
  }

  /// The calm presentation of a growing remainder: its prepared display with
  /// the base body style, never the raw source.
  Widget _calmText(
    MessageMarkdownInline? inline,
    String text,
    TextStyle style,
  ) {
    if (inline == null) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        children: messageMarkdownInlineSpans(
          inline,
          style,
          accent: accent,
          codeBackground: codeBackground,
        ),
      ),
    );
  }
}

final class _WarningBlock extends StatelessWidget {
  const _WarningBlock({
    required this.inline,
    required this.text,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
  });

  final MessageMarkdownInline? inline;
  final String text;
  final TextStyle baseStyle;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    final textStyle = baseStyle.copyWith(
      color: error,
      fontWeight: FontWeight.w800,
    );
    return DecoratedBox(
      decoration: continuousHairlineDecoration(
        color: Color.lerp(blockBackground, error, 0.12)!,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        stroke: Color.lerp(borderColor, error, 0.7)!,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: inline == null
                  ? Text(text, style: textStyle)
                  : Text.rich(
                      TextSpan(
                        children: messageMarkdownInlineSpans(
                          inline!,
                          textStyle,
                          accent: accent,
                          codeBackground: codeBackground,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MarkdownList extends StatelessWidget {
  const _MarkdownList({
    required this.block,
    required this.ordered,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.renderStyle,
    this.count,
  });

  final MessageMarkdownBlock block;
  final bool ordered;
  final TextStyle baseStyle;
  final Color accent;
  final Color codeBackground;
  final MessageMarkdownStyle renderStyle;

  /// Renders only the first [count] items when the list is still growing.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final items = block.items;
    final rendered = count ?? items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < rendered; index++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: ordered
                    ? renderStyle.orderedListMarkerWidth
                    : renderStyle.listMarkerWidth,
                child: Text(
                  ordered ? '${index + 1}.' : renderStyle.unorderedMarker,
                  style: baseStyle.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: _itemText(
                  messageMarkdownItemInline(block, index),
                  items[index],
                  baseStyle,
                ),
              ),
            ],
          ),
          if (index != rendered - 1)
            SizedBox(height: renderStyle.listItemSpacing),
        ],
      ],
    );
  }

  Widget _itemText(
    MessageMarkdownInline? inline,
    String text,
    TextStyle style,
  ) {
    if (inline == null) return Text(text, style: style);
    return Text.rich(
      TextSpan(
        children: messageMarkdownInlineSpans(
          inline,
          style,
          accent: accent,
          codeBackground: codeBackground,
        ),
      ),
    );
  }
}

final class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({
    required this.cells,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    this.rowCount,
  });

  final List<List<MessageMarkdownInline>> cells;
  final TextStyle baseStyle;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;

  /// Renders only the first [rowCount] rows when the table is still growing.
  final int? rowCount;

  static const _cellHorizontalPadding = 10.0;

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) return const SizedBox.shrink();
    final renderedRows = rowCount ?? cells.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Columns narrower than an equal share keep their intrinsic content
        // width; wider columns become flex columns that take the remaining
        // space, so their text wraps instead of scrolling horizontally.
        final tableWidth = constraints.maxWidth;
        final columnWidths = <int, TableColumnWidth>{};
        if (tableWidth.isFinite) {
          final intrinsicWidths = messageMarkdownTableIntrinsicColumnWidths(
            cells,
            baseStyle,
            accent: accent,
            codeBackground: codeBackground,
            rowCount: renderedRows,
          );
          final contentWidth =
              tableWidth - 2 - cells.first.length * _cellHorizontalPadding * 2;
          final equalShare = contentWidth / cells.first.length;
          for (var c = 0; c < cells.first.length; c++) {
            columnWidths[c] = intrinsicWidths[c] <= equalShare
                ? const IntrinsicColumnWidth()
                : const FlexColumnWidth();
          }
        }
        return DecoratedBox(
          decoration: continuousHairlineDecoration(
            borderRadius: BorderRadius.circular(6),
            stroke: borderColor,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Table(
              columnWidths: columnWidths,
              defaultColumnWidth: const FlexColumnWidth(),
              border: TableBorder(
                horizontalInside: BorderSide(color: borderColor),
                verticalInside: BorderSide(color: borderColor),
              ),
              children: [
                for (var rowIndex = 0; rowIndex < renderedRows; rowIndex++)
                  TableRow(
                    decoration: BoxDecoration(
                      color: rowIndex == 0
                          ? blockBackground
                          : Colors.transparent,
                    ),
                    children: [
                      for (final cell in cells[rowIndex])
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _cellHorizontalPadding,
                            vertical: 8,
                          ),
                          child: Text.rich(
                            TextSpan(
                              children: messageMarkdownInlineSpans(
                                cell,
                                rowIndex == 0
                                    ? baseStyle.copyWith(
                                        fontWeight: FontWeight.w800,
                                      )
                                    : baseStyle,
                                accent: accent,
                                codeBackground: codeBackground,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.foreground,
    required this.background,
    required this.borderColor,
    required this.renderStyle,
  });

  final String code;
  final String language;
  final Color foreground;
  final Color background;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: continuousHairlineDecoration(
        color: background,
        borderRadius: BorderRadius.circular(renderStyle.codeRadius),
        stroke: borderColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (renderStyle.showCodeLanguage && language.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                renderStyle.codePadding,
                renderStyle.codePadding,
                renderStyle.codePadding,
                0,
              ),
              child: Text(
                language.trim(),
                style: TextStyle(
                  color: foreground.withAlpha(180),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'SF Mono',
                  fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.all(renderStyle.codePadding),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                code,
                style: TextStyle(
                  color: foreground,
                  height: renderStyle.codeLineHeight,
                  fontSize: renderStyle.codeFontSize,
                  fontFamily: 'SF Mono',
                  fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
