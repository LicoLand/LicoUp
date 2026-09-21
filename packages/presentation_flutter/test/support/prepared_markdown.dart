import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

/// Synthetic scope for widget tests. It has no process, host, or application
/// dependency.
const ResourceScope testResourceScope = ResourceScope('test-conversation');

/// Builds one prepared message value from plain prepared blocks.
///
/// The ids let a later call describe the next source version of the same
/// message: unchanged blocks keep their id and text, while the growing tail
/// keeps its id with new text. This mirrors what the runtime installs without
/// starting a worker isolate.
PreparedValue<MessageMarkdownBlock> preparedMarkdownValue(
  List<(String, MessageMarkdownBlock)> blocks, {
  int version = 1,
  bool openTail = false,
  String epoch = 'epoch-a',
  String message = 'message-1',
}) {
  final resource = ResourceKey(scope: testResourceScope, stableKey: message);
  final position = SourcePosition(
    epoch: SourceEpoch(epoch),
    version: SourceVersion(version),
  );

  final source = StringBuffer();
  final sourceBlocks = <SourceBlock>[];
  final preparedBlocks = <PreparedBlock<MessageMarkdownBlock>>[];
  for (var index = 0; index < blocks.length; index++) {
    final (id, block) = blocks[index];
    if (index > 0) source.write('\n');
    final start = source.length;
    source.write(_sourceText(block));
    final end = source.length;
    final sourceBlock = SourceBlock(
      id: BlockId(id),
      version: BlockVersion(version),
      text: SourceTextReference(
        resource: resource,
        position: position,
        range: SourceTextRange(start: start, end: end),
      ),
      isSealed: !(openTail && index == blocks.length - 1),
    );
    sourceBlocks.add(sourceBlock);
    preparedBlocks.add(
      PreparedBlock<MessageMarkdownBlock>(block: sourceBlock, value: block),
    );
  }

  return PreparedValue<MessageMarkdownBlock>.fromBlocks(
    key: PreparationKey(
      parserVersion: const ParserVersion('licoup.test.v1'),
      syntaxConfig: SyntaxConfig(revision: 'licoup.test.default'),
      content: ContentRevision(
        resource: resource,
        position: position,
        blocks: sourceBlocks,
      ),
    ),
    blocks: preparedBlocks,
  );
}

String _sourceText(MessageMarkdownBlock block) {
  return switch (block.type) {
    MessageMarkdownBlockType.table =>
      block.rows.map((row) => row.join(' | ')).join('\n'),
    MessageMarkdownBlockType.unorderedList ||
    MessageMarkdownBlockType.orderedList => block.items.join('\n'),
    _ => block.text,
  };
}
