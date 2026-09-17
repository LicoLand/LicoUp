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

/// Identity carried into an asynchronous presentation preparation.
final class PreparationRequest<T> {
  const PreparationRequest({
    required this.resource,
    required this.source,
    required this.generation,
    this.consistencyGroup,
  });

  factory PreparationRequest.fromSnapshot({
    required ResourceSnapshot<T> snapshot,
    required RequestGeneration generation,
  }) => PreparationRequest<T>(
    resource: snapshot.fieldGroup,
    source: snapshot.position,
    generation: generation,
    consistencyGroup: snapshot.consistencyGroup,
  );

  final ResourceFieldGroup<T> resource;
  final SourcePosition source;
  final RequestGeneration generation;
  final ConsistencyGroup? consistencyGroup;

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
          other.consistencyGroup == consistencyGroup;

  @override
  int get hashCode =>
      Object.hash(resource, source, generation, consistencyGroup);
}

/// Pure result value from an asynchronous preparation step.
final class PreparedResource<T> {
  const PreparedResource({required this.request, required this.value});

  final PreparationRequest<T> request;
  final T value;

  T get prepared => value;
}

typedef PreparationResult<T> = PreparedResource<T>;

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

typedef Actions<Action> = PresentationActions<Action>;

extension PresentationActionsSend<Action> on PresentationActions<Action> {
  FutureOr<void> send(Action action) => dispatch(action);
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
