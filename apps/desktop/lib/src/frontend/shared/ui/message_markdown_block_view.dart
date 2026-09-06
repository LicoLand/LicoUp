import 'dart:collection';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_inline.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

/// Bounded cache for table intrinsic-width measurements. Measuring runs one
/// [TextPainter] layout per cell on every build; the parsed rows list keeps
/// its identity per content through the block-parse cache, so the measured
/// widths are reusable whenever the table and its style are unchanged.
final LinkedHashMap<(List<List<String>>, TextStyle, Color, Color), List<double>>
_tableIntrinsicWidthCache = LinkedHashMap();
const int _tableIntrinsicWidthCacheLimit = 128;

/// The widest intrinsic cell width per column, measured with the same inline
/// spans and base style the table renders with, so column choices match the
/// layout.
@visibleForTesting
List<double> messageMarkdownTableIntrinsicColumnWidths(
  List<List<String>> rows,
  TextStyle baseStyle, {
  required Color accent,
  required Color codeBackground,
}) {
  final key = (rows, baseStyle, accent, codeBackground);
  final cached = _tableIntrinsicWidthCache.remove(key);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _tableIntrinsicWidthCache[key] = cached;
    return cached;
  }
  final columnCount = rows.isEmpty ? 0 : rows.first.length;
  final widths = List<double>.filled(columnCount, 0);
  for (final row in rows) {
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

  @override
  Widget build(BuildContext context) {
    return switch (block.type) {
      MessageMarkdownBlockType.heading => Text.rich(
        TextSpan(
          children: messageMarkdownInlineSpans(
            block.text,
            messageMarkdownHeadingStyle(baseStyle, block.level, renderStyle),
            accent: accent,
            codeBackground: codeBackground,
          ),
        ),
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
        decoration: BoxDecoration(
          color: blockBackground,
          borderRadius: BorderRadius.circular(renderStyle.quoteRadius),
          border: Border.all(color: borderColor),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: renderStyle.quotePaddingX,
            vertical: renderStyle.quotePaddingY,
          ),
          child: Text.rich(
            TextSpan(
              children: messageMarkdownInlineSpans(
                block.text,
                baseStyle,
                accent: accent,
                codeBackground: codeBackground,
              ),
            ),
          ),
        ),
      ),
      MessageMarkdownBlockType.warning => _WarningBlock(
        text: block.text,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
      ),
      MessageMarkdownBlockType.unorderedList => _MarkdownList(
        items: block.items,
        ordered: false,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        renderStyle: renderStyle,
      ),
      MessageMarkdownBlockType.orderedList => _MarkdownList(
        items: block.items,
        ordered: true,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        renderStyle: renderStyle,
      ),
      MessageMarkdownBlockType.table => _MarkdownTable(
        rows: block.rows,
        baseStyle: baseStyle,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
      ),
      MessageMarkdownBlockType.paragraph => Text.rich(
        TextSpan(
          children: messageMarkdownInlineSpans(
            block.text,
            baseStyle,
            accent: accent,
            codeBackground: codeBackground,
          ),
        ),
      ),
    };
  }
}

final class _WarningBlock extends StatelessWidget {
  const _WarningBlock({
    required this.text,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
  });

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
      decoration: BoxDecoration(
        color: Color.lerp(blockBackground, error, 0.12)!,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        border: Border.all(color: Color.lerp(borderColor, error, 0.7)!),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: error, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: messageMarkdownInlineSpans(
                    text,
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
    required this.items,
    required this.ordered,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.renderStyle,
  });

  final List<String> items;
  final bool ordered;
  final TextStyle baseStyle;
  final Color accent;
  final Color codeBackground;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < items.length; index++) ...[
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
                child: Text.rich(
                  TextSpan(
                    children: messageMarkdownInlineSpans(
                      items[index],
                      baseStyle,
                      accent: accent,
                      codeBackground: codeBackground,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (index != items.length - 1)
            SizedBox(height: renderStyle.listItemSpacing),
        ],
      ],
    );
  }
}

final class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({
    required this.rows,
    required this.baseStyle,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
  });

  final List<List<String>> rows;
  final TextStyle baseStyle;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;

  static const _cellHorizontalPadding = 10.0;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Columns narrower than an equal share keep their intrinsic content
        // width; wider columns become flex columns that take the remaining
        // space, so their text wraps instead of scrolling horizontally.
        final tableWidth = constraints.maxWidth;
        final columnWidths = <int, TableColumnWidth>{};
        if (tableWidth.isFinite) {
          final intrinsicWidths = messageMarkdownTableIntrinsicColumnWidths(
            rows,
            baseStyle,
            accent: accent,
            codeBackground: codeBackground,
          );
          final contentWidth =
              tableWidth - 2 - rows.first.length * _cellHorizontalPadding * 2;
          final equalShare = contentWidth / rows.first.length;
          for (var c = 0; c < rows.first.length; c++) {
            columnWidths[c] = intrinsicWidths[c] <= equalShare
                ? const IntrinsicColumnWidth()
                : const FlexColumnWidth();
          }
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(6),
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
                for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                  TableRow(
                    decoration: BoxDecoration(
                      color: rowIndex == 0
                          ? blockBackground
                          : Colors.transparent,
                    ),
                    children: [
                      for (final cell in rows[rowIndex])
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
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(renderStyle.codeRadius),
        border: Border.all(color: borderColor),
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
