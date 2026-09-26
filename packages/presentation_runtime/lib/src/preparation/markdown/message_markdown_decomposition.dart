import 'package:presentation_contract/presentation_contract.dart';

import '../../scheduling/preparation_cancellation.dart';
import '../../scheduling/preparation_worker.dart';
import 'message_markdown_models.dart';
import 'message_markdown_parser.dart';

/// Resolves a link label that this message does not define itself.
///
/// An interleaved conversation can define a link label in another message, so
/// the returned reference points at that message's block and the dependent
/// block is invalidated when it changes.
typedef MarkdownLabelReferenceResolver =
    BlockReference? Function(String label, ResourceKey resource);

/// One message revision broken into F0 source blocks.
///
/// A block keeps its identity while the source keeps treating it as the same
/// block: the same ordinal and the same scanned block type, so an edit earlier
/// in the message does not renumber every block after it. Its [BlockVersion]
/// advances whenever its own text changes, which is what lets a prepared block
/// be reused without re-reading the text.
final class MessageMarkdownDecomposition {
  MessageMarkdownDecomposition._({
    required this.resource,
    required this.position,
    required this.text,
    required this.blocks,
    required this.nextOrdinal,
    this.blockTypes = const <BlockId, MessageMarkdownBlockType>{},
  });

  /// Builds a revision from blocks a source adapter already tracks.
  ///
  /// The caller owns block identity and version here, so every block must cite
  /// text inside [text] at [position]: an offset from another epoch or another
  /// resource would address the wrong bytes.
  factory MessageMarkdownDecomposition.fromBlocks({
    required ResourceKey resource,
    required SourcePosition position,
    required String text,
    required Iterable<SourceBlock> blocks,
  }) {
    final ordered = List<SourceBlock>.unmodifiable(blocks);
    var nextOrdinal = 0;
    for (final block in ordered) {
      if (block.text.resource != resource) {
        throw ArgumentError.value(
          block.id.value,
          'blocks',
          'block text belongs to another resource',
        );
      }
      if (!block.text.isValidIn(position)) {
        throw ArgumentError.value(
          block.id.value,
          'blocks',
          'block text belongs to another source epoch',
        );
      }
      if (block.text.range.end > text.length) {
        throw ArgumentError.value(
          block.id.value,
          'blocks',
          'block range is outside the revision text',
        );
      }
      final ordinal = _trailingOrdinal(block.id);
      if (ordinal != null && ordinal >= nextOrdinal) {
        nextOrdinal = ordinal + 1;
      }
    }
    return MessageMarkdownDecomposition._(
      resource: resource,
      position: position,
      text: text,
      blocks: ordered,
      nextOrdinal: nextOrdinal,
    );
  }

  final ResourceKey resource;
  final SourcePosition position;
  final String text;
  final List<SourceBlock> blocks;

  /// Next free block ordinal, so a diverged revision never reuses an id.
  final int nextOrdinal;

  /// Block type this revision scanned for each of its blocks.
  ///
  /// Identity needs it: an edit earlier in the message shifts every later
  /// block's offset, so the offset alone cannot say whether the block at the
  /// same position is still the same block.
  final Map<BlockId, MessageMarkdownBlockType> blockTypes;

  /// Scanned type of one block, when this revision knows it.
  MessageMarkdownBlockType? typeOf(BlockId id) => blockTypes[id];

  /// Every covered block, in source order.
  List<BlockId> get blockIds =>
      List<BlockId>.unmodifiable(blocks.map((block) => block.id));

  int get blockCount => blocks.length;

  SourceBlock? block(BlockId id) {
    for (final block in blocks) {
      if (block.id == id) return block;
    }
    return null;
  }

  /// The slice of [text] one block covers.
  String textOf(SourceBlock block) =>
      text.substring(block.text.range.start, block.text.range.end);

  ContentRevision toContentRevision() =>
      ContentRevision(resource: resource, position: position, blocks: blocks);

  @override
  String toString() =>
      'MessageMarkdownDecomposition($resource@$position, '
      '${blocks.length} blocks)';
}

/// One block of a message revision as a scan described it.
///
/// It carries primitives only: the block type, the text range it covers,
/// whether its boundary is settled, and the link labels it defines and uses.
/// Identity, version, and references are derived from these values on the
/// caller, so the caller never tokenizes, splits lines, or normalizes text.
final class ScannedMarkdownBlock {
  ScannedMarkdownBlock({
    required this.type,
    required this.range,
    required this.isSealed,
    required Iterable<String> definedLabels,
    required Iterable<String> usedLabels,
  }) : definedLabels = List<String>.unmodifiable(definedLabels),
       usedLabels = List<String>.unmodifiable(usedLabels);

  final MessageMarkdownBlockType type;
  final SourceTextRange range;
  final bool isSealed;
  final List<String> definedLabels;
  final List<String> usedLabels;

  @override
  String toString() =>
      'ScannedMarkdownBlock(${type.name}, $range, sealed: $isSealed)';
}

/// Compact wire form of one scanned block.
///
/// Only primitives cross the worker boundary; the caller rebuilds the
/// descriptor without parsing the text again.
List<Object?> encodeScannedMarkdownBlock(ScannedMarkdownBlock block) =>
    <Object?>[
      block.type.index,
      block.range.start,
      block.range.end,
      block.isSealed,
      block.definedLabels,
      block.usedLabels,
    ];

/// Rebuilds one scanned block from its [encodeScannedMarkdownBlock] form.
ScannedMarkdownBlock decodeScannedMarkdownBlock(Object? payload) {
  final parts = payload! as List<Object?>;
  return ScannedMarkdownBlock(
    type: MessageMarkdownBlockType.values[parts[0]! as int],
    range: SourceTextRange(start: parts[1]! as int, end: parts[2]! as int),
    isSealed: parts[3]! as bool,
    definedLabels: (parts[4]! as List<Object?>).cast<String>(),
    usedLabels: (parts[5]! as List<Object?>).cast<String>(),
  );
}

/// Worker operation that scans one whole message text into block descriptors.
///
/// The reply is compact: one descriptor per block, with no prepared content.
/// Parsing a block's content stays the region operation's job, so a long
/// message never copies its full prepared text back over the boundary.
Future<Object?> runMarkdownScan(
  Object? payload,
  WorkerJobContext context,
) async {
  final config = payload! as List<Object?>;
  final yieldBudgetBytes = config[0]! as int;
  final text = config[1]! as String;
  final scanned = scanMessageMarkdownBlocks(text);
  final result = <Object?>[];
  var bytesSinceYield = 0;
  for (final block in scanned) {
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'scan',
      );
    }
    final length = block.range.end - block.range.start;
    context.recordWorkBytes(length);
    result.add(encodeScannedMarkdownBlock(block));
    bytesSinceYield += length;
    if (bytesSinceYield >= yieldBudgetBytes) {
      bytesSinceYield = 0;
      await context.yieldToControl();
    }
  }
  return result;
}

/// Scans one message text into block descriptors.
///
/// [runMarkdownScan] and the synchronous path share this function, so a scan
/// in a worker and a scan on the caller describe exactly the same blocks.
List<ScannedMarkdownBlock> scanMessageMarkdownBlocks(String text) {
  final spans = scanMessageMarkdownBlockSpans(text);
  final scanned = <ScannedMarkdownBlock>[];
  for (final span in spans) {
    final body = text.substring(span.range.start, span.range.end);
    scanned.add(
      ScannedMarkdownBlock(
        type: span.block.type,
        range: span.range,
        isSealed: span.isSealed,
        definedLabels: _definedLabels(body),
        usedLabels: _usedLabels(body),
      ),
    );
  }
  return List<ScannedMarkdownBlock>.unmodifiable(scanned);
}

/// Builds a revision from blocks a scan already described.
///
/// Identity, versions, and references are derived here and nowhere else, so
/// the synchronous path and the off-thread path cannot drift apart.
MessageMarkdownDecomposition assembleMessageMarkdownDecomposition({
  required ResourceKey resource,
  required SourcePosition position,
  required String text,
  required List<ScannedMarkdownBlock> blocks,
  MessageMarkdownDecomposition? previous,
  String idPrefix = 'block',
  MarkdownLabelReferenceResolver? resolveExternalLabel,
}) {
  // Identity only carries over inside one source epoch: a replaced source
  // issues new block identities, so an old id can never address new text.
  final base =
      previous != null &&
          previous.resource == resource &&
          previous.position.epoch == position.epoch
      ? previous
      : null;
  final reusableOrdinal =
      (base ?? (previous?.resource == resource ? previous : null))
          ?.nextOrdinal ??
      0;
  var ordinal = reusableOrdinal;
  final definitions = <String, BlockId>{};
  final ids = <int, BlockId>{};
  final versions = <int, BlockVersion>{};

  for (var index = 0; index < blocks.length; index++) {
    final scanned = blocks[index];
    final candidate = base != null && index < base.blocks.length
        ? base.blocks[index]
        : null;
    final previousType = candidate == null ? null : base!.typeOf(candidate.id);
    final sameShape =
        candidate != null &&
        (previousType != null
            ? previousType == scanned.type
            : candidate.text.range.start == scanned.range.start);
    if (sameShape) {
      ids[index] = candidate.id;
      final unchanged = _sameText(
        text,
        scanned.range,
        base!.text,
        candidate.text.range,
      );
      versions[index] = unchanged
          ? candidate.version
          : BlockVersion(candidate.version.value + 1);
    } else {
      ids[index] = BlockId('$idPrefix-${ordinal++}');
      versions[index] = const BlockVersion(0);
    }
    for (final label in scanned.definedLabels) {
      definitions[label] = ids[index]!;
    }
  }

  final result = <SourceBlock>[];
  for (var index = 0; index < blocks.length; index++) {
    final scanned = blocks[index];
    result.add(
      SourceBlock(
        id: ids[index]!,
        version: versions[index]!,
        text: SourceTextReference(
          resource: resource,
          position: position,
          range: scanned.range,
        ),
        isSealed: scanned.isSealed,
        references: _referencesFor(
          resource: resource,
          usedLabels: scanned.usedLabels,
          definitions: definitions,
          self: ids[index]!,
          resolveExternalLabel: resolveExternalLabel,
        ),
      ),
    );
  }

  return MessageMarkdownDecomposition._(
    resource: resource,
    position: position,
    text: text,
    blocks: List<SourceBlock>.unmodifiable(result),
    nextOrdinal: ordinal,
    blockTypes: Map<BlockId, MessageMarkdownBlockType>.unmodifiable(
      <BlockId, MessageMarkdownBlockType>{
        for (var index = 0; index < blocks.length; index++)
          ids[index]!: blocks[index].type,
      },
    ),
  );
}

/// True when two text ranges hold the same code units.
///
/// The comparison reads both strings in place; it never allocates the slices
/// it compares, so an unchanged block does not copy its text on the caller.
bool _sameText(
  String text,
  SourceTextRange range,
  String other,
  SourceTextRange otherRange,
) {
  final length = range.end - range.start;
  if (length != otherRange.end - otherRange.start) return false;
  for (var offset = 0; offset < length; offset++) {
    if (text.codeUnitAt(range.start + offset) !=
        other.codeUnitAt(otherRange.start + offset)) {
      return false;
    }
  }
  return true;
}

/// Splits one message revision into source blocks.
///
/// [previous] carries block identity from the revision this one grew out of,
/// so an append keeps earlier block ids and advances only the versions of the
/// blocks whose text changed.
///
/// This synchronous form scans on the calling isolate. A caller that must keep
/// that isolate free uses `MarkdownPreparationEngine.decompose` instead; both
/// paths share the same assembly, so they describe the same revision.
MessageMarkdownDecomposition decomposeMessageMarkdown({
  required ResourceKey resource,
  required SourcePosition position,
  required String text,
  MessageMarkdownDecomposition? previous,
  String idPrefix = 'block',
  MarkdownLabelReferenceResolver? resolveExternalLabel,
}) => assembleMessageMarkdownDecomposition(
  resource: resource,
  position: position,
  text: text,
  blocks: scanMessageMarkdownBlocks(text),
  previous: previous,
  idPrefix: idPrefix,
  resolveExternalLabel: resolveExternalLabel,
);

Set<BlockReference> _referencesFor({
  required ResourceKey resource,
  required Iterable<String> usedLabels,
  required Map<String, BlockId> definitions,
  required BlockId self,
  MarkdownLabelReferenceResolver? resolveExternalLabel,
}) {
  final references = <BlockReference>{};
  for (final label in usedLabels) {
    final target = definitions[label];
    if (target != null) {
      if (target != self) {
        references.add(BlockReference(resource: resource, blockId: target));
      }
      continue;
    }
    final external = resolveExternalLabel?.call(label, resource);
    if (external != null) references.add(external);
  }
  return references;
}

final RegExp _labelPattern = RegExp(r'\[([^\[\]\n]+)\]');

Iterable<String> _definedLabels(String body) sync* {
  for (final match in _labelPattern.allMatches(body)) {
    if (_isDefinition(body, match.end)) yield match.group(1)!;
  }
}

Iterable<String> _usedLabels(String body) sync* {
  for (final match in _labelPattern.allMatches(body)) {
    if (!_isDefinition(body, match.end)) yield match.group(1)!;
  }
}

bool _isDefinition(String body, int matchEnd) =>
    matchEnd < body.length && body[matchEnd] == ':';

final RegExp _trailingDigits = RegExp(r'(\d+)$');

int? _trailingOrdinal(BlockId id) {
  final match = _trailingDigits.firstMatch(id.value);
  return match == null ? null : int.tryParse(match.group(1)!);
}
