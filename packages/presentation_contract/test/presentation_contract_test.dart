import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

final class _Projection implements ProjectionSource<int> {
  @override
  int current = 7;

  @override
  Stream<ProjectionUpdate<int>> get changes =>
      const Stream<ProjectionUpdate<int>>.empty();
}

final class _Effects implements EffectSource<String> {
  @override
  Stream<String> get effects => Stream<String>.fromIterable(<String>['shown']);
}

final class _Intents implements IntentSink<String> {
  final sent = <String>[];

  @override
  void send(String intent) => sent.add(intent);
}

final class _Source implements PresentationSource<String> {
  _Source(this._observation) : fieldGroup = _observation.initial.fieldGroup;

  final SourceObservation<String> _observation;

  @override
  final ResourceFieldGroup<String> fieldGroup;

  @override
  Future<SourceObservation<String>> open() async => _observation;
}

final class _Lifecycle implements PresentationLifecycle {
  final events = <String>[];

  @override
  void dispose() => events.add('dispose');

  @override
  void pause() => events.add('pause');

  @override
  void recompute() => events.add('recompute');
}

void main() {
  group('legacy directional primitives', () {
    test(
      'contract preserves projection, effect, and intent directions',
      () async {
        final projection = _Projection();
        final effects = _Effects();
        final intents = _Intents();

        expect(projection.current, 7);
        expect(await projection.changes.toList(), isEmpty);
        expect(await effects.effects.toList(), <String>['shown']);
        intents.send('select');
        expect(intents.sent, <String>['select']);
      },
    );

    test('trace and projection update keep minimal value equality', () {
      const trace = TraceContext(traceId: 'trace-a');
      expect(const TraceContext(), const TraceContext());
      expect(trace, const TraceContext(traceId: 'trace-a'));
      expect(trace, isNot(const TraceContext(traceId: 'trace-b')));
      expect(
        const ProjectionUpdate<int>(7, trace: trace),
        const ProjectionUpdate<int>(7, trace: trace),
      );
      expect(
        const ProjectionUpdate<int>(7),
        isNot(const ProjectionUpdate<int>(8)),
      );
    });
  });

  group('resource identity and source ordering', () {
    late ResourceKey key;
    late ResourceFieldGroup<String> body;
    late SourcePosition first;
    late SourcePosition second;

    setUp(() {
      key = ResourceKey(
        scope: const ResourceScope('conversation:synthetic'),
        stableKey: 'message-1',
      );
      body = ResourceFieldGroup<String>(resource: key, name: 'body');
      first = const SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(1),
      );
      second = const SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(2),
      );
    });

    test('scope, stable key, and typed field group form identity', () {
      expect(
        key,
        ResourceKey(
          scope: const ResourceScope('conversation:synthetic'),
          stableKey: 'message-1',
        ),
      );
      expect(body, ResourceFieldGroup<String>(resource: key, name: 'body'));
      expect(
        body,
        isNot(ResourceFieldGroup<String>(resource: key, name: 'meta')),
      );
    });

    test('version is ordered only inside one source epoch', () {
      expect(second.compare(first), VersionRelation.newer);
      expect(first.compare(second), VersionRelation.older);
      expect(second.isAfter(first), isTrue);
      expect(
        second.compare(
          const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(0),
          ),
        ),
        VersionRelation.differentEpoch,
      );
      expect(
        second.isAfter(
          const SourcePosition(
            epoch: SourceEpoch('epoch-b'),
            version: SourceVersion(99),
          ),
        ),
        isFalse,
      );
    });

    test(
      'source opening carries initial snapshot and later changes together',
      () async {
        final group = ConsistencyGroup(
          id: const ConsistencyGroupId('group-1'),
          position: second,
          changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body)],
        );
        final initial = ResourceSnapshot<String>(
          fieldGroup: body,
          epoch: first.epoch,
          version: first.version,
          value: 'first',
        );
        final next = ResourceSnapshot<String>(
          fieldGroup: body,
          epoch: second.epoch,
          version: second.version,
          value: 'second',
          consistencyGroup: group,
        );
        final changes = StreamController<SourceChange<String>>();
        final source = _Source(
          SourceObservation<String>(initial: initial, changes: changes.stream),
        );
        final observation = await source.open();
        final received = <SourceChange<String>>[];
        final subscription = observation.changes.listen(received.add);
        addTearDown(() async {
          await subscription.cancel();
          await changes.close();
        });

        changes.add(
          SourceChange<String>(snapshot: next, base: first, group: group),
        );
        await Future<void>.delayed(Duration.zero);

        expect(observation.initial, initial);
        expect(received, hasLength(1));
        expect(received.single.snapshot.value, 'second');
      },
    );
  });

  test('consistency groups expose actual changed keys and are immutable', () {
    final key = ResourceKey(
      scope: const ResourceScope('conversation:synthetic'),
      stableKey: 'message-1',
    );
    final body = ResourceFieldGroup<String>(resource: key, name: 'body');
    final group = ConsistencyGroup(
      id: const ConsistencyGroupId('group-1'),
      position: const SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(2),
      ),
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body)],
    );

    expect(group.affects(body), isTrue);
    expect(group.changedKeys, contains(key));
    expect(
      () => group.changed.add(ChangedFieldGroup(resource: key, name: 'meta')),
      throwsUnsupportedError,
    );
  });

  test(
    'delta requires the installed base and carries atomic group identity',
    () {
      final key = ResourceKey(
        scope: const ResourceScope('conversation:synthetic'),
        stableKey: 'message-1',
      );
      final body = ResourceFieldGroup<String>(resource: key, name: 'body');
      const first = SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(1),
      );
      const second = SourcePosition(
        epoch: SourceEpoch('epoch-a'),
        version: SourceVersion(2),
      );
      final group = ConsistencyGroup(
        id: const ConsistencyGroupId('group-1'),
        position: second,
        changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body)],
      );
      final installed = ResourceSnapshot<String>(
        fieldGroup: body,
        epoch: first.epoch,
        version: first.version,
        value: 'first',
      );
      final next = ResourceSnapshot<String>(
        fieldGroup: body,
        epoch: second.epoch,
        version: second.version,
        value: 'second',
        consistencyGroup: group,
      );
      final change = SourceChange<String>(
        snapshot: next,
        base: first,
        group: group,
      );

      expect(change.hasValidGroup, isTrue);
      expect(change.matchesBase(installed), isTrue);
      expect(change.group, same(group));
      expect(
        SourceChange<String>(
          snapshot: installed,
          base: first,
          group: group,
        ).matchesBase(installed),
        isFalse,
      );

      final differentGroup = ConsistencyGroup(
        id: const ConsistencyGroupId('group-2'),
        position: second,
        changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body)],
      );
      expect(
        SourceChange<String>(
          snapshot: next,
          base: first,
          group: differentGroup,
        ).hasValidGroup,
        isFalse,
      );
    },
  );

  test(
    'preparation acceptance rejects rebuild, switch, revoke, and dispose results',
    () {
      final key = ResourceKey(
        scope: const ResourceScope('conversation:synthetic'),
        stableKey: 'message-1',
      );
      final body = ResourceFieldGroup<String>(resource: key, name: 'body');
      final group = ConsistencyGroup(
        id: const ConsistencyGroupId('group-1'),
        position: const SourcePosition(
          epoch: SourceEpoch('epoch-a'),
          version: SourceVersion(2),
        ),
        changed: <ChangedFieldGroup>[ChangedFieldGroup.of(body)],
      );
      final snapshot = ResourceSnapshot<String>(
        fieldGroup: body,
        epoch: const SourceEpoch('epoch-a'),
        version: const SourceVersion(2),
        value: 'second',
        consistencyGroup: group,
      );
      final request = PreparationRequest<String>.fromSnapshot(
        snapshot: snapshot,
        generation: const RequestGeneration(4),
      );
      final prepared = PreparedResource<String>(
        request: request,
        value: 'prepared-second',
      );

      expect(request.resourceKey, key);
      expect(request.epoch, snapshot.epoch);
      expect(request.version, snapshot.version);
      expect(request.consistencyGroup, same(group));
      expect(
        PreparationAcceptance<String>(request: request).accepts(prepared),
        isTrue,
      );
      expect(
        PreparationAcceptance<String>(
          request: PreparationRequest<String>(
            resource: body,
            source: SourcePosition(
              epoch: SourceEpoch('epoch-a'),
              version: SourceVersion(2),
            ),
            generation: RequestGeneration(5),
            consistencyGroup: group,
          ),
        ).accepts(prepared),
        isFalse,
      );
      expect(
        PreparationAcceptance<String>(
          request: request,
          status: PreparationStatus.revoked,
        ).accepts(prepared),
        isFalse,
      );
      expect(
        PreparationAcceptance<String>(
          request: request,
          status: PreparationStatus.disposed,
        ).canInstall(prepared),
        isFalse,
      );
    },
  );

  test(
    'actions pass their pinned origin to the application facade callback',
    () async {
      final key = ResourceKey(
        scope: const ResourceScope('conversation:synthetic'),
        stableKey: 'message-1',
      );
      final origin = ActionOrigin(scope: key.scope, resource: key);
      ActionOrigin? receivedOrigin;
      String? receivedAction;
      final actions = CallbackActions<String>(
        origin: origin,
        onDispatch: (action, actionOrigin) {
          receivedAction = action;
          receivedOrigin = actionOrigin;
        },
      );

      await actions.dispatch('copy');

      expect(receivedAction, 'copy');
      expect(receivedOrigin, same(origin));
      expect(actions.origin, same(origin));
    },
  );

  test('lifecycle controls are presentation-only operations', () {
    final lifecycle = _Lifecycle();

    lifecycle.pause();
    lifecycle.recompute();
    lifecycle.dispose();

    expect(lifecycle.events, <String>['pause', 'recompute', 'dispose']);
  });
}
