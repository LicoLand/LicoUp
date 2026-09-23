library presentation_contract;


import 'dart:async';

/// Stable ownership scope for a presentation resource.
///
/// A scope is part of identity. It is not a widget or provider lifetime.
final class ResourceScope {
  const ResourceScope(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ResourceScope && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ResourceScope($value)';
}

/// Alternate name used by application-facing declarations.
typedef PresentationScope = ResourceScope;

/// Stable identity for one resource inside a scope.
final class ResourceKey {
  const ResourceKey({required this.scope, required this.stableKey});

  final ResourceScope scope;
  final String stableKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceKey &&
          other.scope == scope &&
          other.stableKey == stableKey;

  @override
  int get hashCode => Object.hash(scope, stableKey);

  @override
  String toString() => '$scope/$stableKey';
}

/// A typed group of fields read from one [ResourceKey].
///
/// The type parameter belongs to the group, so two consumers can select
/// different typed groups for the same resource without sharing a wider
/// snapshot type.
final class ResourceFieldGroup<T> {
  const ResourceFieldGroup({required this.resource, required this.name});

  final ResourceKey resource;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceFieldGroup<T> &&
          other.resource == resource &&
          other.name == name;

  @override
  int get hashCode => Object.hash(resource, name);

  @override
  String toString() => '$resource#$name';
}

/// Short name for declarations that already sit inside a resource module.
typedef FieldGroup<T> = ResourceFieldGroup<T>;

/// Opaque identity of the authority that owns source ordering.
final class SourceIdentity {
  const SourceIdentity({required this.scope, required this.stableKey});

  final ResourceScope scope;
  final String stableKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceIdentity &&
          other.scope == scope &&
          other.stableKey == stableKey;

  @override
  int get hashCode => Object.hash(scope, stableKey);
}

/// Identity of one incarnation of a source.
///
/// The value is intentionally opaque. Callers must use a stable immutable
/// scalar, such as a source-issued string or integer, rather than derive it
/// from snapshot contents.
final class SourceEpoch {
  const SourceEpoch(this.value);

  final Object value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SourceEpoch && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SourceEpoch($value)';
}

/// Monotonic order issued by one source epoch.
final class SourceVersion {
  const SourceVersion(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SourceVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'SourceVersion($value)';
}

/// Result of comparing source positions.
///
/// [differentEpoch] is deliberately not ordered. A version from a rebuilt
/// source cannot supersede or precede a version from another source epoch.
enum VersionRelation { older, same, newer, differentEpoch }

/// A source position whose version is meaningful only within [epoch].
final class SourcePosition {
  const SourcePosition({required this.epoch, required this.version});

  final SourceEpoch epoch;
  final SourceVersion version;

  VersionRelation compare(SourcePosition other) {
    if (epoch != other.epoch) return VersionRelation.differentEpoch;
    final order = version.value.compareTo(other.version.value);
    if (order < 0) return VersionRelation.older;
    if (order > 0) return VersionRelation.newer;
    return VersionRelation.same;
  }

  bool get isInitial => version.value == 0;

  bool isSameEpochAs(SourcePosition other) => epoch == other.epoch;

  bool isAfter(SourcePosition other) => compare(other) == VersionRelation.newer;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourcePosition &&
          other.epoch == epoch &&
          other.version == version;

  @override
  int get hashCode => Object.hash(epoch, version);

  @override
  String toString() => '$epoch/$version';
}

/// Names used by source adapters and preparation code for the same position.
typedef SourceCursor = SourcePosition;
typedef SourceStamp = SourcePosition;

/// Half-open `[start, end)` offset range inside one source revision.
///
/// The numbers are meaningless without the [SourceTextReference] that carries
/// them: the same offsets address different text in another revision.
final class SourceTextRange {
  const SourceTextRange({required this.start, required this.end})
    : assert(start >= 0, 'start must not be negative'),
      assert(end >= start, 'end must not precede start');

  final int start;
  final int end;

  int get length => end - start;

  bool get isEmpty => end <= start;

  bool containsOffset(int offset) => offset >= start && offset < end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceTextRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SourceTextRange($start..$end)';
}

/// Citation of the original source text a prepared value was built from.
///
/// Display code can keep the full text, copy it, or anchor selection to it
/// without re-parsing, because the reference says which resource revision the
/// offsets belong to and whether they are still meaningful.
final class SourceTextReference {
  const SourceTextReference({
    required this.resource,
    required this.position,
    required this.range,
  });

  final ResourceKey resource;
  final SourcePosition position;
  final SourceTextRange range;

  /// Offsets resolve only inside the epoch that issued them.
  ///
  /// Replacing a source opens a new [SourceEpoch]. References from the old
  /// epoch stay invalid in it even when the new text looks similar.
  bool isValidIn(SourcePosition other) => position.epoch == other.epoch;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceTextReference &&
          other.resource == resource &&
          other.position == position &&
          other.range == range;

  @override
  int get hashCode => Object.hash(resource, position, range);

  @override
  String toString() => '$resource@$position$range';
}

/// Stable identity of one block inside one [SourceEpoch].
///
/// A block keeps its identity while the source keeps treating it as the same
/// block, even as its text grows and its [BlockVersion] advances. A replaced
/// source issues a new epoch, so old block identities do not carry over.
final class BlockId {
  const BlockId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BlockId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BlockId($value)';
}

/// Version of one block's text inside one [SourceEpoch].
final class BlockVersion {
  const BlockVersion(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BlockVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'BlockVersion($value)';
}

/// Reference to one block, in this resource or in another one.
///
/// A link definition, a footnote, or an interleaved message can make one
/// block's prepared output depend on a block elsewhere, so the reference
/// carries the resource as well as the [BlockId].
final class BlockReference {
  const BlockReference({required this.resource, required this.blockId});

  final ResourceKey resource;
  final BlockId blockId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockReference &&
          other.resource == resource &&
          other.blockId == blockId;

  @override
  int get hashCode => Object.hash(resource, blockId);

  @override
  String toString() => '$resource#$blockId';
}

/// One block of a source revision and what its text depends on.
final class SourceBlock {
  factory SourceBlock({
    required BlockId id,
    required BlockVersion version,
    required SourceTextReference text,
    bool isSealed = false,
    Iterable<BlockReference> references = const <BlockReference>[],
  }) => SourceBlock._(
    id: id,
    version: version,
    text: text,
    isSealed: isSealed,
    references: Set<BlockReference>.unmodifiable(references),
  );

  const SourceBlock._({
    required this.id,
    required this.version,
    required this.text,
    required this.isSealed,
    required this.references,
  });

  final BlockId id;
  final BlockVersion version;
  final SourceTextReference text;

  /// True once the source observed this block's final boundary.
  ///
  /// An open fence or a table continuation that may still grow is not sealed,
  /// so its prepared output cannot be treated as final yet.
  final bool isSealed;

  /// Blocks whose text this block's prepared output depends on.
  ///
  /// A sealed block with an unresolved reference can still change, so the
  /// dependency stays declared after the block's own text stops growing.
  final Set<BlockReference> references;

  bool referencesBlock(BlockReference reference) =>
      references.contains(reference);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SourceBlock &&
          other.id == id &&
          other.version == version &&
          other.text == text &&
          other.isSealed == isSealed &&
          _sameSet(other.references, references);

  @override
  int get hashCode =>
      Object.hash(id, version, text, isSealed, _setHash(references));

  @override
  String toString() => '$id@$version${isSealed ? '' : ' (open)'}';
}

/// Identity of one atomic group of source changes.
final class ConsistencyGroupId {
  const ConsistencyGroupId(this.value, {this.source});

  final Object value;
  final SourceIdentity? source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConsistencyGroupId &&
          other.value == value &&
          other.source == source;

  @override
  int get hashCode => Object.hash(value, source);
}

/// One actual resource/field-group entry changed by a producer.
final class ChangedFieldGroup {
  const ChangedFieldGroup({required this.resource, required this.name});

  factory ChangedFieldGroup.of(ResourceFieldGroup<Object?> group) =>
      ChangedFieldGroup(resource: group.resource, name: group.name);

  final ResourceKey resource;
  final String name;

  bool matches<T>(ResourceFieldGroup<T> group) =>
      resource == group.resource && name == group.name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChangedFieldGroup &&
          other.resource == resource &&
          other.name == name;

  @override
  int get hashCode => Object.hash(resource, name);
}

/// Atomic source-group metadata carried by every member change.
///
/// [changed] is producer-owned fact, not a notification hint. The runtime can
/// prepare only consumers affected by these entries and install all members
/// carrying this group identity together.
final class ConsistencyGroup {
  factory ConsistencyGroup({
    required ConsistencyGroupId id,
    required SourcePosition position,
    required Iterable<ChangedFieldGroup> changed,
  }) {
    final entries = Set<ChangedFieldGroup>.unmodifiable(changed);
    return ConsistencyGroup._(id: id, position: position, changed: entries);
  }

  ConsistencyGroup._({
    required this.id,
    required this.position,
    required Set<ChangedFieldGroup> changed,
  }) : changed = changed,
       changedKeys = Set<ResourceKey>.unmodifiable(
         changed.map((entry) => entry.resource),
       );

  final ConsistencyGroupId id;
  final SourcePosition position;
  final Set<ChangedFieldGroup> changed;
  final Set<ResourceKey> changedKeys;

  /// Alias for code that describes the entries as changed fields.
  Set<ChangedFieldGroup> get changedFields => changed;

  bool affects<T>(ResourceFieldGroup<T> group) =>
      changed.any((entry) => entry.matches(group));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConsistencyGroup &&
          other.id == id &&
          other.position == position &&
          _sameSet(other.changed, changed);

  @override
  int get hashCode => Object.hash(id, position, _setHash(changed));
}

/// One immutable value at a source position.
///
/// The value itself must be an immutable application value. This wrapper does
/// not deep-copy or content-hash it; unchanged values can therefore retain
/// their identity across source notifications.
final class ResourceSnapshot<T> {
  const ResourceSnapshot({
    required this.fieldGroup,
    required this.epoch,
    required this.version,
    required this.value,
    this.consistencyGroup,
  });

  final ResourceFieldGroup<T> fieldGroup;
  final SourceEpoch epoch;
  final SourceVersion version;
  final T value;
  final ConsistencyGroup? consistencyGroup;

  ResourceKey get resource => fieldGroup.resource;

  ResourceFieldGroup<T> get fields => fieldGroup;

  SourcePosition get position => SourcePosition(epoch: epoch, version: version);

  bool isNewerThan(ResourceSnapshot<T> other) =>
      fieldGroup == other.fieldGroup && position.isAfter(other.position);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResourceSnapshot<T> &&
          other.fieldGroup == fieldGroup &&
          other.epoch == epoch &&
          other.version == version &&
          other.value == value &&
          other.consistencyGroup == consistencyGroup;

  @override
  int get hashCode =>
      Object.hash(fieldGroup, epoch, version, value, consistencyGroup);
}

/// A source change whose base must match the installed snapshot position.
final class SourceChange<T> {
  const SourceChange({
    required this.snapshot,
    required this.base,
    required this.group,
    this.trace,
  });

  final ResourceSnapshot<T> snapshot;
  final SourcePosition base;
  final ConsistencyGroup group;
  final TraceContext? trace;

  SourcePosition get position => snapshot.position;

  bool get hasValidGroup =>
      snapshot.consistencyGroup == group &&
      group.position == position &&
      group.affects(snapshot.fieldGroup);

  bool matchesBase(ResourceSnapshot<T> installed) =>
      installed.fieldGroup == snapshot.fieldGroup &&
      installed.position == base &&
      base.isSameEpochAs(position) &&
      position.isAfter(base);
}

typedef SourceUpdate<T> = SourceChange<T>;
typedef ResourceDelta<T> = SourceChange<T>;

/// The result of opening a source: the initial value and one lossless update
/// stream from the same observation boundary.
final class SourceObservation<T> {
  const SourceObservation({required this.initial, required this.changes});

  final ResourceSnapshot<T> initial;
  final Stream<SourceChange<T>> changes;
}

/// Renderer-independent source port.
///
/// Implementations must establish the update subscription before taking the
/// initial read, or use an equivalent source-level atomic read/subscribe
/// boundary. A caller receives [SourceObservation.initial] and then listens to
/// [SourceObservation.changes] from that same boundary, so intermediate source
/// updates cannot be silently dropped.
abstract interface class PresentationSource<T> {
  ResourceFieldGroup<T> get fieldGroup;

  Future<SourceObservation<T>> open();
}

/// Observation-oriented spelling for source adapters.
extension PresentationSourceObservation<T> on PresentationSource<T> {
  Future<SourceObservation<T>> observe() => open();

  ResourceKey get resource => fieldGroup.resource;
}

typedef Source<T> = PresentationSource<T>;
typedef ResourceSource<T> = PresentationSource<T>;

/// Monotonic display request generation.
final class RequestGeneration {
  const RequestGeneration(this.value);

  final int value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RequestGeneration && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

typedef PresentationRequestGeneration = RequestGeneration;

/// Declared extent of one preparation attempt.
enum PreparationScope {
  /// Only the blocks the source reported as changed.
  incremental,

  /// The whole content revision, executed away from the rendering path.
  global,
}

/// Why one preparation attempt had to run.
enum PreparationTrigger {
  initial,
  blocksChanged,
  blockDependencyChanged,
  sourceReplaced,
  parserConfigChanged,
  cacheEvicted,
}

/// Recorded reason for one preparation attempt.
///
/// A global attempt is recorded rather than silent. It explains why the whole
/// revision was recomputed, and the runtime runs it off the rendering path
/// instead of inside a build.
final class PreparationCause {
  factory PreparationCause({
    required PreparationTrigger trigger,
    required PreparationScope scope,
    Set<BlockId> changed = const <BlockId>{},
  }) => PreparationCause._(
    trigger: trigger,
    scope: scope,
    changed: Set<BlockId>.unmodifiable(changed),
  );

  const PreparationCause._({
    required this.trigger,
    required this.scope,
    required this.changed,
  });

  final PreparationTrigger trigger;
  final PreparationScope scope;

  /// Blocks the source reported as changed for this attempt.
  final Set<BlockId> changed;

  bool get isGlobal => scope == PreparationScope.global;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparationCause &&
          other.trigger == trigger &&
          other.scope == scope &&
          _sameSet(other.changed, changed);

  @override
  int get hashCode => Object.hash(trigger, scope, _setHash(changed));

  @override
  String toString() => 'PreparationCause($trigger, $scope)';
}

/// Identity carried into an asynchronous presentation preparation.
final class PreparationRequest<T> {
  const PreparationRequest({
    required this.resource,
    required this.source,
    required this.generation,
    this.consistencyGroup,
    this.cause,
  });

  factory PreparationRequest.fromSnapshot({
    required ResourceSnapshot<T> snapshot,
    required RequestGeneration generation,
    PreparationCause? cause,
  }) => PreparationRequest<T>(
    resource: snapshot.fieldGroup,
    source: snapshot.position,
    generation: generation,
    consistencyGroup: snapshot.consistencyGroup,
    cause: cause,
  );

  final ResourceFieldGroup<T> resource;
  final SourcePosition source;
  final RequestGeneration generation;
  final ConsistencyGroup? consistencyGroup;

  /// Why this attempt runs, when the caller knows the reason.
  final PreparationCause? cause;

  ResourceKey get resourceKey => resource.resource;

  SourceEpoch get epoch => source.epoch;

  SourceVersion get version => source.version;

  bool matches(PreparationRequest<T> other) => this == other;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparationRequest<T> &&
          other.resource == resource &&
          other.source == source &&
          other.generation == generation &&
          other.consistencyGroup == consistencyGroup &&
          other.cause == cause;

  @override
  int get hashCode =>
      Object.hash(resource, source, generation, consistencyGroup, cause);
}

/// Pure result value from an asynchronous preparation step.
final class PreparedResource<T> {
  const PreparedResource({required this.request, required this.value});

  final PreparationRequest<T> request;
  final T value;

  T get prepared => value;
}

typedef PreparationResult<T> = PreparedResource<T>;

/// Identity of the parser implementation and its output semantics.
///
/// A parser change that can produce different output for the same content must
/// publish a new version; one that cannot must not.
final class ParserVersion {
  const ParserVersion(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ParserVersion && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ParserVersion($value)';
}

/// Semantic parser configuration.
///
/// Only settings that can change prepared output belong here. Colours, fonts,
/// density, and other renderer styling have no field in this type, so a
/// restyle cannot invalidate a prepared value, while a changed [revision] or
/// [features] set can.
final class SyntaxConfig {
  factory SyntaxConfig({
    required String revision,
    Iterable<String> features = const <String>[],
  }) => SyntaxConfig._(
    revision: revision,
    features: Set<String>.unmodifiable(features),
  );

  const SyntaxConfig._({required this.revision, required this.features});

  /// Opaque revision of the semantic configuration the parser was given.
  final String revision;

  /// Semantic features enabled for this configuration, such as `tables`.
  final Set<String> features;

  bool enables(String feature) => features.contains(feature);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyntaxConfig &&
          other.revision == revision &&
          _sameSet(other.features, features);

  @override
  int get hashCode => Object.hash(revision, _setHash(features));

  @override
  String toString() => 'SyntaxConfig($revision)';
}

/// Exactly which source content one preparation covers.
///
/// Content is a subset, not a whole document: an incremental attempt over
/// three changed blocks covers three blocks. Two attempts over different
/// subsets at the same source position are different preparations.
final class ContentRevision {
  factory ContentRevision({
    required ResourceKey resource,
    required SourcePosition position,
    required Iterable<SourceBlock> blocks,
  }) {
    final ordered = List<SourceBlock>.unmodifiable(blocks);
    final byId = <BlockId, SourceBlock>{};
    for (final block in ordered) {
      if (byId.containsKey(block.id)) {
        throw ArgumentError.value(
          block.id.value,
          'blocks',
          'duplicate block id in one content revision',
        );
      }
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
      byId[block.id] = block;
    }
    return ContentRevision._(
      resource: resource,
      position: position,
      blocks: ordered,
      byId: Map<BlockId, SourceBlock>.unmodifiable(byId),
    );
  }

  ContentRevision._({
    required this.resource,
    required this.position,
    required this.blocks,
    required Map<BlockId, SourceBlock> byId,
  }) : _byId = byId;

  final ResourceKey resource;
  final SourcePosition position;

  /// Covered blocks in source order.
  final List<SourceBlock> blocks;

  final Map<BlockId, SourceBlock> _byId;

  late final List<BlockId> blockIds = List<BlockId>.unmodifiable(
    blocks.map((block) => block.id),
  );

  SourceBlock? block(BlockId id) => _byId[id];

  bool covers(BlockId id) => _byId.containsKey(id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentRevision &&
          other.resource == resource &&
          other.position == position &&
          _sameList(other.blocks, blocks);

  @override
  int get hashCode => Object.hash(resource, position, Object.hashAll(blocks));

  @override
  String toString() => '$resource@$position[${blocks.length} blocks]';
}

/// Identity of one preparation: parser, semantic configuration, and content.
///
/// Two preparations with the same key produce the same prepared value, so the
/// key is the reuse identity a worker can trust. It carries no renderer input.
final class PreparationKey {
  const PreparationKey({
    required this.parserVersion,
    required this.syntaxConfig,
    required this.content,
  });

  final ParserVersion parserVersion;
  final SyntaxConfig syntaxConfig;
  final ContentRevision content;

  /// True when [previous] cannot be reused instead of preparing again.
  bool requiresRePreparation(PreparationKey? previous) => previous != this;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparationKey &&
          other.parserVersion == parserVersion &&
          other.syntaxConfig == syntaxConfig &&
          other.content == content;

  @override
  int get hashCode => Object.hash(parserVersion, syntaxConfig, content);

  @override
  String toString() => '$parserVersion/$syntaxConfig/$content';
}

/// One plain input a prepared value was computed from.
///
/// A preparation that reads another field group (a filter, a selected id, a
/// locale) declares it here, so a later change to that input invalidates the
/// prepared value without re-parsing the source.
final class PreparedInputReference {
  const PreparedInputReference({
    required this.resource,
    required this.name,
    this.position,
  });

  final ResourceKey resource;
  final String name;

  /// Position of the input when it was read, when the reader knows it.
  final SourcePosition? position;

  bool matches<T>(ResourceFieldGroup<T> group) =>
      resource == group.resource && name == group.name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparedInputReference &&
          other.resource == resource &&
          other.name == name &&
          other.position == position;

  @override
  int get hashCode => Object.hash(resource, name, position);

  @override
  String toString() => '$resource#$name';
}

/// One prepared block: its source identity plus the prepared payload.
final class PreparedBlock<T> {
  const PreparedBlock({required this.block, required this.value});

  final SourceBlock block;

  /// Prepared output for this block, in whatever compact form the preparation
  /// produced. Consumers render it without normalizing or tokenizing the
  /// source text again.
  final T value;

  BlockId get id => block.id;

  BlockVersion get version => block.version;

  SourceTextReference get text => block.text;

  bool get isSealed => block.isSealed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparedBlock<T> && other.block == block && other.value == value;

  @override
  int get hashCode => Object.hash(block, value);

  @override
  String toString() => 'PreparedBlock($id@$version)';
}

/// Immutable prepared output for one [PreparationKey].
///
/// [immutablePrefix] holds prepared blocks that will not change under the key:
/// their own text is sealed and every transitive dependency is sealed and
/// present here. [mutableTail] holds everything a later source version may
/// still change. A consumer can therefore reuse the prefix and re-render only
/// the tail, and recomputing the tail does not invalidate the prefix.
final class PreparedValue<T> {
  factory PreparedValue({
    required PreparationKey key,
    required Iterable<PreparedBlock<T>> immutablePrefix,
    required Iterable<PreparedBlock<T>> mutableTail,
    Iterable<PreparedInputReference> referencedInputs =
        const <PreparedInputReference>[],
  }) {
    final prefix = List<PreparedBlock<T>>.unmodifiable(immutablePrefix);
    final tail = List<PreparedBlock<T>>.unmodifiable(mutableTail);

    // Prefix and tail are subsets, not runs: an open block may sit between two
    // frozen ones, so the covered blocks are ordered by the content revision.
    final covered = key.content.blocks;
    final order = <BlockId, int>{
      for (var index = 0; index < covered.length; index++)
        covered[index].id: index,
    };
    final blocks = List<PreparedBlock<T>>.unmodifiable(
      <PreparedBlock<T>>[...prefix, ...tail]..sort(
        (left, right) =>
            (order[left.id] ?? -1).compareTo(order[right.id] ?? -1),
      ),
    );
    _checkPreparedBlocks<T>(key, prefix, blocks);
    return PreparedValue._(
      key: key,
      immutablePrefix: prefix,
      mutableTail: tail,
      blocks: blocks,
      referencedInputs: Set<PreparedInputReference>.unmodifiable(
        referencedInputs,
      ),
    );
  }

  /// Freezes every block that cannot change any more under [key].
  ///
  /// A block is frozen when it is sealed and every transitive dependency is
  /// sealed and covered by this same value. Everything else stays in the
  /// mutable tail, so an unresolved cross-block or cross-message reference
  /// keeps its dependent block out of the immutable prefix.
  factory PreparedValue.fromBlocks({
    required PreparationKey key,
    required Iterable<PreparedBlock<T>> blocks,
    Iterable<PreparedInputReference> referencedInputs =
        const <PreparedInputReference>[],
  }) {
    final ordered = List<PreparedBlock<T>>.unmodifiable(blocks);
    final stableIds = _stableBlockIds(key.content);
    final prefix = <PreparedBlock<T>>[];
    final tail = <PreparedBlock<T>>[];
    for (final block in ordered) {
      (stableIds.contains(block.id) ? prefix : tail).add(block);
    }
    return PreparedValue<T>(
      key: key,
      immutablePrefix: prefix,
      mutableTail: tail,
      referencedInputs: referencedInputs,
    );
  }

  const PreparedValue._({
    required this.key,
    required this.immutablePrefix,
    required this.mutableTail,
    required this.blocks,
    required this.referencedInputs,
  });

  final PreparationKey key;
  final List<PreparedBlock<T>> immutablePrefix;
  final List<PreparedBlock<T>> mutableTail;

  /// Plain inputs this preparation read.
  final Set<PreparedInputReference> referencedInputs;

  /// Every covered block, in source order, prefix and tail included.
  final List<PreparedBlock<T>> blocks;

  ContentRevision get content => key.content;

  ResourceKey get resource => key.content.resource;

  SourcePosition get position => key.content.position;

  /// Blocks this value covers, in source order.
  List<BlockId> get blockIds => key.content.blockIds;

  bool get isComplete => mutableTail.isEmpty;

  /// True when this value was prepared for [request]'s resource and position.
  bool matches(PreparationRequest<Object?> request) =>
      resource == request.resourceKey && position == request.source;

  bool dependsOn(BlockReference reference) =>
      blocks.any((block) => block.block.referencesBlock(reference));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreparedValue<T> &&
          other.key == key &&
          _sameList(other.blocks, blocks) &&
          _sameList(other.immutablePrefix, immutablePrefix) &&
          _sameList(other.mutableTail, mutableTail) &&
          _sameSet(other.referencedInputs, referencedInputs);

  @override
  int get hashCode => Object.hash(
    key,
    Object.hashAll(blocks),
    Object.hashAll(immutablePrefix),
    Object.hashAll(mutableTail),
    _setHash(referencedInputs),
  );

  @override
  String toString() =>
      'PreparedValue($key, ${immutablePrefix.length}+${mutableTail.length})';
}

/// The only lifecycle statuses that can make a prepared result ineligible.
enum PreparationStatus { active, revoked, disposed }

/// Current acceptance identity for one prepared result.
///
/// Rebuilds, source switches, and request recomputation create a different
/// [request]. Revocation and presentation disposal use [status]. Together
/// these checks keep an old async result from installing into a new display
/// owner without requiring a task or transport to be cancelled.
final class PreparationAcceptance<T> {
  const PreparationAcceptance({
    required this.request,
    this.status = PreparationStatus.active,
  });

  final PreparationRequest<T> request;
  final PreparationStatus status;

  bool get isActive => status == PreparationStatus.active;

  bool accepts(PreparedResource<T> result) =>
      isActive && result.request == request;

  bool canInstall(PreparedResource<T> result) => accepts(result);
}

/// Installation port implemented by the later presentation runtime.
///
/// A result keeps its [PreparationRequest], including its consistency-group
/// identity, until this port accepts and installs it atomically.
abstract interface class PresentationInstaller<T> {
  bool install(PreparedResource<T> result, PreparationAcceptance<T> acceptance);
}

/// Result of offering one member to a consistency group install.
enum GroupInstallOutcome {
  /// Accepted and staged; the group is not complete yet.
  staged,

  /// Accepted as the last missing member; the group is now installed.
  installed,

  /// Refused; nothing was staged or installed.
  rejected,
}

/// Atomic install gate for one consistency group.
///
/// Members are offered as their preparation finishes. Nothing becomes visible
/// until every changed field group has a member at the group's own position,
/// so a view never mixes two versions of one group. A group that is still
/// loading blocks only itself: [pending] is the local loading state, and a
/// group at another position installs through its own gate.
///
/// [revoke] and [dispose] take effect immediately, for members that were
/// already staged and for members that arrive later. Neither waits for the
/// group to complete, and a revoked or disposed gate hands out nothing.
final class ConsistencyGroupInstall<T> {
  ConsistencyGroupInstall(this.group);

  final ConsistencyGroup group;

  final Map<ResourceFieldGroup<T>, PreparedResource<T>> _members =
      <ResourceFieldGroup<T>, PreparedResource<T>>{};
  final Map<ResourceFieldGroup<T>, PreparedResource<T>> _installed =
      <ResourceFieldGroup<T>, PreparedResource<T>>{};
  PreparationStatus _status = PreparationStatus.active;

  ConsistencyGroupId get groupId => group.id;

  SourcePosition get position => group.position;

  PreparationStatus get status => _status;

  bool get isActive => _status == PreparationStatus.active;

  bool get isRevoked => _status == PreparationStatus.revoked;

  bool get isDisposed => _status == PreparationStatus.disposed;

  bool get isInstalled => _installed.isNotEmpty;

  /// Members accepted at [position] so far, by field group.
  Map<ResourceFieldGroup<T>, PreparedResource<T>> get staged =>
      Map<ResourceFieldGroup<T>, PreparedResource<T>>.unmodifiable(_members);

  /// The installed group, empty until the group completes.
  Map<ResourceFieldGroup<T>, PreparedResource<T>> get installed =>
      Map<ResourceFieldGroup<T>, PreparedResource<T>>.unmodifiable(_installed);

  /// Changed field groups with no member yet: local loading, not a global one.
  Set<ChangedFieldGroup> get pending {
    if (!isActive) return const <ChangedFieldGroup>{};
    return Set<ChangedFieldGroup>.unmodifiable(
      group.changed.where((changed) => !_members.keys.any(changed.matches)),
    );
  }

  /// True once every changed field group has a member from this position.
  bool get isComplete => isActive && _members.isNotEmpty && pending.isEmpty;

  void revoke() {
    _status = PreparationStatus.revoked;
    _members.clear();
    _installed.clear();
  }

  void dispose() {
    _status = PreparationStatus.disposed;
    _members.clear();
    _installed.clear();
  }

  /// Offers one member of this group.
  ///
  /// The result is staged only when it carries this group, this position, one
  /// of the changed field groups, and an acceptance that still allows it.
  GroupInstallOutcome offer(
    PreparedResource<T> result,
    PreparationAcceptance<T> acceptance,
  ) {
    if (!isActive || isInstalled) return GroupInstallOutcome.rejected;
    if (!acceptance.canInstall(result)) return GroupInstallOutcome.rejected;
    final request = result.request;
    if (request.consistencyGroup != group) return GroupInstallOutcome.rejected;
    if (request.source != group.position) return GroupInstallOutcome.rejected;
    if (!group.affects(request.resource)) return GroupInstallOutcome.rejected;

    final members = <ResourceFieldGroup<T>, PreparedResource<T>>{
      ..._members,
      request.resource: result,
    };
    _members
      ..clear()
      ..addAll(members);
    if (group.changed.any((changed) => !members.keys.any(changed.matches))) {
      return GroupInstallOutcome.staged;
    }

    _installed
      ..clear()
      ..addAll(members);
    return GroupInstallOutcome.installed;
  }
}

/// Presentation-only lifecycle controls.
///
/// These operations manage observation and rebuildable display state. They do
/// not stop Graph, PersistentTurn, transport, or other durable work owned by
/// the application.
abstract interface class PresentationLifecycle {
  void pause();

  void recompute();

  void dispose();
}

/// Scope captured when a renderer creates an action.
final class ActionOrigin {
  const ActionOrigin({required this.scope, this.resource});

  final ResourceScope scope;
  final ResourceKey? resource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionOrigin &&
          other.scope == scope &&
          other.resource == resource;

  @override
  int get hashCode => Object.hash(scope, resource);
}

typedef PresentationActionHandler<Action> =
    FutureOr<void> Function(Action action, ActionOrigin origin);

/// Typed renderer action port with a pinned originating scope.
abstract interface class PresentationActions<Action> {
  ActionOrigin get origin;

  FutureOr<void> dispatch(Action action);
}

/// Small pure-Dart adapter for an existing application facade callback.
final class CallbackActions<Action> implements PresentationActions<Action> {
  const CallbackActions({required this.origin, required this.onDispatch});

  @override
  final ActionOrigin origin;

  final PresentationActionHandler<Action> onDispatch;

  @override
  FutureOr<void> dispatch(Action action) => onDispatch(action, origin);
}

// No bare `Actions` alias: it would clash with Flutter's widgets.Actions in
// any file importing both libraries (ambiguous_export).

extension PresentationActionsSend<Action> on PresentationActions<Action> {
  FutureOr<void> send(Action action) => dispatch(action);
}

/// Host-compiled primitives a declarative contribution may bind to.
///
/// A contribution declares at most one primitive. When the running shell does
/// not provide it, the contribution is locally unavailable: the resource it
/// would have read keeps its identity, position, and consistency groups, so no
/// other feature re-reads or re-merges anything.
enum DeclarativePrimitive { form, table, chart, text, progress, command }

/// Ordinary data input for one third-party declarative contribution.
///
/// A contribution author declares plain immutable [inputs] plus typed
/// [actions]. Nothing here requires a component DSL, a provider, or a Flutter
/// dependency, and the host binds the value to a primitive it compiled rather
/// than to code the contribution supplies.
final class DeclarativeInput<Inputs, Action> {
  const DeclarativeInput({
    required this.contributionId,
    required this.primitive,
    required this.resource,
    required this.inputs,
    required this.actions,
    this.position,
  });

  /// Stable identity of the declaring contribution, not of one instance.
  final String contributionId;

  final DeclarativePrimitive primitive;

  final ResourceKey resource;

  /// Plain immutable application value; the contract never interprets it.
  final Inputs inputs;

  final PresentationActions<Action> actions;

  /// Prepared position the inputs came from, when the author knows it.
  final SourcePosition? position;

  ActionOrigin get origin => actions.origin;

  bool isSupportedBy(Iterable<DeclarativePrimitive> availablePrimitives) =>
      availablePrimitives.contains(primitive);

  /// Null while the shell provides [primitive]; otherwise the local reason.
  DeclarativeUnavailable? unavailableGiven(
    Iterable<DeclarativePrimitive> availablePrimitives,
  ) => isSupportedBy(availablePrimitives)
      ? null
      : DeclarativeUnavailable(
          contributionId: contributionId,
          primitive: primitive,
          resource: resource,
        );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeclarativeInput<Inputs, Action> &&
          other.contributionId == contributionId &&
          other.primitive == primitive &&
          other.resource == resource &&
          other.inputs == inputs &&
          other.actions == actions &&
          other.position == position;

  @override
  int get hashCode => Object.hash(
    contributionId,
    primitive,
    resource,
    inputs,
    actions,
    position,
  );

  @override
  String toString() => 'DeclarativeInput($contributionId, ${primitive.name})';
}

/// A contribution whose primitive the running shell does not provide.
///
/// This is a local result: the contribution shows its own unavailable state
/// while the prepared data it would have read stays untouched.
final class DeclarativeUnavailable {
  const DeclarativeUnavailable({
    required this.contributionId,
    required this.primitive,
    this.resource,
  });

  final String contributionId;
  final DeclarativePrimitive primitive;
  final ResourceKey? resource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeclarativeUnavailable &&
          other.contributionId == contributionId &&
          other.primitive == primitive &&
          other.resource == resource;

  @override
  int get hashCode => Object.hash(contributionId, primitive, resource);

  @override
  String toString() =>
      'DeclarativeUnavailable($contributionId, ${primitive.name})';
}

/// Read-only projected state exposed to an existing renderer.
///
/// This pre-F01 source shape remains available while features migrate to
/// [PresentationSource].
abstract interface class ProjectionSource<T> {
  T get current;

  Stream<ProjectionUpdate<T>> get changes;
}

/// One immutable projected value and its optional renderer-local cause.
final class ProjectionUpdate<T> {
  const ProjectionUpdate(this.value, {this.trace});

  final T value;
  final TraceContext? trace;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectionUpdate<T> &&
          other.value == value &&
          other.trace == trace;

  @override
  int get hashCode => Object.hash(value, trace);
}

/// Non-replayed, one-shot effects exposed to a renderer.
abstract interface class EffectSource<E> {
  Stream<E> get effects;
}

/// Fire-and-forget semantic input accepted from a renderer.
abstract interface class IntentSink<I> {
  void send(I intent);
}

/// Optional opaque local causal context carried across presentation operations.
final class TraceContext {
  const TraceContext({this.traceId});

  final String? traceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraceContext && other.traceId == traceId;

  @override
  int get hashCode => traceId.hashCode;
}

void _checkPreparedBlocks<T>(
  PreparationKey key,
  List<PreparedBlock<T>> prefix,
  List<PreparedBlock<T>> blocks,
) {
  final covered = key.content.blocks;
  if (covered.length != blocks.length) {
    throw ArgumentError.value(
      blocks.length,
      'blocks',
      'a prepared value must cover exactly key.content.blocks '
          '(${covered.length} covered)',
    );
  }

  for (var index = 0; index < blocks.length; index++) {
    final prepared = blocks[index];
    if (prepared.block != covered[index]) {
      throw ArgumentError.value(
        prepared.block.id.value,
        'blocks',
        'prepared block does not match key.content.blocks at index $index',
      );
    }
  }

  final stableIds = _stableBlockIds(key.content);
  for (final prepared in prefix) {
    if (!stableIds.contains(prepared.id)) {
      throw ArgumentError.value(
        prepared.block.id.value,
        'immutablePrefix',
        'an unsealed block or unresolved dependency cannot be immutable',
      );
    }
  }
}

Set<BlockId> _stableBlockIds(ContentRevision content) {
  final dependents = <BlockId, List<BlockId>>{};
  final unstable = <BlockId>{};
  for (final block in content.blocks) {
    if (!block.isSealed) unstable.add(block.id);
    for (final reference in block.references) {
      if (reference.resource != content.resource ||
          !content.covers(reference.blockId)) {
        unstable.add(block.id);
      } else {
        (dependents[reference.blockId] ??= <BlockId>[]).add(block.id);
      }
    }
  }

  // Propagate instability backwards once per block/edge. This also handles
  // cycles without recursive traversal or repeated whole-document scans.
  final pending = unstable.toList();
  for (var index = 0; index < pending.length; index++) {
    for (final dependent in dependents[pending[index]] ?? const <BlockId>[]) {
      if (unstable.add(dependent)) pending.add(dependent);
    }
  }
  return <BlockId>{
    for (final block in content.blocks)
      if (!unstable.contains(block.id)) block.id,
  };
}

bool _sameList<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameSet<T>(Set<T> left, Set<T> right) {
  if (left.length != right.length) return false;
  return left.every(right.contains);
}

int _setHash<T>(Set<T> values) {
  var result = 0;
  for (final value in values) {
    result ^= value.hashCode;
  }
  return result;
}
