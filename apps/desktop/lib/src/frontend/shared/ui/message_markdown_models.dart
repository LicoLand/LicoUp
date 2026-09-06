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

final class MessageMarkdownBlock {
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
      items: List.unmodifiable(items),
    );
  }

  factory MessageMarkdownBlock.orderedList(List<String> items) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.orderedList,
      text: '',
      items: List.unmodifiable(items),
    );
  }

  factory MessageMarkdownBlock.table(List<List<String>> rows) {
    return MessageMarkdownBlock._(
      type: MessageMarkdownBlockType.table,
      text: '',
      rows: List.unmodifiable(
        rows.map((row) => List<String>.unmodifiable(row)),
      ),
    );
  }

  final MessageMarkdownBlockType type;
  final String text;
  final int level;
  final List<String> items;
  final List<List<String>> rows;
  final String language;

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
