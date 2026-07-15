import 'package:flutter/material.dart';

class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({
    super.key,
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    this.renderStyle = const MessageMarkdownStyle(),
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
      color: foreground,
      height: renderStyle.bodyLineHeight,
      fontSize: renderStyle.bodyFontSize,
      letterSpacing: 0,
    );
    final blocks = parseMessageMarkdownBlocks(data);
    if (blocks.isEmpty) {
      return Text('', style: baseStyle);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          _MarkdownBlockView(
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
}

class MessageMarkdownStyle {
  const MessageMarkdownStyle({
    this.bodyFontSize = 14,
    this.bodyLineHeight = 1.35,
    this.blockSpacing = 8,
    this.heading1FontSize = 18,
    this.heading2FontSize = 16,
    this.heading3FontSize = 15,
    this.headingLineHeight = 1.25,
    this.headingWeight = FontWeight.w900,
    this.codeFontSize = 13,
    this.codeLineHeight = 1.35,
    this.codeRadius = 6,
    this.codePadding = 10,
    this.showCodeLanguage = false,
    this.quoteRadius = 6,
    this.quotePaddingX = 10,
    this.quotePaddingY = 8,
    this.listMarkerWidth = 22,
    this.orderedListMarkerWidth = 30,
    this.listItemSpacing = 5,
    this.unorderedMarker = '-',
  });

  final double bodyFontSize;
  final double bodyLineHeight;
  final double blockSpacing;
  final double heading1FontSize;
  final double heading2FontSize;
  final double heading3FontSize;
  final double headingLineHeight;
  final FontWeight headingWeight;
  final double codeFontSize;
  final double codeLineHeight;
  final double codeRadius;
  final double codePadding;
  final bool showCodeLanguage;
  final double quoteRadius;
  final double quotePaddingX;
  final double quotePaddingY;
  final double listMarkerWidth;
  final double orderedListMarkerWidth;
  final double listItemSpacing;
  final String unorderedMarker;
}

@visibleForTesting
List<MessageMarkdownBlock> parseMessageMarkdownBlocks(String data) {
  final lines = data
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final blocks = <MessageMarkdownBlock>[];
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      index++;
      continue;
    }
    if (trimmed.startsWith('```')) {
      final language = trimmed.substring(3).trim();
      index++;
      final codeLines = <String>[];
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        codeLines.add(lines[index]);
        index++;
      }
      if (index < lines.length) {
        index++;
      }
      blocks.add(
        MessageMarkdownBlock.code(codeLines.join('\n'), language: language),
      );
      continue;
    }
    final heading = _headingMatch(trimmed);
    if (heading != null) {
      blocks.add(
        MessageMarkdownBlock.heading(heading.text, level: heading.level),
      );
      index++;
      continue;
    }
    if (_isQuoteLine(trimmed)) {
      final quoteLines = <String>[];
      while (index < lines.length && _isQuoteLine(lines[index].trim())) {
        quoteLines.add(lines[index].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        index++;
      }
      blocks.add(MessageMarkdownBlock.quote(quoteLines.join('\n')));
      continue;
    }
    final warning = _warningAt(lines, index);
    if (warning != null) {
      blocks.add(MessageMarkdownBlock.warning(warning.text));
      index = warning.nextIndex;
      continue;
    }
    final table = _tableAt(lines, index);
    if (table != null) {
      blocks.add(MessageMarkdownBlock.table(table.rows));
      index = table.nextIndex;
      continue;
    }
    if (_unorderedListItem(trimmed) != null) {
      final items = <String>[];
      while (index < lines.length) {
        final item = _unorderedListItem(lines[index].trim());
        if (item == null) {
          break;
        }
        items.add(item);
        index++;
      }
      blocks.add(MessageMarkdownBlock.unorderedList(items));
      continue;
    }
    if (_orderedListItem(trimmed) != null) {
      final items = <String>[];
      while (index < lines.length) {
        final item = _orderedListItem(lines[index].trim());
        if (item == null) {
          break;
        }
        items.add(item);
        index++;
      }
      blocks.add(MessageMarkdownBlock.orderedList(items));
      continue;
    }

    final paragraph = <String>[];
    while (index < lines.length) {
      final current = lines[index];
      final currentTrimmed = current.trim();
      if (currentTrimmed.isEmpty ||
          currentTrimmed.startsWith('```') ||
          _headingMatch(currentTrimmed) != null ||
          _isQuoteLine(currentTrimmed) ||
          _warningAt(lines, index) != null ||
          _tableAt(lines, index) != null ||
          _unorderedListItem(currentTrimmed) != null ||
          _orderedListItem(currentTrimmed) != null) {
        break;
      }
      paragraph.add(currentTrimmed);
      index++;
    }
    blocks.add(MessageMarkdownBlock.paragraph(paragraph.join('\n')));
  }
  return blocks;
}

class MessageMarkdownBlock {
  const MessageMarkdownBlock._({
    required this.type,
    required this.text,
    this.level = 0,
    this.items = const [],
    this.rows = const [],
    this.language = '',
  });

  factory MessageMarkdownBlock.paragraph(String text) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.paragraph,
      text: text,
    );
  }

  factory MessageMarkdownBlock.heading(String text, {required int level}) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.heading,
      text: text,
      level: level,
    );
  }

  factory MessageMarkdownBlock.code(String text, {String language = ''}) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.code,
      text: text,
      language: language,
    );
  }

  factory MessageMarkdownBlock.quote(String text) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.quote,
      text: text,
    );
  }

  factory MessageMarkdownBlock.warning(String text) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.warning,
      text: text,
    );
  }

  factory MessageMarkdownBlock.unorderedList(List<String> items) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.unorderedList,
      text: '',
      items: items,
    );
  }

  factory MessageMarkdownBlock.orderedList(List<String> items) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.orderedList,
      text: '',
      items: items,
    );
  }

  factory MessageMarkdownBlock.table(List<List<String>> rows) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.table,
      text: '',
      rows: rows,
    );
  }

  final MessageMarkdownBlockType type;
  final String text;
  final int level;
  final List<String> items;
  final List<List<String>> rows;
  final String language;
}

enum MessageMarkdownBlockType {
  paragraph,
  heading,
  code,
  quote,
  warning,
  unorderedList,
  orderedList,
  table,
}

class _MarkdownBlockView extends StatelessWidget {
  const _MarkdownBlockView({
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
          children: _inlineSpans(
            block.text,
            _headingStyle(baseStyle, block.level, renderStyle),
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
              children: _inlineSpans(
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
          children: _inlineSpans(
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

class _WarningBlock extends StatelessWidget {
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
    final background = Color.lerp(blockBackground, error, 0.12)!;
    final resolvedBorder = Color.lerp(borderColor, error, 0.7)!;
    final textStyle = baseStyle.copyWith(
      color: error,
      fontWeight: FontWeight.w800,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: resolvedBorder),
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
                  children: _inlineSpans(
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

class _MarkdownList extends StatelessWidget {
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
                    children: _inlineSpans(
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

class _MarkdownTable extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(color: borderColor),
              verticalInside: BorderSide(color: borderColor),
            ),
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                TableRow(
                  decoration: BoxDecoration(
                    color: rowIndex == 0 ? blockBackground : Colors.transparent,
                  ),
                  children: [
                    for (final cell in rows[rowIndex])
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: _inlineSpans(
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
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
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

List<InlineSpan> _inlineSpans(
  String text,
  TextStyle style, {
  required Color accent,
  required Color codeBackground,
}) {
  final spans = <InlineSpan>[];
  var index = 0;
  while (index < text.length) {
    if (text.startsWith('`', index)) {
      final end = text.indexOf('`', index + 1);
      if (end > index + 1) {
        spans.add(
          TextSpan(
            text: text.substring(index + 1, end),
            style: style.copyWith(
              fontFamily: 'SF Mono',
              fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
              fontSize: (style.fontSize ?? 14) - 1,
              backgroundColor: codeBackground,
            ),
          ),
        );
        index = end + 1;
        continue;
      }
    }
    if (text.startsWith('[', index)) {
      final labelEnd = text.indexOf('](', index + 1);
      if (labelEnd > index + 1) {
        final urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          spans.add(
            TextSpan(
              text: text.substring(index + 1, labelEnd),
              style: style.copyWith(
                color: accent,
                decoration: TextDecoration.underline,
                decorationColor: accent,
              ),
            ),
          );
          index = urlEnd + 1;
          continue;
        }
      }
    }
    final strong =
        _emphasisMatch(text, index, '**') ?? _emphasisMatch(text, index, '__');
    if (strong != null) {
      spans.addAll(
        _inlineSpans(
          strong.text,
          style.copyWith(fontWeight: FontWeight.w800),
          accent: accent,
          codeBackground: codeBackground,
        ),
      );
      index = strong.end;
      continue;
    }
    final emphasis =
        _emphasisMatch(text, index, '*') ?? _emphasisMatch(text, index, '_');
    if (emphasis != null) {
      spans.addAll(
        _inlineSpans(
          emphasis.text,
          style.copyWith(fontStyle: FontStyle.italic),
          accent: accent,
          codeBackground: codeBackground,
        ),
      );
      index = emphasis.end;
      continue;
    }
    final next = _nextMarkdownMarker(text, index + 1);
    spans.add(TextSpan(text: text.substring(index, next), style: style));
    index = next;
  }
  return spans;
}

TextStyle _headingStyle(
  TextStyle baseStyle,
  int level,
  MessageMarkdownStyle renderStyle,
) {
  return baseStyle.copyWith(
    fontSize: switch (level) {
      1 => renderStyle.heading1FontSize,
      2 => renderStyle.heading2FontSize,
      _ => renderStyle.heading3FontSize,
    },
    height: renderStyle.headingLineHeight,
    fontWeight: renderStyle.headingWeight,
  );
}

_HeadingMatch? _headingMatch(String line) {
  final match = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
  if (match == null) {
    return null;
  }
  return _HeadingMatch(match.group(1)!.length, match.group(2)!.trim());
}

bool _isQuoteLine(String line) => line.startsWith('>');

_WarningMatch? _warningAt(List<String> lines, int index) {
  final first = lines[index].trim();
  if (!_isRuntimeWarningLine(first)) {
    return null;
  }
  final warningLines = <String>[first];
  var nextIndex = index + 1;
  while (nextIndex < lines.length) {
    final line = lines[nextIndex].trim();
    if (line.isEmpty || !_isRuntimeWarningLine(line)) {
      break;
    }
    warningLines.add(line);
    nextIndex++;
  }
  return _WarningMatch(warningLines.join('\n'), nextIndex);
}

bool _isRuntimeWarningLine(String line) {
  final lower = line.toLowerCase();
  return line.startsWith('API Error:') ||
      lower.contains('connection closed mid-response') ||
      lower.contains('the response above may be incomplete');
}

_TableMatch? _tableAt(List<String> lines, int index) {
  if (index + 1 >= lines.length) {
    return null;
  }
  final headerLine = lines[index].trim();
  final separatorLine = lines[index + 1].trim();
  if (!_isTableRow(headerLine) || !_isTableSeparator(separatorLine)) {
    return null;
  }
  final header = _splitTableRow(headerLine);
  final separator = _splitTableRow(separatorLine);
  if (header.length < 2 || separator.length < 2) {
    return null;
  }
  final rows = <List<String>>[header];
  var nextIndex = index + 2;
  while (nextIndex < lines.length) {
    final line = lines[nextIndex].trim();
    if (line.isEmpty || !_isTableRow(line) || _isTableSeparator(line)) {
      break;
    }
    rows.add(_splitTableRow(line));
    nextIndex++;
  }
  return _TableMatch(_normalizeTableRows(rows), nextIndex);
}

bool _isTableRow(String line) {
  final trimmed = line.trim();
  return trimmed.contains('|') && _splitTableRow(trimmed).length >= 2;
}

bool _isTableSeparator(String line) {
  final cells = _splitTableRow(line);
  if (cells.length < 2) {
    return false;
  }
  return cells.every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell.trim()));
}

List<String> _splitTableRow(String line) {
  var row = line.trim();
  if (row.startsWith('|')) {
    row = row.substring(1);
  }
  if (row.endsWith('|')) {
    row = row.substring(0, row.length - 1);
  }
  final cells = <String>[];
  final buffer = StringBuffer();
  for (var index = 0; index < row.length; index++) {
    final char = row[index];
    if (char == r'\' && index + 1 < row.length && row[index + 1] == '|') {
      buffer.write('|');
      index++;
      continue;
    }
    if (char == '|') {
      cells.add(buffer.toString().trim());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  cells.add(buffer.toString().trim());
  return cells;
}

List<List<String>> _normalizeTableRows(List<List<String>> rows) {
  final columnCount = rows.fold<int>(
    0,
    (max, row) => row.length > max ? row.length : max,
  );
  return [
    for (final row in rows)
      [
        for (var index = 0; index < columnCount; index++)
          index < row.length ? row[index] : '',
      ],
  ];
}

String? _unorderedListItem(String line) {
  final match = RegExp(r'^[-*+]\s+(.+)$').firstMatch(line);
  return match?.group(1)?.trim();
}

String? _orderedListItem(String line) {
  final match = RegExp(r'^\d+[.)]\s+(.+)$').firstMatch(line);
  return match?.group(1)?.trim();
}

_EmphasisMatch? _emphasisMatch(String text, int index, String marker) {
  if (!text.startsWith(marker, index)) {
    return null;
  }
  if (marker.length == 1 &&
      index + 1 < text.length &&
      text.startsWith(marker, index + 1)) {
    return null;
  }
  final end = text.indexOf(marker, index + marker.length);
  if (end <= index + marker.length) {
    return null;
  }
  return _EmphasisMatch(
    text.substring(index + marker.length, end),
    end + marker.length,
  );
}

int _nextMarkdownMarker(String text, int start) {
  final candidates = ['`', '[', '**', '__', '*', '_']
      .map((marker) => text.indexOf(marker, start))
      .where((candidate) => candidate >= 0)
      .toList();
  if (candidates.isEmpty) {
    return text.length;
  }
  candidates.sort();
  return candidates.first;
}

class _HeadingMatch {
  const _HeadingMatch(this.level, this.text);

  final int level;
  final String text;
}

class _TableMatch {
  const _TableMatch(this.rows, this.nextIndex);

  final List<List<String>> rows;
  final int nextIndex;
}

class _WarningMatch {
  const _WarningMatch(this.text, this.nextIndex);

  final String text;
  final int nextIndex;
}

class _EmphasisMatch {
  const _EmphasisMatch(this.text, this.end);

  final String text;
  final int end;
}
