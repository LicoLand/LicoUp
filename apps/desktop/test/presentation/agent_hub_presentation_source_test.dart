import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_resources.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/agent_hub/agent_hub_presentation_source.dart';

void main() {
  AgentHubProjection projection({
    PresentationPhase phase = PresentationPhase.ready,
    int refreshRevision = 0,
  }) => AgentHubProjection(
    entries: const [],
    phase: phase,
    refreshRevision: refreshRevision,
  );

  group('AgentHubPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeAgentHubProjectionSource(projection());
      final source = AgentHubPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, agentHubCatalogFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, agentHubCatalogFields);
      expect(initial.resource, agentHubCatalogResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(agentHubCatalogFields), isTrue);
    });

    test(
      'publishes base-matched changes with monotonic versions and trace',
      () async {
        final producer = _FakeAgentHubProjectionSource(projection());
        final source = AgentHubPresentationSource(projection: producer);
        addTearDown(source.dispose);
        final observation = await source.open();
        final published = <SourceChange<AgentHubProjection>>[];
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
        expect(change.group.affects(agentHubCatalogFields), isTrue);
        expect(
          change.group.position.compare(observation.initial.position),
          VersionRelation.newer,
        );
      },
    );

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeAgentHubProjectionSource(projection());
        final source = AgentHubPresentationSource(projection: producer);
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
      final producer = _FakeAgentHubProjectionSource(projection());
      final source = AgentHubPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final states = <ResourceSnapshot<AgentHubProjection>>[];
      final observation = runtime.observe(source);
      final subscription = observation.snapshots.listen(states.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single.value, producer.current);
      expect(states.single.fieldGroup, agentHubCatalogFields);

      producer.publish(projection(phase: PresentationPhase.loading));
      await pumpEventQueue();

      expect(states, hasLength(2));
      expect(states[1].value.phase, PresentationPhase.loading);
      expect(states[1].position.isAfter(states[0].position), isTrue);
      expect(
        states[1].consistencyGroup!.affects(agentHubCatalogFields),
        isTrue,
      );
      expect(
        runtime.current(agentHubCatalogFields)?.value.phase,
        PresentationPhase.loading,
      );
    });

    test('exposes a provider entry bound to the catalog resource', () {
      final producer = _FakeAgentHubProjectionSource(projection());
      final source = AgentHubPresentationSource(projection: producer);
      addTearDown(source.dispose);

      final entry = presentationProviderEntry(source);
      expect(entry.resource, agentHubCatalogFields);
    });
  });

  group('AgentHubCatalogActions', () {
    test('dispatch typed intents with the pinned agent hub origin', () async {
      final intents = _RecordingAgentHubIntents();
      final actions = AgentHubCatalogActions.fromIntents(intents);

      expect(actions.origin.scope, agentHubPresentationScope);
      expect(actions.origin.resource, agentHubCatalogResource);

      await actions.refresh();
      await actions.planEntryInstall(
        'codex',
        channelId: 'npm',
        version: '1.2.3',
      );
      await actions.installEntry('codex', channelId: 'npm', version: '1.2.3');
      await actions.updateEntry('codex');
      await actions.uninstallEntry('codex');
      await actions.verifyEntry('codex');
      await actions.retryEntryAction('codex');
      await actions.openEntryHomepage('codex');
      await actions.openEntryAgent('codex');

      expect(intents.values, hasLength(9));
      expect(intents.values[0], isA<RefreshAgentHub>());
      final plan = intents.values[1] as PlanAgentHubEntryInstall;
      expect(plan.entryId, 'codex');
      expect(plan.channelId, 'npm');
      expect(plan.version, '1.2.3');
      final install = intents.values[2] as InstallAgentHubEntry;
      expect(install.entryId, 'codex');
      expect(install.channelId, 'npm');
      expect(install.version, '1.2.3');
      expect((intents.values[3] as UpdateAgentHubEntry).entryId, 'codex');
      expect((intents.values[4] as UninstallAgentHubEntry).entryId, 'codex');
      expect((intents.values[5] as VerifyAgentHubEntry).entryId, 'codex');
      expect((intents.values[6] as RetryAgentHubEntryAction).entryId, 'codex');
      expect((intents.values[7] as OpenAgentHubHomepage).entryId, 'codex');
      expect((intents.values[8] as OpenAgentHubAgent).entryId, 'codex');
    });

    test('install actions carry the default channel and version', () async {
      final intents = _RecordingAgentHubIntents();
      final actions = AgentHubCatalogActions.fromIntents(intents);

      await actions.planEntryInstall('codex');
      await actions.installEntry('codex');

      final plan = intents.values[0] as PlanAgentHubEntryInstall;
      expect(plan.channelId, '');
      expect(plan.version, 'latest');
      final install = intents.values[1] as InstallAgentHubEntry;
      expect(install.channelId, '');
      expect(install.version, 'latest');
    });

    test('inputs map the catalog projection without losing fields', () {
      final value = projection(
        phase: PresentationPhase.failed,
        refreshRevision: 3,
      );
      final inputs = AgentHubCatalogInputs.fromProjection(value);

      expect(inputs.scope, agentHubPresentationScope);
      expect(inputs.entries, value.entries);
      expect(inputs.phase, value.phase);
      expect(inputs.refreshRevision, 3);
      expect(inputs.notice, value.notice);
      expect(inputs, AgentHubCatalogInputs.fromProjection(value));
    });
  });
}

final class _FakeAgentHubProjectionSource
    implements ProjectionSource<AgentHubProjection> {
  _FakeAgentHubProjectionSource(this._current);

  AgentHubProjection _current;
  final StreamController<ProjectionUpdate<AgentHubProjection>> _changes =
      StreamController<ProjectionUpdate<AgentHubProjection>>.broadcast(
        sync: true,
      );

  @override
  AgentHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentHubProjection>> get changes => _changes.stream;

  void publish(AgentHubProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<AgentHubProjection>(value, trace: trace));
  }
}

final class _RecordingAgentHubIntents implements IntentSink<AgentHubIntent> {
  final List<AgentHubIntent> values = <AgentHubIntent>[];

  @override
  void send(AgentHubIntent intent) => values.add(intent);
}
