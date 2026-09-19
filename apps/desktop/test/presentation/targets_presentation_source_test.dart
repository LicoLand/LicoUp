import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';
import 'package:licoup/src/presentation/targets/targets_view.dart';
import 'package:licoup/src/projections/targets/targets_presentation_source.dart';

void main() {
  TargetsProjection projection({
    String selected = '',
    PresentationPhase phase = PresentationPhase.ready,
  }) => TargetsProjection(
    targets: const [
      TargetProjectionItem(
        id: 'codex',
        name: 'Codex',
        typeLabel: 'cli',
        readinessLabel: 'ready',
        detail: '',
        locationLabel: 'local',
        configured: true,
        pinned: false,
        selected: true,
      ),
    ],
    manualTargetOptions: const [
      ManualTargetOptionProjection(id: 'codex', label: 'Codex'),
    ],
    phase: phase,
  );

  group('TargetsPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeTargetsProjectionSource(projection());
      final source = TargetsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, targetsCatalogFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, targetsCatalogFields);
      expect(initial.resource, targetsCatalogResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(targetsCatalogFields), isTrue);
    });

    test(
      'publishes base-matched changes with monotonic versions and trace',
      () async {
        final producer = _FakeTargetsProjectionSource(projection());
        final source = TargetsPresentationSource(projection: producer);
        addTearDown(source.dispose);
        final observation = await source.open();
        final published = <SourceChange<TargetsProjection>>[];
        final subscription = observation.changes.listen(published.add);
        addTearDown(subscription.cancel);

        final next = projection(phase: PresentationPhase.loading);
        const trace = TraceContext(traceId: 'trace-1');
        producer.publish(next, trace: trace);
        producer.publish(next);

        expect(published, hasLength(1));
        final change = published.single;
        expect(change.base, observation.initial.position);
        expect(change.position.version.value, 2);
        expect(change.snapshot.value, next);
        expect(change.trace, trace);
        expect(change.hasValidGroup, isTrue);
        expect(change.group.affects(targetsCatalogFields), isTrue);
        expect(
          change.group.position.compare(observation.initial.position),
          VersionRelation.newer,
        );
      },
    );

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeTargetsProjectionSource(projection());
        final source = TargetsPresentationSource(projection: producer);
        addTearDown(source.dispose);

        final first = await source.open();
        final firstSubscription = first.changes.listen((_) {});
        producer.publish(projection(phase: PresentationPhase.loading));
        await firstSubscription.cancel();
        await pumpEventQueue();

        producer.publish(projection(phase: PresentationPhase.failed));
        final second = await source.open();
        expect(second.initial.value.phase, PresentationPhase.failed);
        expect(second.initial.position.isAfter(first.initial.position), isTrue);
        expect(second.initial.epoch, first.initial.epoch);
      },
    );

    test('installs snapshots through the shared runtime observation', () async {
      final producer = _FakeTargetsProjectionSource(projection());
      final source = TargetsPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final states = <ResourceSnapshot<TargetsProjection>>[];
      final observation = runtime.observe(source);
      final subscription = observation.snapshots.listen(states.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single.value, producer.current);
      expect(states.single.fieldGroup, targetsCatalogFields);

      producer.publish(projection(phase: PresentationPhase.loading));
      await pumpEventQueue();

      expect(states, hasLength(2));
      expect(states[1].value.phase, PresentationPhase.loading);
      expect(states[1].position.isAfter(states[0].position), isTrue);
      expect(states[1].consistencyGroup!.affects(targetsCatalogFields), isTrue);
      expect(
        runtime.current(targetsCatalogFields)?.value.phase,
        PresentationPhase.loading,
      );
    });

    test('exposes a provider entry bound to the catalog resource', () {
      final producer = _FakeTargetsProjectionSource(projection());
      final source = TargetsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      final entry = presentationProviderEntry(source);
      expect(entry.resource, targetsCatalogFields);
    });
  });

  group('TargetsCatalogActions', () {
    test('dispatch typed intents with the pinned targets origin', () async {
      final intents = _RecordingTargetsIntents();
      final actions = TargetsCatalogActions.fromIntents(intents);

      expect(actions.origin.scope, targetsPresentationScope);
      expect(actions.origin.resource, targetsCatalogResource);

      await actions.scan(force: true);
      await actions.select('codex');
      await actions.togglePinned('codex');
      await actions.inspect('codex');
      await actions.addManual(targetId: 'kimi-code', location: 'local');

      expect(intents.values, hasLength(5));
      expect(intents.values[0], isA<ScanTargets>());
      expect((intents.values[0] as ScanTargets).force, isTrue);
      expect(intents.values[1], isA<SelectTarget>());
      expect(intents.values[2], isA<ToggleTargetPinned>());
      expect(intents.values[3], isA<InspectTarget>());
      final add = intents.values[4] as AddManualTarget;
      expect(add.targetId, 'kimi-code');
      expect(add.location, 'local');
    });

    test('inputs map the catalog projection without losing fields', () {
      final value = projection(phase: PresentationPhase.failed);
      final inputs = TargetsCatalogInputs.fromProjection(value);

      expect(inputs.scope, targetsPresentationScope);
      expect(inputs.targets, value.targets);
      expect(inputs.manualTargetOptions, value.manualTargetOptions);
      expect(inputs.phase, value.phase);
      expect(inputs, TargetsCatalogInputs.fromProjection(value));
    });
  });
}

final class _FakeTargetsProjectionSource
    implements ProjectionSource<TargetsProjection> {
  _FakeTargetsProjectionSource(this._current);

  TargetsProjection _current;
  final StreamController<ProjectionUpdate<TargetsProjection>> _changes =
      StreamController<ProjectionUpdate<TargetsProjection>>.broadcast(
        sync: true,
      );

  @override
  TargetsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<TargetsProjection>> get changes => _changes.stream;

  void publish(TargetsProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<TargetsProjection>(value, trace: trace));
  }
}

final class _RecordingTargetsIntents implements IntentSink<TargetsIntent> {
  final List<TargetsIntent> values = <TargetsIntent>[];

  @override
  void send(TargetsIntent intent) => values.add(intent);
}
