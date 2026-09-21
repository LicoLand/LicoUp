import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

const _resource = ResourceKey(
  scope: ResourceScope('synthetic'),
  stableKey: 'message',
);
const _position = SourcePosition(
  epoch: SourceEpoch('source-a'),
  version: SourceVersion(1),
);

SourceBlock _block(
  String id, {
  bool sealed = true,
  Iterable<String> references = const [],
  ResourceKey resource = _resource,
  SourcePosition position = _position,
  SourceTextRange range = const SourceTextRange(start: 0, end: 4),
}) => SourceBlock(
  id: BlockId(id),
  version: const BlockVersion(1),
  text: SourceTextReference(
    resource: resource,
    position: position,
    range: range,
  ),
  isSealed: sealed,
  references: references.map(
    (id) => BlockReference(resource: resource, blockId: BlockId(id)),
  ),
);

PreparationKey _key(List<SourceBlock> blocks) => PreparationKey(
  parserVersion: const ParserVersion('synthetic@1'),
  syntaxConfig: SyntaxConfig(revision: 'syntax@1'),
  content: ContentRevision(
    resource: _resource,
    position: _position,
    blocks: blocks,
  ),
);

PreparedBlock<String> _prepared(SourceBlock block) =>
    PreparedBlock(block: block, value: block.id.value);

void main() {
  test('preparation cause freezes caller-owned changed block sets', () {
    final changed = <BlockId>{const BlockId('body')};
    final cause = PreparationCause(
      trigger: PreparationTrigger.blocksChanged,
      scope: PreparationScope.incremental,
      changed: changed,
    );
    final originalHash = cause.hashCode;
    changed.add(const BlockId('late'));
    expect(cause.changed, {const BlockId('body')});
    expect(cause.hashCode, originalHash);
    expect(cause.changed.clear, throwsUnsupportedError);
  });

  test('prepared blocks must carry the complete source block identity', () {
    final source = _block('body');
    final key = _key([source]);
    final conflicts = <SourceBlock>[
      _block(
        'body',
        resource: const ResourceKey(
          scope: ResourceScope('other-scope'),
          stableKey: 'message',
        ),
      ),
      _block(
        'body',
        position: const SourcePosition(
          epoch: SourceEpoch('source-b'),
          version: SourceVersion(1),
        ),
      ),
      _block(
        'body',
        position: const SourcePosition(
          epoch: SourceEpoch('source-a'),
          version: SourceVersion(2),
        ),
      ),
      _block('body', range: const SourceTextRange(start: 4, end: 8)),
      _block('body', sealed: false),
      _block('body', references: ['missing-definition']),
    ];
    for (final conflict in conflicts) {
      expect(
        () => PreparedValue<String>.fromBlocks(
          key: key,
          blocks: [_prepared(conflict)],
        ),
        throwsArgumentError,
        reason: 'equal id/version cannot hide a different source block',
      );
    }
    expect(
      PreparedValue<String>.fromBlocks(
        key: key,
        blocks: [_prepared(_block('body'))],
      ).blocks.single.block,
      source,
    );
  });

  test('prefix eligibility follows transitive unresolved dependencies', () {
    final blocks = [
      _block('body', references: ['definition']),
      _block('definition', references: ['open']),
      _block('open', sealed: false),
      _block('independent'),
    ];
    final key = _key(blocks);
    final value = PreparedValue<String>.fromBlocks(
      key: key,
      blocks: blocks.map(_prepared),
    );
    expect(value.immutablePrefix.map((block) => block.id.value), [
      'independent',
    ]);
    expect(value.mutableTail.map((block) => block.id.value), [
      'body',
      'definition',
      'open',
    ]);
    expect(
      () => PreparedValue<String>(
        key: key,
        immutablePrefix: [_prepared(blocks.first)],
        mutableTail: blocks.skip(1).map(_prepared),
      ),
      throwsArgumentError,
    );
  });

  test('sealed cycles freeze only when no member reaches a mutable block', () {
    for (final resolved in [false, true]) {
      final blocks = [
        _block('a', references: ['b']),
        _block('b', references: ['a', 'c']),
        _block('c', sealed: resolved),
      ];
      final value = PreparedValue<String>.fromBlocks(
        key: _key(blocks),
        blocks: blocks.map(_prepared),
      );
      expect(value.immutablePrefix, hasLength(resolved ? 3 : 0));
      expect(value.isComplete, resolved);
    }
  });

  test('equality includes the observable frozen and mutable partition', () {
    final block = _prepared(_block('body'));
    final key = _key([block.block]);
    final frozen = PreparedValue<String>(
      key: key,
      immutablePrefix: [block],
      mutableTail: [],
    );
    final pending = PreparedValue<String>(
      key: key,
      immutablePrefix: [],
      mutableTail: [block],
    );
    expect(frozen.isComplete, isTrue);
    expect(pending.isComplete, isFalse);
    expect(frozen, isNot(pending));
    expect({frozen, pending}, hasLength(2));
  });
}
