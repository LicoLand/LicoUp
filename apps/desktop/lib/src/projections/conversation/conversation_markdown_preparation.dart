import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_presentation_source.dart';

/// Creates the engine that runs conversation markdown preparation.
///
/// Production passes a measured worker pool; a test passes an engine it can
/// inspect, so the same pipeline is exercised with real isolates and with
/// scripted ones.
typedef MarkdownPreparationEngineFactory =
    Future<MarkdownPreparationEngine> Function();

/// Field group a message body's prepared value is installed as.
const String conversationMarkdownPreparedField = 'preparedBody';

ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>>
_conversationMarkdownPreparedFieldFor(String identity) =>
    ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>>(
      resource: conversationMarkdownFieldGroupFor(identity).resource,
      name: conversationMarkdownPreparedField,
    );

/// Application-scope prepared pipeline for conversation message bodies.
///
/// This is the implementation behind [ConversationMarkdownPort]. It owns the
/// message body bindings, the runtime admission subscription, the off-thread
/// markdown engine and its worker pool, and the bounded retention of prepared
/// values; composition binds one instance per container through the port.
///
/// One message body is one source resource. A published revision is admitted
/// by the presentation runtime, decomposed and parsed off-thread by the
/// markdown engine, and offered to the runtime's prepared display, which owns
/// consistency-group installation and revocation. The pipeline itself holds no
/// parse result of its own: [valueFor] reads the installed value, so a
/// withdrawn value cannot be shown from a second copy.
///
/// A view only publishes the narrow input it holds and watches one identity, so
/// a streaming reply never rebuilds or re-prepares another message.
final class ConversationMarkdownPreparation
    implements ConversationMarkdownPort {
  ConversationMarkdownPreparation({
    required this.runtime,
    MarkdownPreparationEngineFactory? engineFactory,
    ConversationMarkdownSourceRegistry? registry,
    this.maxRetainedBodies = 512,
  }) : _engineFactory =
           engineFactory ??
           (() => MarkdownPreparationEngine.spawnMeasured(
             name: 'conversation-markdown',
           )),
       registry = registry ?? ConversationMarkdownSourceRegistry() {
    // Authority withdrawal is an application fact this owner has to reflect:
    // the runtime withdraws the derived values first, then tells the scope.
    runtime.onSourceInvalidated(_onSourceInvalidated);
  }

  /// The production entry: one measured worker pool for this container.
  ///
  /// The caller owns the returned instance and must dispose it when the
  /// container ends, so the worker isolates are stopped with the scope.
  static ConversationMarkdownPreparation spawn({
    required PresentationRuntime runtime,
    int maxRetainedBodies = 512,
  }) => ConversationMarkdownPreparation(
    runtime: runtime,
    maxRetainedBodies: maxRetainedBodies,
  );

  final PresentationRuntime runtime;
  final ConversationMarkdownSourceRegistry registry;

  /// Bodies kept after they stop being watched. The least recently published
  /// unwatched body is withdrawn first, so a long session does not retain
  /// prepared values for a history nobody is showing.
  final int maxRetainedBodies;

  final MarkdownPreparationEngineFactory _engineFactory;
  final Map<String, _PreparedBody> _bodies = <String, _PreparedBody>{};
  MarkdownPreparationEngine? _engineReady;
  Future<void>? _disposal;
  int _published = 0;
  bool _disposed = false;

  bool get disposed => _disposed;

  /// The installed prepared value of one message body, when one is visible.
  ///
  /// The value is the runtime display's current install, so a revoked or
  /// superseded value never appears here.
  PreparedValue<MessageMarkdownBlock>? valueFor(String identity) =>
      _bodies[identity]?.value;

  /// The revision position one body currently holds, when it was published.
  SourcePosition? positionFor(String identity) =>
      registry.sourceFor(identity)?.position;

  /// What the last completed preparation attempt did for one body.
  MarkdownPreparationPlan? planFor(String identity) => _bodies[identity]?.plan;

  /// Which worker isolate produced the last off-thread scan of one body.
  PreparationWorkerIdentity? workerFor(String identity) =>
      _bodies[identity]?.worker;

  /// How many preparation attempts were started for one body.
  ///
  /// Evidence for the view contract: a restyle or a rebuild must not increase
  /// this count, while a real text revision must.
  int preparationsFor(String identity) => _bodies[identity]?.preparations ?? 0;

  /// The failure that stopped the last attempt for one body, when one did.
  Object? failureFor(String identity) => _bodies[identity]?.failure;

  /// The state of one message body, for a synchronous read in build.
  @override
  ConversationMarkdownBodyState stateFor(String identity) {
    final body = _bodies[identity];
    if (body == null) return const ConversationMarkdownPreparing();
    final withdrawn = body.withdrawn;
    if (withdrawn != null) return ConversationMarkdownWithdrawn(withdrawn);
    final value = body.value;
    if (value != null) return ConversationMarkdownInstalled(value);
    return const ConversationMarkdownPreparing();
  }

  /// Subscribes [listener] to one body's state changes.
  ///
  /// Returns the release function for this subscription. The listener is
  /// called only for later events; the current state is read with [stateFor].
  @override
  void Function() watch(
    String identity,
    void Function(ConversationMarkdownBodyState state) listener,
  ) {
    final body = _bodyFor(identity);
    body.listeners.add(listener);
    return () => body.listeners.remove(listener);
  }

  /// Publishes the text a view currently holds for one message body.
  ///
  /// Returns the position the body is at after this call, or null when the
  /// pipeline was disposed. A view compares the position of an installed value
  /// with this position, so a value prepared from an older revision of the
  /// same body is never rendered against newer text.
  ///
  /// A body that was withdrawn re-enters preparation only through a controlled
  /// new read: a later revision, or a retired body opening a fresh epoch. The
  /// revision a revocation was recorded for never re-enters by itself.
  @override
  SourcePosition? publish({
    required String identity,
    required String text,
    String conversationId = '',
  }) {
    if (_disposed) return null;
    final body = _bodyFor(identity);
    if (conversationId.isNotEmpty) body.conversationId = conversationId;
    final withdrawn = body.withdrawn;
    if (withdrawn != null) {
      if (withdrawn == ConversationMarkdownWithdrawal.revoked &&
          body.lastText == text) {
        // The withdrawn revision must not re-enter preparation from a repeated
        // read; only a later controlled revision may open a fresh incarnation.
        return registry.sourceFor(identity)?.position;
      }
      // A new revision - or a retired body coming back - is a fresh read:
      // reopen the binding in a new epoch so nothing prepared from the
      // withdrawn incarnation can install, then clear the withdrawal.
      registry.retire(identity);
      body.withdrawn = null;
      _notifyState(body, const ConversationMarkdownPreparing());
    }
    final changed = registry.publish(
      identity: identity,
      text: text,
      conversationId: conversationId,
    );
    body.lastText = text;
    if (changed == null) {
      // The revision is already held. A body whose source was retired while a
      // view still shows it is re-attached here, so the view recovers its
      // prepared value instead of staying on the unprepared text.
      _attach(body, registry.sourceFor(identity));
      return registry.sourceFor(identity)?.position;
    }
    body.lastPublished = ++_published;
    _attach(body, changed);
    _enforceRetention();
    return changed.position;
  }

  /// Withdraws one body as a bounded-retention decision.
  ///
  /// In-flight work is cancelled, the source lease is released, and the
  /// runtime stops showing anything prepared from it. The input text is not
  /// authority-withdrawn, so a later controlled read may prepare it again.
  void retire(String identity) {
    registry.retire(identity);
    final body = _bodies[identity];
    if (body == null) return;
    _withdrawBody(body, ConversationMarkdownWithdrawal.retired);
  }

  /// Withdraws every body published under [conversationId].
  void retireConversation(String conversationId) {
    for (final identity in List<String>.of(_bodies.keys)) {
      if (_bodies[identity]?.conversationId != conversationId) continue;
      retire(identity);
    }
  }

  /// Releases every body, the registry, and the worker pool.
  ///
  /// Idempotent. The returned future completes once the worker pool has
  /// stopped, so a container that disposes this owner can await the isolates
  /// ending with the scope.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    for (final body in List<_PreparedBody>.of(_bodies.values)) {
      registry.retire(body.identity);
      _withdrawBody(body, ConversationMarkdownWithdrawal.scopeEnded);
    }
    registry.clear();
    final ready = _engineReady;
    _engineReady = null;
    if (ready != null) {
      await _stopWorkers(ready);
    } else {
      // The pool may still be coming up. Its completion path stops it when the
      // owner is already disposed; awaiting it here keeps the disposal future
      // honest about the isolates having ended.
      final pending = _pendingEngine;
      _pendingEngine = null;
      if (pending != null) {
        try {
          await pending;
        } on Object {
          // A pool that failed to come up has nothing to stop.
        }
      }
    }
    registry.dispose();
  }

  Future<void> _stopWorkers(MarkdownPreparationEngine engine) async {
    try {
      await engine.workers.dispose();
    } on Object {
      // Stopping a pool that is already stopping is not a failure.
    }
  }

  _PreparedBody _bodyFor(String identity) =>
      _bodies.putIfAbsent(identity, () => _PreparedBody(identity));

  void _attach(_PreparedBody body, ConversationMarkdownSource? source) {
    if (source == null || body.ownership != null || _disposed) return;
    final ownership = runtime.own(source);
    body.ownership = ownership;
    body.observation = ownership.subscribe().stream.listen(
      (snapshot) => _onSnapshot(body, snapshot),
      onError: (Object _) {
        // An observation error is a source-lifecycle fact; the view keeps the
        // text it already holds and the next publish re-attaches on a fresh
        // lease instead of holding a lease on a revoked observation.
        final ownership = body.ownership;
        body.observation = null;
        body.ownership = null;
        unawaited(ownership?.release());
      },
    );
    // A publish that raced the opening is not lost: once the initial admission
    // has settled, a binding that is already ahead of it is read again, so the
    // current revision still enters admission before anything is prepared.
    scheduleMicrotask(() {
      if (_disposed || body.ownership != ownership) return;
      final admitted = ownership.current?.position;
      if (admitted == null ||
          admitted.compare(source.position) == VersionRelation.older) {
        unawaited(ownership.reconnect());
      }
    });
  }

  void _onSnapshot(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> snapshot,
  ) {
    if (_disposed) return;
    final revision = body.revision;
    if (revision != null &&
        revision.position.epoch == snapshot.position.epoch &&
        revision.position.compare(snapshot.position) != VersionRelation.older) {
      return;
    }
    body.cancel?.cancel(PreparationCancellationReason.superseded);
    final token = PreparationCancellationToken();
    body.cancel = token;
    body.preparations++;
    unawaited(_prepare(body, snapshot, token));
  }

  Future<void> _prepare(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> snapshot,
    PreparationCancellationToken token,
  ) async {
    try {
      final display = runtime
          .preparedDisplay<PreparedValue<MessageMarkdownBlock>>();
      final outcome = await display.prepareAndOffer(
        snapshot: _preparedSnapshot(body, snapshot),
        generation: RequestGeneration(snapshot.version.value),
        operation: () => _runPreparation(body, snapshot, token),
        estimatedBytes: snapshot.value.text.length,
        priority: PreparationPriority.foreground,
      );
      if (token.isCancelled || _disposed) return;
      if (outcome == GroupInstallOutcome.rejected) {
        // A superseded position or a withdrawn source: the previous value stays
        // visible and this result installs nowhere.
        return;
      }
      final installed = display.current(body.preparedField)?.value;
      if (installed != null) _install(body, installed);
    } on PreparationCancelledException {
      // Superseded work stays silent: a newer revision owns the body now.
    } on Object catch (error) {
      if (token.isCancelled || _disposed) return;
      body.failure = error;
    }
  }

  /// The real CPU work of one attempt, run inside the display's bounded
  /// executor: decompose off-thread, then parse only what the plan requires.
  Future<PreparedValue<MessageMarkdownBlock>> _runPreparation(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> snapshot,
    PreparationCancellationToken token,
  ) async {
    final engine = await _engine();
    if (token.isCancelled) {
      throw PreparationCancelledException(
        token.reason ?? PreparationCancellationReason.superseded,
        stage: 'queued',
      );
    }
    final scan = await engine.decompose(
      resource: snapshot.resource,
      position: snapshot.position,
      text: snapshot.value.text,
      previous: _reusableRevision(body, snapshot),
      cancel: token,
      onWorker: (identity) => body.worker = identity,
    );
    body.revision = scan.revision;
    final prepared = await engine.prepare(
      MarkdownPreparationRequest(
        preparedField: body.preparedField,
        revision: scan.revision,
        generation: RequestGeneration(snapshot.version.value),
        consistencyGroup: snapshot.consistencyGroup,
      ),
      cancel: token,
    );
    body.plan = prepared.plan;
    return prepared.value;
  }

  /// The install identity of one attempt.
  ///
  /// The prepared field group is installed at the source position that was
  /// read, carrying the source's consistency group identity. That identity is
  /// preserved as-is while its changed entry names the field this preparation
  /// produces, because a group installs the fields it was offered, not the raw
  /// field the value was read from. The value slot carries the revision
  /// currently installed - or an empty placeholder for the first attempt -
  /// because a preparation request is built from the field group, position, and
  /// group identity, never from the value being replaced.
  ResourceSnapshot<PreparedValue<MessageMarkdownBlock>> _preparedSnapshot(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> source,
  ) => ResourceSnapshot<PreparedValue<MessageMarkdownBlock>>(
    fieldGroup: body.preparedField,
    epoch: source.epoch,
    version: source.version,
    value: body.value ?? _emptyPreparedValue(source),
    consistencyGroup: _preparedGroup(body, source),
  );

  ConsistencyGroup? _preparedGroup(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> source,
  ) {
    final group = source.consistencyGroup;
    if (group == null) return null;
    return ConsistencyGroup(
      id: group.id,
      position: group.position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body.preparedField)],
    );
  }

  PreparedValue<MessageMarkdownBlock> _emptyPreparedValue(
    ResourceSnapshot<ConversationMarkdownBody> source,
  ) => PreparedValue<MessageMarkdownBlock>(
    key: PreparationKey(
      parserVersion: defaultMarkdownParserVersion,
      syntaxConfig: defaultMarkdownSyntaxConfig,
      content: ContentRevision(
        resource: source.resource,
        position: source.position,
        blocks: const <SourceBlock>[],
      ),
    ),
    immutablePrefix: const <PreparedBlock<MessageMarkdownBlock>>[],
    mutableTail: const <PreparedBlock<MessageMarkdownBlock>>[],
  );

  /// The revision a new decomposition may carry block identity from.
  ///
  /// Only an older position of the same epoch can donate identity; a new epoch
  /// is a rebuilt source whose block identities do not carry over.
  MessageMarkdownDecomposition? _reusableRevision(
    _PreparedBody body,
    ResourceSnapshot<ConversationMarkdownBody> snapshot,
  ) {
    final revision = body.revision;
    if (revision == null) return null;
    if (revision.position.epoch != snapshot.position.epoch) return null;
    return revision.position.compare(snapshot.position) == VersionRelation.older
        ? revision
        : null;
  }

  void _install(_PreparedBody body, PreparedValue<MessageMarkdownBlock> value) {
    // A withdrawn body installs nothing: a result that arrives after the
    // withdrawal belongs to the revision that was withdrawn.
    if (body.withdrawn != null) return;
    body.failure = null;
    if (identical(body.value, value)) return;
    body.value = value;
    _notifyState(body, ConversationMarkdownInstalled(value));
  }

  /// Records one withdrawal and makes it visible.
  ///
  /// [revokeRuntime] is false when the runtime already withdrew authority: the
  /// application withdrew it and this owner only reflects the fact.
  void _withdrawBody(
    _PreparedBody body,
    ConversationMarkdownWithdrawal reason, {
    bool revokeRuntime = true,
  }) {
    if (body.withdrawn != null) return;
    // Record the reason first: an owner-initiated revoke also notifies the
    // runtime's invalidation listeners, and this body must not be re-labelled
    // as an authority withdrawal by that echo.
    body.withdrawn = reason;
    body.cancel?.cancel(PreparationCancellationReason.revoked);
    body.cancel = null;
    final observation = body.observation;
    body.observation = null;
    if (observation != null) unawaited(observation.cancel());
    if (revokeRuntime) {
      // Revocation wins over completeness: the runtime drops the observation
      // and every value prepared from it before the lease is given up.
      runtime.revoke(body.sourceField.resource);
    }
    body.ownership?.release();
    body.ownership = null;
    body.value = null;
    body.revision = null;
    body.plan = null;
    _notifyState(body, ConversationMarkdownWithdrawn(reason));
  }

  /// Reflects an application authority withdrawal in the bodies this owner
  /// still shows. The runtime has already withdrawn the derived values.
  void _onSourceInvalidated(SourceInvalidation invalidation) {
    if (_disposed) return;
    if (invalidation.reason != SourceInvalidationReason.revoked) return;
    for (final body in List<_PreparedBody>.of(_bodies.values)) {
      if (body.withdrawn != null) continue;
      if (body.sourceField.resource != invalidation.resource) continue;
      _withdrawBody(
        body,
        ConversationMarkdownWithdrawal.revoked,
        revokeRuntime: false,
      );
    }
  }

  void _notifyState(_PreparedBody body, ConversationMarkdownBodyState state) {
    for (final listener
        in List<void Function(ConversationMarkdownBodyState)>.of(
          body.listeners,
        )) {
      listener(state);
    }
  }

  void _enforceRetention() {
    final live = _bodies.values
        .where((body) => body.withdrawn == null)
        .toList();
    if (live.length <= maxRetainedBodies) return;
    final candidates = live.where((body) => body.listeners.isEmpty).toList()
      ..sort(
        (left, right) => left.lastPublished.compareTo(right.lastPublished),
      );
    var excess = live.length - maxRetainedBodies;
    for (final body in candidates) {
      if (excess <= 0) break;
      retire(body.identity);
      excess--;
    }
  }

  Future<MarkdownPreparationEngine> _engine() {
    final ready = _engineReady;
    if (ready != null) return Future<MarkdownPreparationEngine>.value(ready);
    final pending = _pendingEngine;
    if (pending != null) return pending;
    final future = _engineFactory();
    _pendingEngine = future;
    return future.then((engine) {
      _pendingEngine = null;
      // A disposed owner stops the pool through its own disposal path, which
      // awaits this same future, so the pool is stopped exactly once.
      if (!_disposed) _engineReady = engine;
      return engine;
    });
  }

  Future<MarkdownPreparationEngine>? _pendingEngine;
}

final class _PreparedBody {
  _PreparedBody(this.identity)
    : sourceField = conversationMarkdownFieldGroupFor(identity),
      preparedField = _conversationMarkdownPreparedFieldFor(identity);

  final String identity;
  final ResourceFieldGroup<ConversationMarkdownBody> sourceField;
  final ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> preparedField;
  String conversationId = '';
  String? lastText;
  ConversationMarkdownWithdrawal? withdrawn;
  SourceOwnership<ConversationMarkdownBody>? ownership;
  StreamSubscription<ResourceSnapshot<ConversationMarkdownBody>>? observation;
  MessageMarkdownDecomposition? revision;
  PreparationCancellationToken? cancel;
  PreparedValue<MessageMarkdownBlock>? value;
  MarkdownPreparationPlan? plan;
  PreparationWorkerIdentity? worker;
  Object? failure;
  final List<void Function(ConversationMarkdownBodyState state)> listeners =
      <void Function(ConversationMarkdownBodyState state)>[];
  int preparations = 0;
  int lastPublished = 0;
}
