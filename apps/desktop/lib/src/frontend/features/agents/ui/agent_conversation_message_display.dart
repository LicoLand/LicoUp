int recommendedPluginsCount(List<String> blocks) {
  var count = 0;
  for (final block in blocks) {
    for (final line in block.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        count++;
      }
    }
  }
  return count;
}

class MessageDisplayContent {
  const MessageDisplayContent({
    required this.body,
    required this.metadataBlocks,
    required this.recommendedPluginsBlocks,
  });

  final String body;
  final List<String> metadataBlocks;
  final List<String> recommendedPluginsBlocks;
}

MessageDisplayContent splitMessageDisplayBlocks(String data) {
  final pluginsExtraction = _extractBlocks(data, _recommendedPluginsPattern);
  final metadataExtraction = _extractBlocks(
    pluginsExtraction.body,
    _additionalMetadataPattern,
  );
  return MessageDisplayContent(
    body: _compactMessageBody(metadataExtraction.body),
    metadataBlocks: metadataExtraction.blocks,
    recommendedPluginsBlocks: pluginsExtraction.blocks,
  );
}

String conversationMessagePreviewText(String text) {
  return splitMessageDisplayBlocks(text).body.trim();
}

({String body, List<String> blocks}) _extractBlocks(
  String data,
  RegExp pattern,
) {
  final matches = pattern.allMatches(data);
  if (matches.isEmpty) {
    return (body: data, blocks: const <String>[]);
  }
  final body = StringBuffer();
  final blocks = <String>[];
  var cursor = 0;
  for (final match in matches) {
    body.write(data.substring(cursor, match.start));
    final block = (match.group(1) ?? '').trim();
    if (block.isNotEmpty) {
      blocks.add(block);
    }
    cursor = match.end;
  }
  body.write(data.substring(cursor));
  return (body: body.toString(), blocks: blocks);
}

final _additionalMetadataPattern = RegExp(
  r'<\s*additional_metadata\s*>([\s\S]*?)<\s*/\s*additional_metadata\s*>',
  caseSensitive: false,
);

final _recommendedPluginsPattern = RegExp(
  r'<\s*recommended_plugins\s*>([\s\S]*?)<\s*/\s*recommended_plugins\s*>',
  caseSensitive: false,
);

String _compactMessageBody(String text) {
  return text
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
