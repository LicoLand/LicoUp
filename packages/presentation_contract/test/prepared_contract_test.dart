import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

const ResourceScope _scope = ResourceScope('conversation:synthetic');
const ResourceKey _message = ResourceKey(scope: _scope, stableKey: 'message-1');

SourcePosition _position({int version = 3, String epoch = 'epoch-a'}) =>
    SourcePosition(epoch: SourceEpoch(epoch), version: SourceVersion(version));

SourceBlock _block({
  required String id,
  int version = 1,
  bool sealed = false,
  SourcePosition? at,
  Iterable<BlockReference> references = const <BlockReference>[],
}) => SourceBlock(
  id: BlockId(id),
  version: BlockVersion(version),
  text: SourceTextReference(
    resource: _message,
    position: at ?? _position(),
    range: const SourceTextRange(start: 0, end: 4),
  ),
  isSealed: sealed,
  references: references,
);

ContentRevision _content({int version = 3, Iterable<SourceBlock>? blocks}) =>
    ContentRevision(
      resource: _message,
      position: _position(version: version),
      blocks: blocks ?? <SourceBlock>[_block(id: 'body', sealed: true)],
    );

PreparationKey _key({
  String parser = 'message-markdown@3',
  String syntaxRevision = 'syntax@1',
  Iterable<String> features = const <String>['tables'],
  ContentRevision? content,
}) => PreparationKey(
  parserVersion: ParserVersion(parser),
  syntaxConfig: SyntaxConfig(revision: syntaxRevision, features: features),
  content: content ?? _content(),
);

ConsistencyGroup _group({
  required List<ResourceFieldGroup<String>> fields,
  SourcePosition? position,
  String id = 'group-1',
}) => ConsistencyGroup(
  id: ConsistencyGroupId(id),
  position: position ?? _position(),
  changed: fields.map(ChangedFieldGroup.of).toList(),
);

PreparedResource<String> _member(
  ResourceFieldGroup<String> fields,
  ConsistencyGroup group,
  String value, {
  RequestGeneration generation = const RequestGeneration(1),
}) => PreparedResource<String>(
  request: PreparationRequest<String>(
    resource: fields,
    source: group.position,
    generation: generation,
    consistencyGroup: group,
  ),
  value: value,
);

PreparationAcceptance<String> _accepts(PreparedResource<String> result) =>
    PreparationAcceptance<String>(request: result.request);

void main() {
  final body = ResourceFieldGroup<String>(resource: _message, name: 'body');
  final meta = ResourceFieldGroup<String>(resource: _message, name: 'meta');

  test('a text reference resolves only inside its own source epoch', () {
    const reference = SourceTextReference(
      resource: _message,
      position: SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(3),
      ),
      range: SourceTextRange(start: 4, end: 12),
    );

    expect(reference.isValidIn(_position(version: 4)), isTrue);
    expect(
      reference.isValidIn(_position(version: 3, epoch: 'epoch-b')),
      isFalse,
    );
    expect(reference.range.length, 8);
    expect(reference.range.containsOffset(4), isTrue);
    expect(reference.range.containsOffset(12), isFalse);
    expect(reference.range.isEmpty, isFalse);
  });

  test('a content revision refuses blocks from another resource or epoch', () {
    SourceBlock foreign(String key) => SourceBlock(
      id: const BlockId('body'),
      version: const BlockVersion(1),
      text: SourceTextReference(
        resource: ResourceKey(scope: _scope, stableKey: key),
        position: _position(),
        range: const SourceTextRange(start: 0, end: 4),
      ),
    );

    expect(
      () => ContentRevision(
        resource: _message,
        position: _position(),
        blocks: <SourceBlock>[foreign('message-2')],
      ),
      throwsArgumentError,
    );
    expect(
      () => ContentRevision(
        resource: _message,
        position: _position(),
        blocks: <SourceBlock>[
          _block(
            id: 'body',
            at: _position(epoch: 'epoch-b'),
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => ContentRevision(
        resource: _message,
        position: _position(),
        blocks: <SourceBlock>[
          _block(id: 'body'),
          _block(id: 'body'),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      ContentRevision(
        resource: _message,
        position: _position(),
        blocks: <SourceBlock>[_block(id: 'body')],
      ).blockIds,
      <BlockId>[const BlockId('body')],
    );
  });

  test('a restyle keeps the preparation key; a semantic change replaces it', () {
    final key = _key();
    final same = _key(
      content: _content(
        blocks: <SourceBlock>[_block(id: 'body', sealed: true)],
      ),
    );

    // Nothing in a key belongs to rendering, so restyling cannot invalidate it.
    expect(same.requiresRePreparation(key), isFalse);
    expect(
      _key(parser: 'message-markdown@4').requiresRePreparation(key),
      isTrue,
    );
    expect(
      _key(
        features: const <String>['tables', 'math'],
      ).requiresRePreparation(key),
      isTrue,
    );
    expect(_key(syntaxRevision: 'syntax@2').requiresRePreparation(key), isTrue);
    expect(
      _key(content: _content(version: 4)).requiresRePreparation(key),
      isTrue,
    );
    expect(_key().requiresRePreparation(null), isTrue);
  });

  test(
    'a prepared value freezes only sealed blocks with resolved references',
    () {
      final dependency = BlockReference(
        resource: _message,
        blockId: const BlockId('definitions'),
      );
      final open = _content(
        blocks: <SourceBlock>[
          _block(
            id: 'body',
            version: 2,
            sealed: true,
            references: [dependency],
          ),
          _block(id: 'definitions'),
        ],
      );
      final key = _key(content: open);
      final pending = PreparedValue<String>.fromBlocks(
        key: key,
        blocks: <PreparedBlock<String>>[
          PreparedBlock<String>(block: open.blocks[0], value: 'body'),
          PreparedBlock<String>(block: open.blocks[1], value: 'definitions'),
        ],
      );

      expect(pending.immutablePrefix, isEmpty);
      expect(pending.isComplete, isFalse);
      expect(pending.blockIds, <BlockId>[
        const BlockId('body'),
        const BlockId('definitions'),
      ]);

      final sealed = _content(
        blocks: <SourceBlock>[
          _block(
            id: 'body',
            version: 2,
            sealed: true,
            references: [dependency],
          ),
          _block(id: 'definitions', sealed: true),
        ],
      );
      final settled = PreparedValue<String>.fromBlocks(
        key: _key(content: sealed),
        blocks: <PreparedBlock<String>>[
          PreparedBlock<String>(block: sealed.blocks[0], value: 'body'),
          PreparedBlock<String>(block: sealed.blocks[1], value: 'definitions'),
        ],
      );

      expect(settled.immutablePrefix.map((prepared) => prepared.id), <BlockId>[
        const BlockId('body'),
        const BlockId('definitions'),
      ]);
      expect(settled.mutableTail, isEmpty);
      expect(settled.isComplete, isTrue);
      expect(settled.resource, _message);
      expect(settled.position, sealed.position);
      expect(pending.dependsOn(dependency), isTrue);
    },
  );

  test('an open block between frozen ones keeps the source order', () {
    final content = _content(
      blocks: <SourceBlock>[
        _block(id: 'intro', sealed: true),
        _block(id: 'fence'),
        _block(id: 'outro', sealed: true),
      ],
    );
    final value = PreparedValue<String>.fromBlocks(
      key: _key(content: content),
      blocks: <PreparedBlock<String>>[
        for (final block in content.blocks)
          PreparedBlock<String>(block: block, value: block.id.value),
      ],
    );

    expect(value.blockIds, <BlockId>[
      const BlockId('intro'),
      const BlockId('fence'),
      const BlockId('outro'),
    ]);
    expect(value.immutablePrefix.map((prepared) => prepared.id), <BlockId>[
      const BlockId('intro'),
      const BlockId('outro'),
    ]);
    expect(value.mutableTail.map((prepared) => prepared.id), <BlockId>[
      const BlockId('fence'),
    ]);
    expect(value.blocks.map((prepared) => prepared.id), value.blockIds);
  });

  test('a prepared value refuses a frozen block that can still change', () {
    final content = _content(
      blocks: <SourceBlock>[_block(id: 'body', version: 2)],
    );
    final key = _key(content: content);
    final unsealed = <PreparedBlock<String>>[
      PreparedBlock<String>(block: content.blocks.single, value: 'body'),
    ];

    expect(
      () => PreparedValue<String>(
        key: key,
        immutablePrefix: unsealed,
        mutableTail: const <PreparedBlock<String>>[],
      ),
      throwsArgumentError,
    );
    expect(
      () => PreparedValue<String>(
        key: key,
        immutablePrefix: const <PreparedBlock<String>>[],
        mutableTail: const <PreparedBlock<String>>[],
      ),
      throwsArgumentError,
    );
    expect(
      () => PreparedValue<String>(
        key: key,
        immutablePrefix: const <PreparedBlock<String>>[],
        mutableTail: <PreparedBlock<String>>[
          PreparedBlock<String>(
            block: _block(id: 'body', version: 3),
            value: 'body',
          ),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      PreparedValue<String>(
        key: key,
        immutablePrefix: const <PreparedBlock<String>>[],
        mutableTail: unsealed,
      ).mutableTail.single.id,
      const BlockId('body'),
    );
  });

  test('a preparation declares the plain inputs and reason it read', () {
    final content = _content();
    final value = PreparedValue<String>.fromBlocks(
      key: _key(content: content),
      blocks: <PreparedBlock<String>>[
        PreparedBlock<String>(block: content.blocks.single, value: 'body'),
      ],
      referencedInputs: <PreparedInputReference>[
        PreparedInputReference(
          resource: _message,
          name: 'query',
          position: content.position,
        ),
      ],
    );

    expect(value.referencedInputs.single.matches(body), isFalse);
    expect(
      value.referencedInputs.single.matches(
        ResourceFieldGroup<String>(resource: _message, name: 'query'),
      ),
      isTrue,
    );

    final group = _group(fields: <ResourceFieldGroup<String>>[body]);
    final snapshot = ResourceSnapshot<String>(
      fieldGroup: body,
      epoch: group.position.epoch,
      version: group.position.version,
      value: 'body',
      consistencyGroup: group,
    );
    final cause = PreparationCause(
      trigger: PreparationTrigger.sourceReplaced,
      scope: PreparationScope.global,
      changed: <BlockId>{const BlockId('body')},
    );
    final replaced = PreparationRequest<String>.fromSnapshot(
      snapshot: snapshot,
      generation: const RequestGeneration(2),
      cause: cause,
    );

    expect(replaced.cause, cause);
    expect(cause.isGlobal, isTrue);
    expect(value.matches(replaced), isTrue);
    expect(
      replaced,
      isNot(
        PreparationRequest<String>.fromSnapshot(
          snapshot: snapshot,
          generation: const RequestGeneration(2),
        ),
      ),
    );
  });

  test('one group completes in batches and never installs a mixed version', () {
    final group = _group(fields: <ResourceFieldGroup<String>>[body, meta]);
    final install = ConsistencyGroupInstall<String>(group);

    expect(
      install.offer(
        _member(body, group, 'body'),
        _accepts(_member(body, group, 'body')),
      ),
      GroupInstallOutcome.staged,
    );
    expect(install.installed, isEmpty);
    expect(install.isComplete, isFalse);
    expect(install.pending.map((changed) => changed.name), <String>['meta']);

    final last = _member(meta, group, 'meta');
    expect(install.offer(last, _accepts(last)), GroupInstallOutcome.installed);
    expect(
      install.installed.values.map((result) => result.value),
      containsAll(<String>['body', 'meta']),
    );
    expect(install.isComplete, isTrue);

    // A member from another position is refused instead of mixing the view.
    final older = _position(version: 2);
    final oldGroup = _group(
      fields: <ResourceFieldGroup<String>>[body, meta],
      position: older,
    );
    final stale = _member(body, oldGroup, 'body');
    expect(install.offer(stale, _accepts(stale)), GroupInstallOutcome.rejected);
  });

  test('revocation and dispose reject staged and late members at once', () {
    final group = _group(fields: <ResourceFieldGroup<String>>[body, meta]);
    final first = _member(body, group, 'body');
    final install = ConsistencyGroupInstall<String>(group);

    expect(install.offer(first, _accepts(first)), GroupInstallOutcome.staged);
    install.revoke();

    expect(install.isRevoked, isTrue);
    expect(install.staged, isEmpty);
    expect(install.installed, isEmpty);
    expect(install.isComplete, isFalse);

    final late = _member(meta, group, 'meta');
    expect(install.offer(late, _accepts(late)), GroupInstallOutcome.rejected);

    final disposed = ConsistencyGroupInstall<String>(group);
    disposed.dispose();
    expect(disposed.isDisposed, isTrue);
    expect(
      disposed.offer(first, _accepts(first)),
      GroupInstallOutcome.rejected,
    );

    final generation = ConsistencyGroupInstall<String>(group);
    expect(
      generation.offer(
        first,
        PreparationAcceptance<String>(
          request: PreparationRequest<String>(
            resource: body,
            source: group.position,
            generation: const RequestGeneration(9),
            consistencyGroup: group,
          ),
        ),
      ),
      GroupInstallOutcome.rejected,
    );
    expect(
      generation.offer(
        first,
        PreparationAcceptance<String>(
          request: first.request,
          status: PreparationStatus.revoked,
        ),
      ),
      GroupInstallOutcome.rejected,
    );
    expect(generation.installed, isEmpty);
  });

  test('a group still loading never blocks another group', () {
    final slowGroup = _group(fields: <ResourceFieldGroup<String>>[body, meta]);
    final fastGroup = _group(
      fields: <ResourceFieldGroup<String>>[body, meta],
      position: _position(version: 4),
      id: 'group-2',
    );
    final slow = ConsistencyGroupInstall<String>(slowGroup);
    final fast = ConsistencyGroupInstall<String>(fastGroup);

    final slowMember = _member(body, slowGroup, 'body');
    expect(
      slow.offer(slowMember, _accepts(slowMember)),
      GroupInstallOutcome.staged,
    );
    expect(slow.isComplete, isFalse);

    final fastBody = _member(body, fastGroup, 'body');
    final fastMeta = _member(meta, fastGroup, 'meta');
    expect(
      fast.offer(fastBody, _accepts(fastBody)),
      GroupInstallOutcome.staged,
    );
    expect(
      fast.offer(fastMeta, _accepts(fastMeta)),
      GroupInstallOutcome.installed,
    );
    expect(fast.isComplete, isTrue);
    expect(slow.isComplete, isFalse);
    expect(slow.installed, isEmpty);
  });

  test('metadata and body may wait as different consistency groups', () {
    final metadataOnly = _group(
      fields: <ResourceFieldGroup<String>>[meta],
      id: 'metadata-group',
    );
    final bodyOnly = _group(
      fields: <ResourceFieldGroup<String>>[body],
      position: _position(version: 4),
      id: 'body-group',
    );
    final metadata = ConsistencyGroupInstall<String>(metadataOnly);
    final text = ConsistencyGroupInstall<String>(bodyOnly);

    final metaMember = _member(meta, metadataOnly, 'meta');
    expect(
      metadata.offer(metaMember, _accepts(metaMember)),
      GroupInstallOutcome.installed,
    );
    expect(metadata.isComplete, isTrue);
    expect(text.isComplete, isFalse);
    expect(text.installed, isEmpty);
  });

  test('a third-party declarative input stays ordinary data', () {
    final chart = DeclarativeInput<Map<String, Object?>, String>(
      contributionId: 'vendor.example.usage-chart',
      primitive: DeclarativePrimitive.chart,
      resource: _message,
      inputs: const <String, Object?>{
        'series': <String>['tokens'],
      },
      actions: CallbackActions<String>(
        origin: const ActionOrigin(scope: _scope, resource: _message),
        onDispatch: (action, origin) {},
      ),
      position: _position(),
    );

    expect(chart.origin.scope, _scope);
    expect(
      chart.isSupportedBy(<DeclarativePrimitive>[DeclarativePrimitive.form]),
      isFalse,
    );
    expect(
      chart.unavailableGiven(<DeclarativePrimitive>[DeclarativePrimitive.form]),
      DeclarativeUnavailable(
        contributionId: 'vendor.example.usage-chart',
        primitive: DeclarativePrimitive.chart,
        resource: _message,
      ),
    );
    expect(
      chart.unavailableGiven(<DeclarativePrimitive>[
        DeclarativePrimitive.chart,
      ]),
      isNull,
    );
    expect(
      chart.isSupportedBy(<DeclarativePrimitive>[chart.primitive]),
      isTrue,
    );
  });

  test('a missing primitive leaves the source merging lifecycle alone', () {
    final group = _group(fields: <ResourceFieldGroup<String>>[body, meta]);
    final form = DeclarativeInput<List<String>, String>(
      contributionId: 'vendor.example.settings-form',
      primitive: DeclarativePrimitive.form,
      resource: _message,
      inputs: const <String>['display-name'],
      actions: CallbackActions<String>(
        origin: const ActionOrigin(scope: _scope, resource: _message),
        onDispatch: (action, origin) {},
      ),
    );

    expect(
      form.unavailableGiven(<DeclarativePrimitive>[DeclarativePrimitive.text]),
      isNotNull,
    );

    // The resource still installs its own consistency group unchanged.
    final install = ConsistencyGroupInstall<String>(group);
    final first = _member(body, group, 'body');
    final second = _member(meta, group, 'meta');
    expect(install.offer(first, _accepts(first)), GroupInstallOutcome.staged);
    expect(
      install.offer(second, _accepts(second)),
      GroupInstallOutcome.installed,
    );
    expect(install.isComplete, isTrue);
  });
}
