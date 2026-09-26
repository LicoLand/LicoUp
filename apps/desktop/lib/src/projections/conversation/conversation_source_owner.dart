import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

/// One plane's source binding.
///
/// The binding object is stable for the app scope: every producer value is a
/// new version of the same resource, and an explicit re-read after a
/// withdrawal opens a fresh incarnation at a new epoch, so nothing admitted
/// from the withdrawn incarnation can install again.
final class ConversationPlaneSource<T> implements PresentationSource<T> {
  ConversationPlaneSource({
    required this.fieldGroup,
    required T initial,
    required SourceEpoch epoch,
  }) : _current = ResourceSnapshot<T>(
         fieldGroup: fieldGroup,
         epoch: epoch,
         version: const SourceVersion(0),
         value: initial,
         consistencyGroup: _groupAt(
           fieldGroup,
           SourcePosition(epoch: epoch, version: const SourceVersion(0)),
         ),
       );

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final StreamController<SourceChange<T>> _changes =
      StreamController<SourceChange<T>>.broadcast(sync: true);
  ResourceSnapshot<T> _current;
  bool _disposed = false;

  /// The revision this binding currently holds.
  T get current => _current.value;

  ResourceSnapshot<T> get snapshot => _current;

  SourcePosition get position => _current.position;

  /// Publishes [value] as the next revision of this plane.
  bool publish(T value) {
    if (_disposed || _current.value == value) return false;
    final previous = _current;
    final position = SourcePosition(
      epoch: previous.epoch,
      version: SourceVersion(previous.version.value + 1),
    );
    final group = _groupAt(fieldGroup, position);
    final snapshot = ResourceSnapshot<T>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: value,
      consistencyGroup: group,
    );
    _current = snapshot;
    if (_changes.hasListener) {
      _changes.add(
        SourceChange<T>(
          snapshot: snapshot,
          base: previous.position,
          group: group,
        ),
      );
    }
    return true;
  }

  /// Opens a fresh incarnation of this plane at [epoch].
  void reopen({required SourceEpoch epoch, required T value}) {
    if (_disposed) return;
    final position = SourcePosition(
      epoch: epoch,
      version: const SourceVersion(0),
    );
    _current = ResourceSnapshot<T>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: value,
      consistencyGroup: _groupAt(fieldGroup, position),
    );
  }

  @override
  Future<SourceObservation<T>> open() async =>
      SourceObservation<T>(initial: _current, changes: _changes.stream);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }

  static ConsistencyGroup _groupAt(
    ResourceFieldGroup<Object?> fieldGroup,
    SourcePosition position,
  ) => ConsistencyGroup(
    id: ConsistencyGroupId(
      'conversation-plane:${fieldGroup.resource.stableKey}',
    ),
    position: position,
    changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
  );
}

/// One conversation plane admitted by the runtime.
final class ConversationPlaneRuntime<T> implements ConversationPlanePort<T> {
  ConversationPlaneRuntime({
    required this.owner,
    required this.planeName,
    required this.fieldGroup,
    required ProjectionSource<T> producer,
  }) : _producer = producer {
    _source = ConversationPlaneSource<T>(
      fieldGroup: fieldGroup,
      initial: producer.current,
      epoch: owner._newEpoch(),
    );
    _ownership = owner.runtime.own(_source);
    _observation = _ownership.subscribe().stream.listen(
      _onSnapshot,
      onError: (Object _) {
        // An observation error is a lifecycle fact; the owner reflects the
        // authority withdrawal through the runtime's own invalidation signal.
        _observation = null;
      },
    );
    _producerSubscription = producer.changes.listen(_onProducerUpdate);
  }

  final ConversationSourceOwner owner;
  final String planeName;

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ProjectionSource<T> _producer;
  late final ConversationPlaneSource<T> _source;
  late final SourceOwnership<T> _ownership;
  StreamSubscription<ResourceSnapshot<T>>? _observation;
  late final StreamSubscription<ProjectionUpdate<T>> _producerSubscription;
  final StreamController<ConversationPlaneRead<T>> _reads =
      StreamController<ConversationPlaneRead<T>>.broadcast(sync: true);
  T? _visible;
  ConversationPlaneWithdrawal? _withdrawn;
  bool _disposed = false;
  int _incarnations = 1;

  /// How many incarnations this plane opened. Evidence that a withdrawn plane
  /// recovers only through a re-read; a rebuild never opens another one.
  int get incarnations => _incarnations;

  @override
  T? get visibleValue => _visible;

  @override
  Stream<ConversationPlaneRead<T>> get reads => _reads.stream;

  @override
  void reconnect() {
    if (_disposed) return;
    _withdrawn = null;
    _incarnations++;
    // The provider's current value is admitted in a fresh incarnation, so
    // everything derived from the withdrawn one can never install again.
    _source.reopen(epoch: owner._newEpoch(), value: _producer.current);
    unawaited(_ownership.reconnect());
  }

  void _onProducerUpdate(ProjectionUpdate<T> update) {
    if (_disposed || _withdrawn != null) return;
    _source.publish(update.value);
  }

  void _onSnapshot(ResourceSnapshot<T> snapshot) {
    if (_disposed || _withdrawn != null) return;
    _visible = snapshot.value;
    if (_reads.hasListener) {
      _reads.add(ConversationPlaneVisible<T>(snapshot.value));
    }
  }

  void withdraw(
    ConversationPlaneWithdrawal reason, {
    bool revokeRuntime = true,
  }) {
    if (_disposed || _withdrawn != null) return;
    _withdrawn = reason;
    _visible = null;
    if (revokeRuntime) {
      owner.runtime.revoke(fieldGroup.resource);
    }
    if (_reads.hasListener) {
      _reads.add(ConversationPlaneWithdrawn<T>(reason));
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_withdrawn == null) {
      _withdrawn = ConversationPlaneWithdrawal.scopeEnded;
      _visible = null;
      if (_reads.hasListener) {
        _reads.add(
          ConversationPlaneWithdrawn<T>(ConversationPlaneWithdrawal.scopeEnded),
        );
      }
    }
    unawaited(_producerSubscription.cancel());
    final observation = _observation;
    _observation = null;
    if (observation != null) unawaited(observation.cancel());
    owner.runtime.revoke(fieldGroup.resource);
    unawaited(_ownership.release());
    unawaited(_reads.close());
    _source.dispose();
  }
}

/// Application-scope owner of the conversation plane sources.
///
/// One instance per container wraps the projection producer's channels into
/// runtime sources: the initial channel value is admitted immediately, every
/// later channel value is admitted as a new version, and an application
/// authority withdrawal makes the affected plane invisible until an explicit
/// re-read. The producer stays the single source of truth; the owner never
/// rebuilds plane content and never re-derives conversation state.
final class ConversationSourceOwner implements ConversationSourcePort {
  ConversationSourceOwner({required this.runtime, required this.planes}) {
    runtime.onSourceInvalidated(_onSourceInvalidated);
    projection = _plane<ConversationProjection>(
      conversationPlaneProjection,
      planes.projection,
    );
    nativeCatalog = _plane<NativeConversationCatalogProjection>(
      conversationPlaneNativeCatalog,
      planes.nativeCatalog,
    );
    canonicalEvents = _plane<CanonicalConversationProjection>(
      conversationPlaneCanonicalEvents,
      planes.canonicalEvents,
    );
    persistentTurns = _plane<PersistentTurnProjection>(
      conversationPlanePersistentTurns,
      planes.persistentTurns,
    );
    composer = _plane<ComposerProjection>(
      conversationPlaneComposer,
      planes.composer,
    );
    attachments = _plane<ConversationAttachmentsProjection>(
      conversationPlaneAttachments,
      planes.attachments,
    );
    tabActivity = _plane<ConversationTabActivityProjection>(
      conversationPlaneTabActivity,
      planes.tabActivity,
    );
    archive = _plane<ConversationArchiveProjection>(
      conversationPlaneArchive,
      planes.archive,
    );
    final producerExecution = planes.execution;
    execution = producerExecution == null
        ? null
        : _plane<ConversationExecutionProjection>(
            conversationPlaneExecution,
            producerExecution,
          );
  }

  /// The production entry: one plane owner for one container's runtime.
  ///
  /// The caller owns the returned instance and must dispose it when the
  /// container ends.
  static ConversationSourceOwner spawn({
    required PresentationRuntime runtime,
    required ConversationSourcePlanes planes,
  }) => ConversationSourceOwner(runtime: runtime, planes: planes);

  final PresentationRuntime runtime;
  final ConversationSourcePlanes planes;
  final Map<String, ConversationPlaneRuntime<Object?>> _planes =
      <String, ConversationPlaneRuntime<Object?>>{};
  int _epochSeed = 0;
  Future<void>? _disposal;
  bool _disposed = false;

  bool get disposed => _disposed;

  @override
  late final ConversationPlanePort<ConversationProjection> projection;
  @override
  late final ConversationPlanePort<NativeConversationCatalogProjection>
  nativeCatalog;
  @override
  late final ConversationPlanePort<CanonicalConversationProjection>
  canonicalEvents;
  @override
  late final ConversationPlanePort<PersistentTurnProjection> persistentTurns;
  @override
  late final ConversationPlanePort<ComposerProjection> composer;
  @override
  late final ConversationPlanePort<ConversationAttachmentsProjection>
  attachments;
  @override
  late final ConversationPlanePort<ConversationTabActivityProjection>
  tabActivity;
  @override
  late final ConversationPlanePort<ConversationArchiveProjection> archive;
  @override
  late final ConversationPlanePort<ConversationExecutionProjection>? execution;

  /// Withdraws one plane as an application authority decision.
  void withdraw(
    String planeName,
    ConversationPlaneWithdrawal reason, {
    bool revokeRuntime = true,
  }) {
    final plane = _planes[planeName];
    if (plane == null) return;
    plane.withdraw(reason, revokeRuntime: revokeRuntime);
  }

  /// Re-reads one plane after a withdrawal.
  void reconnect(String planeName) => _planes[planeName]?.reconnect();

  /// Releases every plane and its producer subscriptions.
  ///
  /// Idempotent. The runtime stays owned by its own provider.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    for (final plane in List<ConversationPlaneRuntime<Object?>>.of(
      _planes.values,
    )) {
      plane.dispose();
    }
    _planes.clear();
  }

  ConversationPlaneRuntime<T> _plane<T>(
    String planeName,
    ProjectionSource<T> producer,
  ) {
    final existing = _planes[planeName];
    if (existing != null) {
      return existing as ConversationPlaneRuntime<T>;
    }
    final plane = ConversationPlaneRuntime<T>(
      owner: this,
      planeName: planeName,
      fieldGroup: conversationPlaneFieldGroupFor<T>(planeName),
      producer: producer,
    );
    _planes[planeName] = plane as ConversationPlaneRuntime<Object?>;
    return plane;
  }

  SourceEpoch _newEpoch() => SourceEpoch('conversation-plane-${_epochSeed++}');

  void _onSourceInvalidated(SourceInvalidation invalidation) {
    if (_disposed) return;
    if (invalidation.reason != SourceInvalidationReason.revoked) return;
    for (final plane in List<ConversationPlaneRuntime<Object?>>.of(
      _planes.values,
    )) {
      if (plane.fieldGroup.resource != invalidation.resource) continue;
      plane.withdraw(ConversationPlaneWithdrawal.revoked, revokeRuntime: false);
    }
  }
}
