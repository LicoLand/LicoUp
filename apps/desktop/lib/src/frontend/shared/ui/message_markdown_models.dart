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
}
