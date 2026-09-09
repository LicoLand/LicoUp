import 'dart:collection';

import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';

/// Bounded content-addressed cache for block parses. Streaming reparses the
/// newest reply on every publish; keeping recent parses keyed by content makes
/// every other visible row a cache hit even after full projection rebuilds.
/// Parsing is a pure function of the input string, so sharing the immutable
/// result across widgets is safe.
final LinkedHashMap<String, List<MessageMarkdownBlock>> _parseCache =
    LinkedHashMap();
const int _parseCacheLimit = 256;

/// Bounded content-addressed cache for streaming parses. A streamed reply
/// republishes on every chunk; the streaming split has a different result
/// shape than the finalized parse, so it keeps its own cache instead of
/// wrapping the shared block list. Same bound and LRU discipline as
/// [_parseCache]: each distinct snapshot occupies one entry and the least
/// recently used snapshot evicts first.
final LinkedHashMap<String, _StreamingParseInternal> _streamingParseCache =
    LinkedHashMap();

/// Last streaming parse used to grow a reply by suffix only. Completed
/// blocks stay as the same instances; only the open tail is reparsed.
_StreamingParseInternal? _incrementalStreamingCursor;
String? _incrementalStreamingPrefix;

List<MessageMarkdownBlock> parseMessageMarkdownBlocks(String data) {
  final cached = _parseCache.remove(data);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _parseCache[data] = cached;
    return cached;
  }
  final parsed = _parseMessageMarkdownBlocks(data);
  if (_parseCache.length >= _parseCacheLimit) {
    _parseCache.remove(_parseCache.keys.first);
  }
  _parseCache[data] = parsed;
  return parsed;
}

/// Streaming-aware parse: splits the partially written [data] into a COMPLETE
/// block prefix (boundaries fully observed, safe for final styling) and one
/// open TAIL block that is still growing. Only the last scanned block can be
/// open, because every block scan consumes input greedily. Closure rules:
///
/// - code fence: open from the opening fence, closed when the closing fence
///   line arrives;
/// - heading: closed once its line is terminated by a newline;
/// - quote / warning / table: closed once the last consumed line is
///   terminated by a newline;
/// - list run: closed once the last item line is terminated; an open list
///   contributes its terminated items to the complete prefix and only the
///   dangling half-typed item stays in the tail;
/// - paragraph: closed at a real blank line or when a following block starts;
///   a paragraph running to the end of input (a lone trailing newline counts
///   as unterminated) stays in the tail.
MessageMarkdownStreamingParse parseStreamingMessageMarkdownBlocks(String data) {
  final cached = _streamingParseCache.remove(data);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _streamingParseCache[data] = cached;
    _rememberIncrementalStreaming(cached);
    return cached.parse;
  }
  final normalized = _normalizeMarkdownNewlines(data);
  final parsed = _parseStreamingMarkdownIncremental(normalized);
  if (_streamingParseCache.length >= _parseCacheLimit) {
    _streamingParseCache.remove(_streamingParseCache.keys.first);
  }
  _streamingParseCache[data] = parsed;
  _rememberIncrementalStreaming(parsed);
  return parsed.parse;
}

void _rememberIncrementalStreaming(_StreamingParseInternal parsed) {
  _incrementalStreamingCursor = parsed;
  _incrementalStreamingPrefix = parsed.completePrefix;
}

_StreamingParseInternal _parseStreamingMarkdownIncremental(String normalized) {
  final cursor = _incrementalStreamingCursor;
  final prefix = _incrementalStreamingPrefix;
  final prefixLength = cursor?.completeSourceLength ?? 0;
  if (cursor != null &&
      prefix != null &&
      prefixLength > 0 &&
      prefix.length == prefixLength &&
      normalized.length >= prefixLength &&
      _hasNormalizedPrefix(normalized, prefix)) {
    final remainder = normalized.substring(prefixLength);
    if (remainder.isEmpty) {
      return _StreamingParseInternal(
        parse: MessageMarkdownStreamingParse(
          complete: cursor.parse.complete,
          tail: null,
        ),
        completeSourceLength: prefixLength,
        lastCompleteStartOffset: cursor.lastCompleteStartOffset,
        completePrefix: prefix,
      );
    }
    return _mergeIncrementalStreaming(
      cursor,
      _parseStreamingMarkdownUncached(remainder),
      prefixLength,
    );
  }
  return _parseStreamingMarkdownUncached(normalized);
}

bool _hasNormalizedPrefix(String normalized, String prefix) {
  return normalized.startsWith(prefix);
}

_StreamingParseInternal _parseStreamingMarkdownUncached(String normalized) {
  final lines = _normalizedLines(normalized);
  return _streamingSplit(_parseScannedBlocks(lines), lines, normalized);
}

_StreamingParseInternal _mergeIncrementalStreaming(
  _StreamingParseInternal cursor,
  _StreamingParseInternal remainder,
  int prefixLength,
) {
  final prior = cursor.parse.complete;
  final added = remainder.parse.complete;
  final tail = remainder.parse.tail;
  if (added.isEmpty) {
    if (tail != null && prior.isNotEmpty) {
      final reopened = _coalesceContinuableMarkdown(prior.last, tail);
      if (reopened != null) {
        final complete = prior.length == 1
            ? const <MessageMarkdownBlock>[]
            : List<MessageMarkdownBlock>.unmodifiable(
                prior.sublist(0, prior.length - 1),
              );
        return _StreamingParseInternal(
          parse: MessageMarkdownStreamingParse(
            complete: complete,
            tail: reopened,
          ),
          completeSourceLength: cursor.lastCompleteStartOffset,
          lastCompleteStartOffset: complete.isEmpty
              ? 0
              : cursor.lastCompleteStartOffset,
          completePrefix: cursor.completePrefix.substring(
            0,
            cursor.lastCompleteStartOffset,
          ),
        );
      }
    }
    return _StreamingParseInternal(
      parse: MessageMarkdownStreamingParse(complete: prior, tail: tail),
      completeSourceLength: prefixLength,
      lastCompleteStartOffset: cursor.lastCompleteStartOffset,
      completePrefix: cursor.completePrefix,
    );
  }
  final combined = List<MessageMarkdownBlock>.of(prior);
  final coalesced = combined.isEmpty
      ? null
      : _coalesceContinuableMarkdown(combined.last, added.first);
  if (coalesced != null) {
    combined[combined.length - 1] = coalesced;
    combined.addAll(added.skip(1));
  } else {
    combined.addAll(added);
  }
  final completeSourceLength = prefixLength + remainder.completeSourceLength;
  final lastCompleteStartOffset = coalesced != null
      ? cursor.lastCompleteStartOffset
      : prefixLength + remainder.lastCompleteStartOffset;
  return _StreamingParseInternal(
    parse: MessageMarkdownStreamingParse(
      complete: List<MessageMarkdownBlock>.unmodifiable(combined),
      tail: tail,
    ),
    completeSourceLength: completeSourceLength,
    lastCompleteStartOffset: lastCompleteStartOffset,
    completePrefix: cursor.completePrefix + remainder.completePrefix,
  );
}

MessageMarkdownBlock? _coalesceContinuableMarkdown(
  MessageMarkdownBlock first,
  MessageMarkdownBlock second,
) {
  if (first.type != second.type) {
    return null;
  }
  return switch (first.type) {
    MessageMarkdownBlockType.unorderedList =>
      MessageMarkdownBlock.unorderedList([...first.items, ...second.items]),
    MessageMarkdownBlockType.orderedList => MessageMarkdownBlock.orderedList([
      ...first.items,
      ...second.items,
    ]),
    MessageMarkdownBlockType.table => MessageMarkdownBlock.table([
      ...first.rows,
      ...second.rows,
    ]),
    MessageMarkdownBlockType.quote => MessageMarkdownBlock.quote(
      '${first.text}\n${second.text}',
    ),
    MessageMarkdownBlockType.warning => MessageMarkdownBlock.warning(
      '${first.text}\n${second.text}',
    ),
    MessageMarkdownBlockType.paragraph ||
    MessageMarkdownBlockType.heading ||
    MessageMarkdownBlockType.code => null,
  };
}

_StreamingParseInternal _streamingSplit(
  List<_ScannedBlock> scanned,
  List<String> lines,
  String normalized,
) {
  if (scanned.isEmpty) {
    return _StreamingParseInternal(
      parse: const MessageMarkdownStreamingParse(complete: [], tail: null),
      completeSourceLength: 0,
      lastCompleteStartOffset: 0,
      completePrefix: '',
    );
  }
  final last = scanned.last;
  if (last.closed) {
    final complete = List<MessageMarkdownBlock>.unmodifiable([
      for (final entry in scanned) entry.block,
    ]);
    return _StreamingParseInternal(
      parse: MessageMarkdownStreamingParse(complete: complete, tail: null),
      completeSourceLength: normalized.length,
      lastCompleteStartOffset: _lineStartOffset(lines, last.startLine),
      completePrefix: normalized,
    );
  }
  final complete = <MessageMarkdownBlock>[
    for (var index = 0; index < scanned.length - 1; index++)
      scanned[index].block,
  ];
  var tailStartLine = last.startLine;
  final MessageMarkdownBlock tail;
  switch (last.block.type) {
    case MessageMarkdownBlockType.unorderedList:
    case MessageMarkdownBlockType.orderedList:
      final items = last.block.items;
      if (items.length > 1) {
        complete.add(
          last.block.type == MessageMarkdownBlockType.unorderedList
              ? MessageMarkdownBlock.unorderedList(
                  items.sublist(0, items.length - 1),
                )
              : MessageMarkdownBlock.orderedList(
                  items.sublist(0, items.length - 1),
                ),
        );
        tailStartLine = last.endLineExclusive - 1;
      }
      tail = MessageMarkdownBlock.paragraph(items.last);
    case MessageMarkdownBlockType.table:
      final rows = last.block.rows;
      if (rows.length > 1) {
        // Completed rows keep the table frame; the dangling row line streams
        // as plain tail text until it terminates.
        complete.add(
          MessageMarkdownBlock.table(rows.sublist(0, rows.length - 1)),
        );
        tailStartLine = last.endLineExclusive - 1;
        tail = MessageMarkdownBlock.paragraph(
          lines[last.endLineExclusive - 1].trim(),
        );
      } else {
        tail = MessageMarkdownBlock.paragraph(
          lines
              .sublist(last.startLine, last.endLineExclusive)
              .map((line) => line.trim())
              .join('\n'),
        );
      }
    case MessageMarkdownBlockType.paragraph:
    case MessageMarkdownBlockType.heading:
    case MessageMarkdownBlockType.code:
    case MessageMarkdownBlockType.quote:
    case MessageMarkdownBlockType.warning:
      tail = last.block;
  }
  final completeSourceLength = _lineStartOffset(lines, tailStartLine);
  final lastCompleteStartOffset = complete.isEmpty
      ? 0
      : _lineStartOffset(lines, _lastCompleteStartLine(scanned, last));
  return _StreamingParseInternal(
    parse: MessageMarkdownStreamingParse(
      complete: List.unmodifiable(complete),
      tail: tail,
    ),
    completeSourceLength: completeSourceLength,
    lastCompleteStartOffset: lastCompleteStartOffset,
    completePrefix: normalized.substring(0, completeSourceLength),
  );
}

int _lastCompleteStartLine(List<_ScannedBlock> scanned, _ScannedBlock last) {
  final splitListOrTable =
      (last.block.type == MessageMarkdownBlockType.unorderedList ||
          last.block.type == MessageMarkdownBlockType.orderedList ||
          last.block.type == MessageMarkdownBlockType.table) &&
      ((last.block.type == MessageMarkdownBlockType.table &&
              last.block.rows.length > 1) ||
          last.block.items.length > 1);
  if (splitListOrTable) {
    return last.startLine;
  }
  if (scanned.length < 2) {
    return 0;
  }
  return scanned[scanned.length - 2].startLine;
}

int _lineStartOffset(List<String> lines, int lineIndex) {
  if (lineIndex <= 0) {
    return 0;
  }
  if (lineIndex >= lines.length) {
    return lines.join('\n').length;
  }
  var offset = 0;
  for (var index = 0; index < lineIndex; index++) {
    offset += lines[index].length + 1;
  }
  return offset;
}

String _normalizeMarkdownNewlines(String data) {
  return data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

final class _StreamingParseInternal {
  const _StreamingParseInternal({
    required this.parse,
    required this.completeSourceLength,
    required this.lastCompleteStartOffset,
    required this.completePrefix,
  });

  final MessageMarkdownStreamingParse parse;
  final int completeSourceLength;
  final int lastCompleteStartOffset;
  final String completePrefix;
}

List<MessageMarkdownBlock> _parseMessageMarkdownBlocks(String data) {
  return List.unmodifiable([
    for (final scanned in _parseScannedBlocks(_normalizedLines(data)))
      scanned.block,
  ]);
}

List<String> _normalizedLines(String data) {
  return _normalizeMarkdownNewlines(data).split('\n');
}

List<_ScannedBlock> _parseScannedBlocks(List<String> lines) {
  final blocks = <_ScannedBlock>[];
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      index++;
      continue;
    }
    if (trimmed.startsWith('```')) {
      final start = index;
      final language = trimmed.substring(3).trim();
      index++;
      final codeLines = <String>[];
      while (index < lines.length && !lines[index].trim().startsWith('```')) {
        codeLines.add(lines[index]);
        index++;
      }
      // The block is closed only when a closing fence line was observed; an
      // unterminated fence streams its content inside the code frame.
      final closed = index < lines.length;
      if (index < lines.length) index++;
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.code(codeLines.join('\n'), language: language),
          closed: closed,
          startLine: start,
          endLineExclusive: index,
        ),
      );
      continue;
    }
    final heading = _headingMatch(trimmed);
    if (heading != null) {
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.heading(heading.text, level: heading.level),
          // A single trailing newline splits into an empty final element, so
          // a heading on the last line element has not been terminated yet.
          closed: index < lines.length - 1,
          startLine: index,
          endLineExclusive: index + 1,
        ),
      );
      index++;
      continue;
    }
    if (_isQuoteLine(trimmed)) {
      final start = index;
      final quoteLines = <String>[];
      while (index < lines.length && _isQuoteLine(lines[index].trim())) {
        quoteLines.add(lines[index].trim().replaceFirst(RegExp(r'^>\s?'), ''));
        index++;
      }
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.quote(quoteLines.join('\n')),
          closed: index - 1 < lines.length - 1,
          startLine: start,
          endLineExclusive: index,
        ),
      );
      continue;
    }
    final warning = _warningAt(lines, index);
    if (warning != null) {
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.warning(warning.text),
          closed: warning.nextIndex - 1 < lines.length - 1,
          startLine: index,
          endLineExclusive: warning.nextIndex,
        ),
      );
      index = warning.nextIndex;
      continue;
    }
    final table = _tableAt(lines, index);
    if (table != null) {
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.table(table.rows),
          closed: table.nextIndex - 1 < lines.length - 1,
          startLine: index,
          endLineExclusive: table.nextIndex,
        ),
      );
      index = table.nextIndex;
      continue;
    }
    if (_unorderedListItem(trimmed) != null) {
      final start = index;
      final items = <String>[];
      while (index < lines.length) {
        final item = _unorderedListItem(lines[index].trim());
        if (item == null) break;
        items.add(item);
        index++;
      }
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.unorderedList(items),
          closed: index - 1 < lines.length - 1,
          startLine: start,
          endLineExclusive: index,
        ),
      );
      continue;
    }
    if (_orderedListItem(trimmed) != null) {
      final start = index;
      final items = <String>[];
      while (index < lines.length) {
        final item = _orderedListItem(lines[index].trim());
        if (item == null) break;
        items.add(item);
        index++;
      }
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.orderedList(items),
          closed: index - 1 < lines.length - 1,
          startLine: start,
          endLineExclusive: index,
        ),
      );
      continue;
    }

    final start = index;
    final paragraph = <String>[];
    var closed = false;
    while (index < lines.length) {
      final currentTrimmed = lines[index].trim();
      if (currentTrimmed.isEmpty) {
        // A real blank line closes the paragraph; the empty element a lone
        // trailing newline splits into is not one.
        closed = index < lines.length - 1;
        break;
      }
      if (currentTrimmed.startsWith('```') ||
          _headingMatch(currentTrimmed) != null ||
          _isQuoteLine(currentTrimmed) ||
          _warningAt(lines, index) != null ||
          _tableAt(lines, index) != null ||
          _unorderedListItem(currentTrimmed) != null ||
          _orderedListItem(currentTrimmed) != null) {
        // The next block's first line delimits this paragraph.
        closed = true;
        break;
      }
      paragraph.add(currentTrimmed);
      index++;
    }
    blocks.add(
      _ScannedBlock(
        MessageMarkdownBlock.paragraph(paragraph.join('\n')),
        closed: closed,
        startLine: start,
        endLineExclusive: index,
      ),
    );
  }
  return blocks;
}

/// One parsed block plus the boundary bookkeeping the streaming split needs:
/// whether the block's terminating syntax was observed, and its source line
/// span (used to recover raw tail text for partially typed tables).
final class _ScannedBlock {
  const _ScannedBlock(
    this.block, {
    required this.closed,
    required this.startLine,
    required this.endLineExclusive,
  });

  final MessageMarkdownBlock block;
  final bool closed;
  final int startLine;
  final int endLineExclusive;
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
