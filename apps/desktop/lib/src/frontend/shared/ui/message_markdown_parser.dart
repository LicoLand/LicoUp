import 'package:flutter_client/src/frontend/shared/ui/message_markdown_models.dart';

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
      if (index < lines.length) index++;
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
        if (item == null) break;
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
        if (item == null) break;
        items.add(item);
        index++;
      }
      blocks.add(MessageMarkdownBlock.orderedList(items));
      continue;
    }

    final paragraph = <String>[];
    while (index < lines.length) {
      final currentTrimmed = lines[index].trim();
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
  return List.unmodifiable(blocks);
}

_HeadingMatch? _headingMatch(String line) {
  final match = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
  if (match == null) return null;
  return _HeadingMatch(match.group(1)!.length, match.group(2)!.trim());
}

bool _isQuoteLine(String line) => line.startsWith('>');

_WarningMatch? _warningAt(List<String> lines, int index) {
  final first = lines[index].trim();
  if (!_isRuntimeWarningLine(first)) return null;
  final warningLines = <String>[first];
  var nextIndex = index + 1;
  while (nextIndex < lines.length) {
    final line = lines[nextIndex].trim();
    if (line.isEmpty || !_isRuntimeWarningLine(line)) break;
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
  if (index + 1 >= lines.length) return null;
  final headerLine = lines[index].trim();
  final separatorLine = lines[index + 1].trim();
  if (!_isTableRow(headerLine) || !_isTableSeparator(separatorLine)) {
    return null;
  }
  final header = _splitTableRow(headerLine);
  final separator = _splitTableRow(separatorLine);
  if (header.length < 2 || separator.length < 2) return null;
  final rows = <List<String>>[header];
  var nextIndex = index + 2;
  while (nextIndex < lines.length) {
    final line = lines[nextIndex].trim();
    if (line.isEmpty || !_isTableRow(line) || _isTableSeparator(line)) break;
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
  return cells.length >= 2 &&
      cells.every((cell) => RegExp(r'^:?-{3,}:?$').hasMatch(cell.trim()));
}

List<String> _splitTableRow(String line) {
  var row = line.trim();
  if (row.startsWith('|')) row = row.substring(1);
  if (row.endsWith('|')) row = row.substring(0, row.length - 1);
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
  return RegExp(r'^[-*+]\s+(.+)$').firstMatch(line)?.group(1)?.trim();
}

String? _orderedListItem(String line) {
  return RegExp(r'^\d+[.)]\s+(.+)$').firstMatch(line)?.group(1)?.trim();
}

final class _HeadingMatch {
  const _HeadingMatch(this.level, this.text);

  final int level;
  final String text;
}

final class _TableMatch {
  const _TableMatch(this.rows, this.nextIndex);

  final List<List<String>> rows;
  final int nextIndex;
}

final class _WarningMatch {
  const _WarningMatch(this.text, this.nextIndex);

  final String text;
  final int nextIndex;
}
