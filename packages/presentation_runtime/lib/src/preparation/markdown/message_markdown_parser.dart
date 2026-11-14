import 'dart:collection';

import 'package:presentation_contract/presentation_contract.dart';

import '../../scheduling/preparation_cancellation.dart';
import 'message_markdown_models.dart';

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
/// recently used snapshot evicts first. The cache is keyed by the full source
/// text, so interleaved replies never share state; no cross-message cursor
/// survives between calls.
final LinkedHashMap<String, MessageMarkdownStreamingParse>
_streamingParseCache = LinkedHashMap();

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
///
/// The parse is a pure function of [data]: two replies that happen to share a
/// source prefix are parsed independently, so alternating streams (for example
/// group conversations) cannot merge against each other's completed blocks.
MessageMarkdownStreamingParse parseStreamingMessageMarkdownBlocks(String data) {
  final cached = _streamingParseCache.remove(data);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _streamingParseCache[data] = cached;
    return cached;
  }
  final parsed = _parseStreamingMarkdown(_normalizeMarkdownNewlines(data));
  if (_streamingParseCache.length >= _parseCacheLimit) {
    _streamingParseCache.remove(_streamingParseCache.keys.first);
  }
  _streamingParseCache[data] = parsed;
  return parsed;
}

/// Prepares the style-free inline display of one authored text field.
///
/// This is the only inline tokenizer on the client: the runs it returns travel
/// inside the prepared block payload, so a receiver decodes a display value and
/// maps styles without reading the raw markup again. It keeps the exact visible
/// behavior of the block renderer it replaces: code spans, link labels (the
/// target is not displayed), strong and emphasis with nesting, and literal text
/// cut at every marker candidate. It adds no syntax the visible rendering did
/// not already show.
MessageMarkdownInline prepareMessageMarkdownInline(String text) {
  final runs = <MessageMarkdownInlineRun>[];
  _scanMessageMarkdownInline(text, const _InlineFlags(), runs);
  return MessageMarkdownInline(runs);
}

/// Flags accumulated while scanning one nesting level.
///
/// The scanner copies this value once per nesting level and builds one run per
/// literal piece, so a nested marker adds its flag without re-reading anything.
final class _InlineFlags {
  const _InlineFlags({
    this.code = false,
    this.strong = false,
    this.emphasis = false,
    this.link = false,
  });

  final bool code;
  final bool strong;
  final bool emphasis;
  final bool link;

  _InlineFlags withCode() =>
      _InlineFlags(code: true, strong: strong, emphasis: emphasis, link: link);

  _InlineFlags withStrong() =>
      _InlineFlags(code: code, strong: true, emphasis: emphasis, link: link);

  _InlineFlags withEmphasis() =>
      _InlineFlags(code: code, strong: strong, emphasis: true, link: link);

  _InlineFlags withLink() =>
      _InlineFlags(code: code, strong: strong, emphasis: emphasis, link: true);

  MessageMarkdownInlineRun run(String text) => MessageMarkdownInlineRun(
    text,
    isCode: code,
    isStrong: strong,
    isEmphasis: emphasis,
    isLink: link,
  );
}

void _scanMessageMarkdownInline(
  String text,
  _InlineFlags flags,
  List<MessageMarkdownInlineRun> runs,
) {
  var index = 0;
  while (index < text.length) {
    if (text.startsWith('`', index)) {
      final end = text.indexOf('`', index + 1);
      if (end > index + 1) {
        runs.add(flags.withCode().run(text.substring(index + 1, end)));
        index = end + 1;
        continue;
      }
    }
    if (text.startsWith('[', index)) {
      final labelEnd = text.indexOf('](', index + 1);
      if (labelEnd > index + 1) {
        final urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          runs.add(flags.withLink().run(text.substring(index + 1, labelEnd)));
          index = urlEnd + 1;
          continue;
        }
      }
    }
    final strong =
        _emphasisMatch(text, index, '**') ?? _emphasisMatch(text, index, '__');
    if (strong != null) {
      _scanMessageMarkdownInline(strong.text, flags.withStrong(), runs);
      index = strong.end;
      continue;
    }
    final emphasis =
        _emphasisMatch(text, index, '*') ?? _emphasisMatch(text, index, '_');
    if (emphasis != null) {
      _scanMessageMarkdownInline(emphasis.text, flags.withEmphasis(), runs);
      index = emphasis.end;
      continue;
    }
    final next = _nextMarkdownMarker(text, index + 1);
    runs.add(flags.run(text.substring(index, next)));
    index = next;
  }
}

_EmphasisMatch? _emphasisMatch(String text, int index, String marker) {
  if (!text.startsWith(marker, index)) return null;
  if (marker.length == 1 &&
      index + 1 < text.length &&
      text.startsWith(marker, index + 1)) {
    return null;
  }
  final end = text.indexOf(marker, index + marker.length);
  if (end <= index + marker.length) return null;
  return _EmphasisMatch(
    text.substring(index + marker.length, end),
    end + marker.length,
  );
}

int _nextMarkdownMarker(String text, int start) {
  final candidates =
      <String>['`', '[', '**', '__', '*', '_']
          .map((marker) => text.indexOf(marker, start))
          .where((candidate) => candidate >= 0)
          .toList(growable: false)
        ..sort();
  return candidates.isEmpty ? text.length : candidates.first;
}

final class _EmphasisMatch {
  const _EmphasisMatch(this.text, this.end);

  final String text;
  final int end;
}

/// One block of a message revision plus the source span it was scanned from.
final class MessageMarkdownBlockSpan {
  const MessageMarkdownBlockSpan({
    required this.block,
    required this.range,
    required this.isSealed,
  });

  final MessageMarkdownBlock block;

  /// Half-open offset range of this block inside the original message text.
  final SourceTextRange range;

  /// True when this block's boundary is settled for this revision.
  ///
  /// A code fence without its closing line, a paragraph running to the end of
  /// the text, and a table that a following row line could still extend are all
  /// unsealed: their prepared output is not final yet.
  final bool isSealed;

  @override
  String toString() =>
      'MessageMarkdownBlockSpan(${block.type.name}, $range, '
      'sealed: $isSealed)';
}

/// Scans one message revision into block spans with offsets into [data].
///
/// The scan rules are the same ones [_parseScannedBlocks] applies to the whole
/// text, so a span can be parsed on its own and still agree with the full
/// document parse.
List<MessageMarkdownBlockSpan> scanMessageMarkdownBlockSpans(String data) {
  final lines = _rawLines(data);
  // The scan only describes block boundaries: preparing inline runs here would
  // tokenize every block of every streaming revision for a payload that never
  // leaves this function.
  final scanned = _parseScannedBlocks(<String>[
    for (final line in lines) line.text,
  ], prepareContent: false);
  final spans = <MessageMarkdownBlockSpan>[];
  for (final entry in scanned) {
    final start = lines[entry.startLine].start;
    final end = entry.endLineExclusive < lines.length
        ? lines[entry.endLineExclusive].start
        : data.length;
    spans.add(
      MessageMarkdownBlockSpan(
        block: entry.block,
        range: SourceTextRange(start: start, end: end),
        isSealed: entry.closed && _isSealedBoundary(entry, lines),
      ),
    );
  }
  return List<MessageMarkdownBlockSpan>.unmodifiable(spans);
}

/// Parses exactly one block region.
///
/// A region that does not scan to exactly one block is an input error the
/// caller must hear about, not a silently wrong prepared block.
MessageMarkdownBlock parseMessageMarkdownBlockRegion(String region) {
  final blocks = parseMessageMarkdownBlocks(region);
  if (blocks.length != 1) {
    throw PreparationWorkerException(
      code: 'markdown.region_not_single_block',
      detail: 'region scanned to ${blocks.length} blocks',
    );
  }
  return blocks.first;
}

/// Line content and start offset, so a parse result can be mapped back to the
/// offsets of the original text even when it uses CR or CRLF terminators.
final class _RawLine {
  const _RawLine(this.start, this.text);

  final int start;
  final String text;
}

List<_RawLine> _rawLines(String data) {
  final lines = <_RawLine>[];
  final buffer = StringBuffer();
  var start = 0;
  var index = 0;
  while (index < data.length) {
    final unit = data.codeUnitAt(index);
    if (unit == 0x0A) {
      lines.add(_RawLine(start, buffer.toString()));
      buffer.clear();
      index++;
      start = index;
      continue;
    }
    if (unit == 0x0D) {
      lines.add(_RawLine(start, buffer.toString()));
      buffer.clear();
      index++;
      if (index < data.length && data.codeUnitAt(index) == 0x0A) index++;
      start = index;
      continue;
    }
    buffer.writeCharCode(unit);
    index++;
  }
  lines.add(_RawLine(start, buffer.toString()));
  return lines;
}

/// A table stays open while a following line could still be one of its rows.
bool _isSealedBoundary(_ScannedBlock entry, List<_RawLine> lines) {
  if (entry.block.type != MessageMarkdownBlockType.table) return true;
  final next = entry.endLineExclusive;
  if (next >= lines.length) return false;
  final line = lines[next].text;
  if (line.trim().isEmpty) {
    // The empty element a trailing newline splits into is not a real blank
    // line, so the table is still the last thing the source has said.
    return next + 1 < lines.length;
  }
  return !_isTableRow(line) && !_isTableSeparator(line);
}

MessageMarkdownStreamingParse _parseStreamingMarkdown(String normalized) {
  return _streamingSplit(_parseScannedBlocks(normalized.split('\n')));
}

/// Splits a parse into the settled prefix and the still-growing remainder.
///
/// The within-block split is the one the scan already prepared on each list or
/// table block: a settled block contributes its whole value, a growing list or
/// table contributes its settled part plus the prepared remainder, and every
/// other growing block is its own remainder.
MessageMarkdownStreamingParse _streamingSplit(List<_ScannedBlock> scanned) {
  if (scanned.isEmpty) {
    return const MessageMarkdownStreamingParse(complete: [], tail: null);
  }
  final last = scanned.last;
  final streaming = last.block.streaming;
  final settled = last.closed && (streaming == null || streaming.tail == null);
  if (settled) {
    return MessageMarkdownStreamingParse(
      complete: List<MessageMarkdownBlock>.unmodifiable([
        for (final entry in scanned) entry.block,
      ]),
      tail: null,
    );
  }
  final settledPart = last.block.settledStreamingPart;
  return MessageMarkdownStreamingParse(
    complete: List<MessageMarkdownBlock>.unmodifiable([
      for (var index = 0; index < scanned.length - 1; index++)
        scanned[index].block,
      if (settledPart != null) settledPart,
    ]),
    tail: streaming?.tail ?? last.block,
  );
}

String _normalizeMarkdownNewlines(String data) {
  return data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
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

List<_ScannedBlock> _parseScannedBlocks(
  List<String> lines, {
  bool prepareContent = true,
}) {
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
          MessageMarkdownBlock.heading(
            heading.text,
            level: heading.level,
            inline: _preparedInline(heading.text, prepareContent),
          ),
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
      final quoteText = quoteLines.join('\n');
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.quote(
            quoteText,
            inline: _preparedInline(quoteText, prepareContent),
          ),
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
          MessageMarkdownBlock.warning(
            warning.text,
            inline: _preparedInline(warning.text, prepareContent),
          ),
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
      final closed = table.nextIndex - 1 < lines.length - 1;
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.table(
            table.rows,
            cellInline: _preparedCellInline(table.rows, prepareContent),
            streaming: prepareContent
                ? _tableStreaming(
                    rows: table.rows,
                    lines: lines,
                    startLine: index,
                    nextIndex: table.nextIndex,
                    closed: closed,
                  )
                : null,
          ),
          closed: closed,
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
      final closed = index - 1 < lines.length - 1;
      final itemInline = _preparedItemInline(items, prepareContent);
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.unorderedList(
            items,
            itemInline: itemInline,
            streaming: prepareContent
                ? _listStreaming(items, itemInline, closed: closed)
                : null,
          ),
          closed: closed,
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
      final closed = index - 1 < lines.length - 1;
      final itemInline = _preparedItemInline(items, prepareContent);
      blocks.add(
        _ScannedBlock(
          MessageMarkdownBlock.orderedList(
            items,
            itemInline: itemInline,
            streaming: prepareContent
                ? _listStreaming(items, itemInline, closed: closed)
                : null,
          ),
          closed: closed,
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
    final paragraphText = paragraph.join('\n');
    blocks.add(
      _ScannedBlock(
        MessageMarkdownBlock.paragraph(
          paragraphText,
          inline: _preparedInline(paragraphText, prepareContent),
        ),
        closed: closed,
        startLine: start,
        endLineExclusive: index,
      ),
    );
  }
  return blocks;
}

/// Prepared inline display of one authored field, when this scan prepares it.
MessageMarkdownInline? _preparedInline(String text, bool prepareContent) =>
    prepareContent ? prepareMessageMarkdownInline(text) : null;

List<MessageMarkdownInline>? _preparedItemInline(
  List<String> items,
  bool prepareContent,
) => prepareContent
    ? <MessageMarkdownInline>[
        for (final item in items) prepareMessageMarkdownInline(item),
      ]
    : null;

List<List<MessageMarkdownInline>>? _preparedCellInline(
  List<List<String>> rows,
  bool prepareContent,
) => prepareContent
    ? <List<MessageMarkdownInline>>[
        for (final row in rows)
          <MessageMarkdownInline>[
            for (final cell in row) prepareMessageMarkdownInline(cell),
          ],
      ]
    : null;

/// Prepared streaming split of one list block.
///
/// A terminated run settles every item; an unterminated last item stays the
/// growing remainder, prepared from its own authored text so a renderer never
/// falls back to the raw source.
MessageMarkdownBlockStreaming? _listStreaming(
  List<String> items,
  List<MessageMarkdownInline>? itemInline, {
  required bool closed,
}) {
  if (items.isEmpty) return null;
  if (closed) {
    return MessageMarkdownBlockStreaming(
      settledCount: items.length,
      tail: null,
    );
  }
  return MessageMarkdownBlockStreaming(
    settledCount: items.length - 1,
    tail: MessageMarkdownBlock.paragraph(
      items.last,
      inline: itemInline == null ? null : itemInline.last,
    ),
  );
}

/// Prepared streaming split of one table block.
///
/// Completed rows keep the table frame; an unterminated row line streams as the
/// prepared calm remainder, exactly as the visible rendering showed it before
/// the split moved into the worker.
MessageMarkdownBlockStreaming _tableStreaming({
  required List<List<String>> rows,
  required List<String> lines,
  required int startLine,
  required int nextIndex,
  required bool closed,
}) {
  if (closed) {
    return MessageMarkdownBlockStreaming(settledCount: rows.length, tail: null);
  }
  final String remainder;
  if (rows.length > 1) {
    remainder = lines[nextIndex - 1].trim();
  } else {
    remainder = lines
        .sublist(startLine, nextIndex)
        .map((line) => line.trim())
        .join('\n');
  }
  return MessageMarkdownBlockStreaming(
    settledCount: rows.length - 1,
    tail: MessageMarkdownBlock.paragraph(
      remainder,
      inline: prepareMessageMarkdownInline(remainder),
    ),
  );
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
