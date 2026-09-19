import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_inputs.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/projections/skill_hub/skill_hub_presentation_sources.dart';

void main() {
  test(
    'opening delivers the current projection as the catalog snapshot',
    () async {
      final harness = _CatalogSourceHarness(
        projection: _projection(skills: [_skill('alpha')], query: 'al'),
      );
      addTearDown(harness.dispose);

      expect(harness.counting.openObservations, 0);

      final observation = await harness.source.open();

      expect(observation.initial.fieldGroup, skillHubCatalogFieldGroup);
      expect(observation.initial.epoch, const SourceEpoch('catalog-test'));
      expect(observation.initial.version.value, 1);
      expect(observation.initial.consistencyGroup, isNull);
      expect(observation.initial.value.skills.map((skill) => skill.id), [
        'alpha',
      ]);
      expect(observation.initial.value.query, 'al');
      expect(observation.initial.value.phase, PresentationPhase.ready);
      expect(observation.initial.value.usageAvailable, isFalse);
      // The hub subscription is established before the initial read.
      expect(harness.counting.openObservations, 1);
    },
  );

  test('republishing an equal slice emits nothing', () async {
    final harness = _CatalogSourceHarness(
      projection: _projection(skills: [_skill('alpha')]),
    );
    addTearDown(harness.dispose);
    final observation = await harness.source.open();
    final updates = <SourceChange<SkillHubCatalogInputs>>[];
    final subscription = observation.changes.listen(updates.add);
    addTearDown(subscription.cancel);

    harness.inner.publish(_projection(skills: [_skill('alpha')], notice: null));
    await _settle();

    expect(updates, isEmpty);
    expect(harness.counting.openObservations, 1);
  });

  test('a changed slice emits one base-matched single-member change', () async {
    final harness = _CatalogSourceHarness(
      projection: _projection(skills: [_skill('alpha')]),
    );
    addTearDown(harness.dispose);
    final observation = await harness.source.open();
    final updates = <SourceChange<SkillHubCatalogInputs>>[];
    final subscription = observation.changes.listen(updates.add);
    addTearDown(subscription.cancel);

    harness.inner.publish(
      _projection(skills: [_skill('alpha'), _skill('beta')]),
      trace: const TraceContext(traceId: 'trace-a'),
    );
    await _settle();

    expect(updates, hasLength(1));
    final change = updates.single;
    expect(change.base, observation.initial.position);
    expect(change.matchesBase(observation.initial), isTrue);
    expect(change.snapshot.version.value, 2);
    expect(change.snapshot.epoch, const SourceEpoch('catalog-test'));
    expect(change.group.position, change.snapshot.position);
    expect(change.group.changed, hasLength(1));
    expect(
      change.group.changed.single.resource,
      skillHubCatalogFieldGroup.resource,
    );
    expect(change.group.changed.single.name, 'inputs');
    expect(change.hasValidGroup, isTrue);
    expect(change.snapshot.value.skills.map((skill) => skill.id), [
      'alpha',
      'beta',
    ]);
    expect(change.trace?.traceId, 'trace-a');

    harness.inner.publish(_projection(skills: [_skill('beta')]));
    await _settle();

    expect(updates, hasLength(2));
    expect(updates.last.snapshot.version.value, 3);
    expect(updates.last.base.version.value, 2);
    expect(updates.last.matchesBase(updates.first.snapshot), isTrue);
  });

  test('releasing the only observation cancels the hub subscription', () async {
    final harness = _CatalogSourceHarness(
      projection: _projection(skills: [_skill('alpha')]),
    );
    addTearDown(harness.dispose);

    final observation = await harness.source.open();
    final subscription = observation.changes.listen((_) {});
    expect(harness.counting.subscriptions, 1);
    expect(harness.counting.openObservations, 1);

    await subscription.cancel();
    await _settle();

    expect(harness.counting.cancellations, 1);
    expect(harness.counting.openObservations, 0);

    harness.inner.publish(_projection(skills: [_skill('beta')]));
    await _settle();
    expect(harness.counting.openObservations, 0);
  });

  test('reopening after a full cancel observes the hub again', () async {
    final harness = _CatalogSourceHarness(
      projection: _projection(skills: [_skill('alpha')]),
    );
    addTearDown(harness.dispose);

    final first = await harness.source.open();
    final firstSubscription = first.changes.listen((_) {});
    await firstSubscription.cancel();
    await _settle();
    expect(harness.counting.openObservations, 0);

    final second = await harness.source.open();
    final updates = <SourceChange<SkillHubCatalogInputs>>[];
    final secondSubscription = second.changes.listen(updates.add);
    addTearDown(secondSubscription.cancel);

    expect(second.initial.version.value, 2);
    expect(harness.counting.subscriptions, 2);
    expect(harness.counting.openObservations, 1);

    harness.inner.publish(
      _projection(skills: [_skill('alpha'), _skill('beta')]),
    );
    await _settle();

    expect(updates, hasLength(1));
    expect(updates.single.base, second.initial.position);
    expect(updates.single.snapshot.version.value, 3);

    await secondSubscription.cancel();
    await _settle();
    expect(harness.counting.openObservations, 0);
    expect(harness.counting.cancellations, 2);
  });

  test(
    'dispose releases open observations and rejects further opens',
    () async {
      final harness = _CatalogSourceHarness();
      final observation = await harness.source.open();
      final subscription = observation.changes.listen((_) {});

      await harness.source.dispose();
      await _settle();

      expect(harness.counting.cancellations, 1);
      expect(harness.counting.openObservations, 0);
      expect(() => harness.source.open(), throwsStateError);
      await subscription.cancel();
      await harness.inner.dispose();
    },
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

SkillHubProjection _projection({
  List<SkillProjectionItem> skills = const <SkillProjectionItem>[],
  String query = '',
  PresentationPhase phase = PresentationPhase.ready,
  bool usageAvailable = false,
  PresentationNotice? notice,
}) => SkillHubProjection(
  skills: skills,
  query: query,
  phase: phase,
  usageAvailable: usageAvailable,
  notice: notice,
);

SkillProjectionItem _skill(String id) => SkillProjectionItem(
  id: id,
  name: id,
  author: '',
  description: '',
  content: '',
  sourceLabel: '',
  version: 'local',
  pathLabel: '/skills/$id',
  public: false,
  usageCount: 0,
  windowedUsageCount: 0,
  iconId: 'plug',
  colorToken: 'primary',
  agents: const <SkillAgentProjection>[],
);

final class _CatalogSourceHarness {
  _CatalogSourceHarness({SkillHubProjection? projection})
    : inner = _MutableProjectionSource(projection ?? _projection()) {
    counting = _CountingProjectionSource(inner);
    source = SkillHubCatalogPresentationSource(
      fieldGroup: skillHubCatalogFieldGroup,
      source: counting,
      epochId: 'catalog-test',
    );
  }

  final _MutableProjectionSource inner;
  late final _CountingProjectionSource counting;
  late final SkillHubCatalogPresentationSource source;

  Future<void> dispose() async {
    await source.dispose();
    await inner.dispose();
  }
}

final class _MutableProjectionSource
    implements ProjectionSource<SkillHubProjection> {
  _MutableProjectionSource(this._current);

  SkillHubProjection _current;
  final StreamController<ProjectionUpdate<SkillHubProjection>> _changes =
      StreamController<ProjectionUpdate<SkillHubProjection>>.broadcast(
        sync: true,
      );

  @override
  SkillHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SkillHubProjection>> get changes => _changes.stream;

  void publish(SkillHubProjection projection, {TraceContext? trace}) {
    _current = projection;
    _changes.add(
      ProjectionUpdate<SkillHubProjection>(projection, trace: trace),
    );
  }

  Future<void> dispose() => _changes.close();
}

final class _CountingProjectionSource
    implements ProjectionSource<SkillHubProjection> {
  _CountingProjectionSource(this._inner);

  final ProjectionSource<SkillHubProjection> _inner;
  int subscriptions = 0;
  int cancellations = 0;
  int openObservations = 0;

  @override
  SkillHubProjection get current => _inner.current;

  @override
  Stream<ProjectionUpdate<SkillHubProjection>> get changes {
    final controller = StreamController<ProjectionUpdate<SkillHubProjection>>();
    StreamSubscription<ProjectionUpdate<SkillHubProjection>>? upstream;
    var cancelled = false;
    controller
      ..onListen = () {
        subscriptions += 1;
        openObservations += 1;
        upstream = _inner.changes.listen(
          (update) {
            if (!controller.isClosed) controller.add(update);
          },
          onError: controller.addError,
          onDone: () {
            if (!controller.isClosed) unawaited(controller.close());
          },
        );
      }
      ..onCancel = () async {
        if (cancelled) return;
        cancelled = true;
        cancellations += 1;
        openObservations -= 1;
        await upstream?.cancel();
      };
    return controller.stream;
  }
}
