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

/// One style-free display run of a prepared inline text field.
///
/// A run carries the exact characters a renderer displays and the semantic
/// flags it maps to its own styles. No font, colour, weight value, or theme
/// identity appears here: a restyle maps these flags again without re-reading
/// the raw Markdown, and a restyle cannot invalidate a prepared value.
///
/// Flags nest the way the source markup nests, so a code span inside strong
/// text carries both [isCode] and [isStrong].
final class MessageMarkdownInlineRun {
  const MessageMarkdownInlineRun(
    this.text, {
    this.isCode = false,
    this.isStrong = false,
    this.isEmphasis = false,
    this.isLink = false,
  });

  /// The characters of this run, in display form.
  ///
  /// A link run holds its label without the target, exactly as the visible
  /// Markdown rendering shows it.
  final String text;

  final bool isCode;
  final bool isStrong;
  final bool isEmphasis;
  final bool isLink;

  bool get isPlain => !isCode && !isStrong && !isEmphasis && !isLink;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageMarkdownInlineRun &&
          other.text == text &&
          other.isCode == isCode &&
          other.isStrong == isStrong &&
          other.isEmphasis == isEmphasis &&
          other.isLink == isLink;

  @override
  int get hashCode => Object.hash(text, isCode, isStrong, isEmphasis, isLink);

  @override
  String toString() {
    final flags = <String>[
      if (isCode) 'code',
      if (isStrong) 'strong',
      if (isEmphasis) 'emphasis',
      if (isLink) 'link',
    ];
    return 'MessageMarkdownInlineRun(${flags.isEmpty ? 'plain' : flags.join('+')}: '
        '${text.length} code units)';
  }
}

/// Immutable, style-free prepared display of one authored Markdown text field.
///
/// The runs are the complete display value: concatenating them yields the text
/// a renderer must show, so no consumer normalizes, tokenizes, or scans the
/// source text again. [runs] is a plain value list; sharing it across widgets
/// and isolates is safe.
final class MessageMarkdownInline {
  MessageMarkdownInline(Iterable<MessageMarkdownInlineRun> runs)
    : runs = List<MessageMarkdownInlineRun>.unmodifiable(runs);

  /// The plain display of [text], for a field the preparation has not covered.
  ///
  /// This constructor interprets no markup: the text is shown literally. It is
  /// the renderer's non-parsing fallback, never a parsing route. Empty text has
  /// no runs, which is also what the tokenizer produces for it.
  factory MessageMarkdownInline.plain(String text) => MessageMarkdownInline(
    text.isEmpty
        ? const <MessageMarkdownInlineRun>[]
        : <MessageMarkdownInlineRun>[MessageMarkdownInlineRun(text)],
  );

  final List<MessageMarkdownInlineRun> runs;

  /// True when no run carries a semantic flag.
  bool get isPlainText => runs.every((run) => run.isPlain);

  /// The exact text a renderer displays: the run texts in order.
  ///
  /// A single-run value returns that run's own string, so a plain field does
  /// not occupy a second copy of its text.
  late final String displayText = switch (runs.length) {
    0 => '',
    1 => runs.first.text,
    _ => _joinRuns(runs),
  };

  /// Cumulative display offsets of [runs], for range lookup.
  late final List<int> _runStarts = _startsOf(runs);

  /// True when this display adds nothing to [sourceText].
  ///
  /// A field with no markup tokenizes to one plain run equal to its own text,
  /// so its prepared value carries no information beyond the text the block
  /// already ships: the codec drops the runs and the decoder restores the
  /// plain value. A field with any markup has a display that differs from its
  /// source or a flagged run, so its runs always travel.
  bool _sharesDisplayOf(String sourceText) =>
      displayText == sourceText && runs.length <= 1 && isPlainText;

  /// The runs covering display range `[start, end)`, with run text clipped.
  ///
  /// This is the layout helper for bounded slices: a renderer cuts
  /// [displayText] into pieces and maps the runs of each piece. Offsets are
  /// UTF-16 code units into [displayText]; the returned runs preserve their
  /// semantic flags and hold exactly the characters of the range.
  List<MessageMarkdownInlineRun> slice(int start, int end) {
    if (start < 0 || end < start || end > displayText.length) {
      throw RangeError.range(
        end,
        start,
        displayText.length,
        'end',
        'must cover a range of displayText',
      );
    }
    if (runs.isEmpty || start == end) {
      return const <MessageMarkdownInlineRun>[];
    }
    final sliced = <MessageMarkdownInlineRun>[];
    var index = _runIndexAt(_runStarts, start);
    while (index < runs.length && _runStarts[index] < end) {
      final run = runs[index];
      final runStart = _runStarts[index];
      final runEnd = runStart + run.text.length;
      final from = start > runStart ? start - runStart : 0;
      final to = end < runEnd ? end - runStart : run.text.length;
      if (to > from) {
        final text = (from == 0 && to == run.text.length)
            ? run.text
            : run.text.substring(from, to);
        sliced.add(
          MessageMarkdownInlineRun(
            text,
            isCode: run.isCode,
            isStrong: run.isStrong,
            isEmphasis: run.isEmphasis,
            isLink: run.isLink,
          ),
        );
      }
      index++;
    }
    return List<MessageMarkdownInlineRun>.unmodifiable(sliced);
  }

  /// Content identity of this display, comparable across independent parses.
  int get contentHash => Object.hashAll(runs);

  @override
  String toString() =>
      'MessageMarkdownInline(${runs.length} runs, '
      '${displayText.length} code units${isPlainText ? ', plain' : ''})';
}

String _joinRuns(List<MessageMarkdownInlineRun> runs) {
  final buffer = StringBuffer();
  for (final run in runs) {
    buffer.write(run.text);
  }
  return buffer.toString();
}

List<int> _startsOf(List<MessageMarkdownInlineRun> runs) {
  final starts = List<int>.filled(runs.length, 0);
  var offset = 0;
  for (var index = 0; index < runs.length; index++) {
    starts[index] = offset;
    offset += runs[index].text.length;
  }
  return starts;
}

/// Index of the run whose display range contains [offset].
///
/// [starts] is strictly increasing because the tokenizer never emits an empty
/// run; the search returns the last start not after [offset].
int _runIndexAt(List<int> starts, int offset) {
  var low = 0;
  var high = starts.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (starts[mid] <= offset) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

// Wire flags of one prepared inline run. Only primitives cross the worker
// boundary, so the flags travel as one integer bit set.
const int _inlineFlagCode = 1;
const int _inlineFlagStrong = 2;
const int _inlineFlagEmphasis = 4;
const int _inlineFlagLink = 8;

/// Compact wire form of one prepared inline value, or null when the display
/// adds nothing to [sourceText].
///
/// Only primitives cross the worker boundary. A field whose prepared display
/// equals its own source text travels as null: the block already carries the
/// text, and the decoder restores the plain value without tokenizing.
List<Object?>? encodeMessageMarkdownInline(
  MessageMarkdownInline? inline,
  String sourceText,
) {
  if (inline == null || inline._sharesDisplayOf(sourceText)) return null;
  return <Object?>[
    for (final run in inline.runs)
      <Object?>[
        run.text,
        (run.isCode ? _inlineFlagCode : 0) |
            (run.isStrong ? _inlineFlagStrong : 0) |
            (run.isEmphasis ? _inlineFlagEmphasis : 0) |
            (run.isLink ? _inlineFlagLink : 0),
      ],
  ];
}

/// Rebuilds one prepared inline value from its encoded form.
///
/// A null payload means the prepared display is [sourceText] itself, so the
/// receiving isolate constructs the plain value without parsing anything.
MessageMarkdownInline decodeMessageMarkdownInline(
  Object? payload,
  String sourceText,
) {
  if (payload == null) return MessageMarkdownInline.plain(sourceText);
  final runs = <MessageMarkdownInlineRun>[];
  for (final entry in payload as List<Object?>) {
    final parts = entry! as List<Object?>;
    final flags = parts[1]! as int;
    runs.add(
      MessageMarkdownInlineRun(
        parts[0]! as String,
        isCode: flags & _inlineFlagCode != 0,
        isStrong: flags & _inlineFlagStrong != 0,
        isEmphasis: flags & _inlineFlagEmphasis != 0,
        isLink: flags & _inlineFlagLink != 0,
      ),
    );
  }
  return MessageMarkdownInline(runs);
}

/// Prepared streaming view of one partially settled list or table block.
///
/// A list or table that is still growing has a settled leading part and one
/// growing remainder. The worker prepares both: [settledCount] names the
/// leading items (list) or rows (table) whose boundary was observed, and [tail]
/// is the remainder as its own prepared block, rendered calmly. A consumer
/// renders the settled part from the block's own prepared items/rows and never
/// re-reads the source; a settled block carries a split whose [tail] is null.
final class MessageMarkdownBlockStreaming {
  const MessageMarkdownBlockStreaming({
    required this.settledCount,
    required this.tail,
  });

  /// How many leading items (list) or rows (table) are settled.
  final int settledCount;

  /// The still-growing remainder, prepared as its own block, or null when the
  /// settled part covers the whole block.
  final MessageMarkdownBlock? tail;

  /// Content identity comparable across independent parses.
  int get contentHash => Object.hash(settledCount, tail?.contentHash ?? 0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageMarkdownBlockStreaming &&
          other.settledCount == settledCount &&
          other.tail == tail;

  @override
  int get hashCode => Object.hash(settledCount, tail);

  @override
  String toString() =>
      'MessageMarkdownBlockStreaming(settled: $settledCount, '
      'tail: ${tail?.type.name ?? 'none'})';
}

final class MessageMarkdownBlock {
  const MessageMarkdownBlock._({
    required this.type,
    required this.text,
    this.level = 0,
    this.items = const [],
    this.rows = const [],
    this.language = '',
    this.inline,
    this.itemInline = const [],
    this.cellInline = const [],
    this.streaming,
  });

  factory MessageMarkdownBlock.paragraph(
    String text, {
    MessageMarkdownInline? inline,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.paragraph,
      text: text,
      inline: inline,
    );
  }

  factory MessageMarkdownBlock.heading(
    String text, {
    required int level,
    MessageMarkdownInline? inline,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.heading,
      text: text,
      level: level,
      inline: inline,
    );
  }

  factory MessageMarkdownBlock.code(String text, {String language = ''}) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.code,
      text: text,
      language: language,
    );
  }

  factory MessageMarkdownBlock.quote(
    String text, {
    MessageMarkdownInline? inline,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.quote,
      text: text,
      inline: inline,
    );
  }

  factory MessageMarkdownBlock.warning(
    String text, {
    MessageMarkdownInline? inline,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.warning,
      text: text,
      inline: inline,
    );
  }

  factory MessageMarkdownBlock.unorderedList(
    List<String> items, {
    List<MessageMarkdownInline>? itemInline,
    MessageMarkdownBlockStreaming? streaming,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.unorderedList,
      text: '',
      items: List<String>.unmodifiable(items),
      itemInline: _checkedItemInline(items, itemInline),
      streaming: _checkedStreaming(items.length, streaming),
    );
  }

  factory MessageMarkdownBlock.orderedList(
    List<String> items, {
    List<MessageMarkdownInline>? itemInline,
    MessageMarkdownBlockStreaming? streaming,
  }) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.orderedList,
      text: '',
      items: List<String>.unmodifiable(items),
      itemInline: _checkedItemInline(items, itemInline),
      streaming: _checkedStreaming(items.length, streaming),
    );
  }

  factory MessageMarkdownBlock.table(
    List<List<String>> rows, {
    List<List<MessageMarkdownInline>>? cellInline,
    MessageMarkdownBlockStreaming? streaming,
  }) {
    final frozen = List<List<String>>.unmodifiable(
      rows.map(List<String>.unmodifiable),
    );
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.table,
      text: '',
      rows: frozen,
      cellInline: _checkedCellInline(frozen, cellInline),
      streaming: _checkedStreaming(frozen.length, streaming),
    );
  }

  final MessageMarkdownBlockType type;

  /// The authored text of this block, with inline markup preserved.
  ///
  /// This is the source content, not the display form: [inline] carries the
  /// prepared display runs. Code blocks keep their raw text here and never
  /// have prepared inline runs.
  final String text;
  final int level;
  final List<String> items;
  final List<List<String>> rows;
  final String language;

  /// Prepared inline display of [text], when the preparation covered it.
  final MessageMarkdownInline? inline;

  /// Prepared inline display of every entry of [items], in the same order.
  final List<MessageMarkdownInline> itemInline;

  /// Prepared inline display of every cell of [rows], in the same shape.
  final List<List<MessageMarkdownInline>> cellInline;

  /// Prepared streaming split of a list or table block, when the worker could
  /// partially settle it. Null for every other block type.
  final MessageMarkdownBlockStreaming? streaming;

  /// The settled leading part of this still-growing block, as its own value.
  ///
  /// Null when nothing is settled yet, or when the whole block is settled (the
  /// block itself is then the settled value and a renderer shows it final). A
  /// renderer that iterates the prepared items/rows directly can use
  /// [streaming] instead of materializing this value.
  MessageMarkdownBlock? get settledStreamingPart {
    final split = streaming;
    if (split == null || split.settledCount <= 0 || split.tail == null) {
      return null;
    }
    switch (type) {
      case MessageMarkdownBlockType.unorderedList:
        return MessageMarkdownBlock.unorderedList(
          items.sublist(0, split.settledCount),
          itemInline: itemInline.isEmpty
              ? null
              : itemInline.sublist(0, split.settledCount),
        );
      case MessageMarkdownBlockType.orderedList:
        return MessageMarkdownBlock.orderedList(
          items.sublist(0, split.settledCount),
          itemInline: itemInline.isEmpty
              ? null
              : itemInline.sublist(0, split.settledCount),
        );
      case MessageMarkdownBlockType.table:
        return MessageMarkdownBlock.table(
          rows.sublist(0, split.settledCount),
          cellInline: cellInline.isEmpty
              ? null
              : cellInline.sublist(0, split.settledCount),
        );
      case MessageMarkdownBlockType.paragraph:
      case MessageMarkdownBlockType.heading:
      case MessageMarkdownBlockType.code:
      case MessageMarkdownBlockType.quote:
      case MessageMarkdownBlockType.warning:
        return null;
    }
  }

  /// Content fingerprint for keyed streaming layouts: two blocks with the same
  /// fingerprint render identically, so a keyed widget can be reused without
  /// re-layout while the surrounding stream grows.
  int get contentHash => Object.hash(
    type,
    text,
    level,
    language,
    Object.hashAll(items),
    Object.hashAll(rows.map(Object.hashAll)),
    inline?.contentHash ?? 0,
    Object.hashAll(itemInline.map((value) => value.contentHash)),
    Object.hashAll(
      cellInline.map(
        (row) => Object.hashAll(row.map((cell) => cell.contentHash)),
      ),
    ),
    streaming?.contentHash ?? 0,
  );
}

/// Validates that a streaming split stays inside the authored shape.
MessageMarkdownBlockStreaming? _checkedStreaming(
  int entryCount,
  MessageMarkdownBlockStreaming? streaming,
) {
  if (streaming == null) return null;
  if (streaming.settledCount < 0 || streaming.settledCount > entryCount) {
    throw ArgumentError.value(
      streaming.settledCount,
      'streaming',
      'settledCount must cover a prefix of $entryCount entries',
    );
  }
  return streaming;
}

/// Validates that prepared item runs are parallel to the authored items.
List<MessageMarkdownInline> _checkedItemInline(
  List<String> items,
  List<MessageMarkdownInline>? itemInline,
) {
  if (itemInline == null) return const <MessageMarkdownInline>[];
  if (itemInline.length != items.length) {
    throw ArgumentError.value(
      itemInline,
      'itemInline',
      'must hold exactly one prepared value per item',
    );
  }
  return List<MessageMarkdownInline>.unmodifiable(itemInline);
}

/// Validates that prepared cell runs match the authored table shape.
List<List<MessageMarkdownInline>> _checkedCellInline(
  List<List<String>> rows,
  List<List<MessageMarkdownInline>>? cellInline,
) {
  if (cellInline == null) return const <List<MessageMarkdownInline>>[];
  if (cellInline.length != rows.length) {
    throw ArgumentError.value(
      cellInline,
      'cellInline',
      'must hold exactly one prepared row per authored row',
    );
  }
  for (var row = 0; row < rows.length; row++) {
    if (cellInline[row].length != rows[row].length) {
      throw ArgumentError.value(
        cellInline[row],
        'cellInline',
        'row $row must hold exactly one prepared value per cell',
      );
    }
  }
  return List<List<MessageMarkdownInline>>.unmodifiable(
    cellInline.map(List<MessageMarkdownInline>.unmodifiable),
  );
}

/// Streaming-aware parse of a partially written message: [complete] holds the
/// blocks whose Markdown boundary has been observed (safe to render with final
/// styling), and [tail] holds the still-growing trailing block, or null when
/// the input ends on a clean block boundary.
final class MessageMarkdownStreamingParse {
  const MessageMarkdownStreamingParse({
    required this.complete,
    required this.tail,
  });

  final List<MessageMarkdownBlock> complete;
  final MessageMarkdownBlock? tail;
}

/// Compact wire form of one prepared block.
///
/// Only primitives cross the worker boundary, so a prepared block travels as a
/// short list instead of a structured object graph. The receiving side rebuilds
/// the value with the ordinary constructors: no normalization, line splitting,
/// or tokenizing happens outside the worker. Prepared inline runs travel in
/// their own compact form; a plain field whose display equals its text is
/// omitted, because the text travels with the block anyway.
List<Object?> encodeMessageMarkdownBlock(MessageMarkdownBlock block) {
  return <Object?>[
    block.type.index,
    block.text,
    block.level,
    block.language,
    block.items,
    block.rows,
    encodeMessageMarkdownInline(block.inline, block.text),
    <Object?>[
      for (var index = 0; index < block.items.length; index++)
        encodeMessageMarkdownInline(
          _itemInlineAt(block, index),
          block.items[index],
        ),
    ],
    <Object?>[
      for (var row = 0; row < block.rows.length; row++)
        <Object?>[
          for (var column = 0; column < block.rows[row].length; column++)
            encodeMessageMarkdownInline(
              _cellInlineAt(block, row, column),
              block.rows[row][column],
            ),
        ],
    ],
    block.streaming == null
        ? null
        : <Object?>[
            block.streaming!.settledCount,
            block.streaming!.tail == null
                ? null
                : encodeMessageMarkdownBlock(block.streaming!.tail!),
          ],
  ];
}

/// Rebuilds one prepared block from its [encodeMessageMarkdownBlock] form.
MessageMarkdownBlock decodeMessageMarkdownBlock(Object? payload) {
  final parts = payload! as List<Object?>;
  final type = MessageMarkdownBlockType.values[parts[0]! as int];
  final text = parts[1]! as String;
  final level = parts[2]! as int;
  final language = parts[3]! as String;
  final items = (parts[4]! as List<Object?>).cast<String>();
  final rows = (parts[5]! as List<Object?>)
      .map((row) => (row! as List<Object?>).cast<String>())
      .toList(growable: false);
  final inline = decodeMessageMarkdownInline(parts[6], text);
  final itemInline = <MessageMarkdownInline>[
    for (var index = 0; index < items.length; index++)
      decodeMessageMarkdownInline(
        (parts[7]! as List<Object?>)[index],
        items[index],
      ),
  ];
  final cellInline = <List<MessageMarkdownInline>>[
    for (var row = 0; row < rows.length; row++)
      <MessageMarkdownInline>[
        for (var column = 0; column < rows[row].length; column++)
          decodeMessageMarkdownInline(
            ((parts[8]! as List<Object?>)[row]! as List<Object?>)[column],
            rows[row][column],
          ),
      ],
  ];
  final streamingPayload = parts.length > 9 ? parts[9] : null;
  final streaming = streamingPayload == null
      ? null
      : MessageMarkdownBlockStreaming(
          settledCount: (streamingPayload as List<Object?>)[0]! as int,
          tail: streamingPayload[1] == null
              ? null
              : decodeMessageMarkdownBlock(streamingPayload[1]),
        );
  switch (type) {
    case MessageMarkdownBlockType.paragraph:
      return MessageMarkdownBlock.paragraph(text, inline: inline);
    case MessageMarkdownBlockType.heading:
      return MessageMarkdownBlock.heading(text, level: level, inline: inline);
    case MessageMarkdownBlockType.code:
      return MessageMarkdownBlock.code(text, language: language);
    case MessageMarkdownBlockType.quote:
      return MessageMarkdownBlock.quote(text, inline: inline);
    case MessageMarkdownBlockType.warning:
      return MessageMarkdownBlock.warning(text, inline: inline);
    case MessageMarkdownBlockType.unorderedList:
      return MessageMarkdownBlock.unorderedList(
        items,
        itemInline: itemInline,
        streaming: streaming,
      );
    case MessageMarkdownBlockType.orderedList:
      return MessageMarkdownBlock.orderedList(
        items,
        itemInline: itemInline,
        streaming: streaming,
      );
    case MessageMarkdownBlockType.table:
      return MessageMarkdownBlock.table(
        rows,
        cellInline: cellInline,
        streaming: streaming,
      );
  }
}

MessageMarkdownInline? _itemInlineAt(MessageMarkdownBlock block, int index) =>
    index < block.itemInline.length ? block.itemInline[index] : null;

MessageMarkdownInline? _cellInlineAt(
  MessageMarkdownBlock block,
  int row,
  int column,
) => row < block.cellInline.length && column < block.cellInline[row].length
    ? block.cellInline[row][column]
    : null;

/// UTF-8 size of one prepared block, computed without allocating an encoding.
///
/// Prepared inline runs count their own text: the byte cache must see the
/// display payload it actually retains, not just the authored text.
int messageMarkdownBlockBytes(MessageMarkdownBlock block) {
  var bytes = 0;
  bytes += _utf8Bytes(block.text);
  bytes += _utf8Bytes(block.language);
  bytes += 8; // type, level, and list/row framing
  for (final item in block.items) {
    bytes += _utf8Bytes(item) + 1;
  }
  for (final row in block.rows) {
    for (final cell in row) {
      bytes += _utf8Bytes(cell) + 1;
    }
  }
  if (!(block.inline?._sharesDisplayOf(block.text) ?? true)) {
    bytes += _inlineBytes(block.inline!);
  }
  for (var index = 0; index < block.items.length; index++) {
    final inline = _itemInlineAt(block, index);
    if (inline != null && !inline._sharesDisplayOf(block.items[index])) {
      bytes += _inlineBytes(inline) + 1;
    }
  }
  for (var row = 0; row < block.rows.length; row++) {
    for (var column = 0; column < block.rows[row].length; column++) {
      final inline = _cellInlineAt(block, row, column);
      if (inline != null && !inline._sharesDisplayOf(block.rows[row][column])) {
        bytes += _inlineBytes(inline) + 1;
      }
    }
  }
  final tail = block.streaming?.tail;
  if (tail != null) {
    bytes += messageMarkdownBlockBytes(tail) + 5;
  } else if (block.streaming != null) {
    bytes += 5;
  }
  return bytes;
}

int _inlineBytes(MessageMarkdownInline inline) {
  var bytes = 0;
  for (final run in inline.runs) {
    bytes += _utf8Bytes(run.text) + 2; // run text plus its encoded flags
  }
  return bytes;
}

/// UTF-8 size of one string, computed without allocating an encoding.
int _utf8Bytes(String value) {
  var bytes = 0;
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < value.length) {
      // A surrogate pair encodes as four bytes.
      bytes += 4;
      index++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
