import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_resources.dart';
import 'package:licoup/src/presentation/agents/agents_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/agents/agents_presentation_source.dart';

void main() {
  AgentsProjection projection({
    String selectedAgentId = '',
    PresentationPhase phase = PresentationPhase.ready,
    bool scanning = false,
  }) => AgentsProjection(
    targets: const [
      AgentTargetProjection(
        id: 'codex',
        displayName: 'Codex',
        available: true,
        pinned: false,
        capabilityLabel: 'cli',
      ),
    ],
    selectedAgentId: selectedAgentId,
    workingDirectoryLabel: '~/work',
    phase: phase,
    scanning: scanning,
  );

  group('AgentsPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeAgentsProjectionSource(projection());
      final source = AgentsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, agentsCatalogFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, agentsCatalogFields);
      expect(initial.resource, agentsCatalogResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(agentsCatalogFields), isTrue);
    });

    test(
      'publishes base-matched changes with monotonic versions and trace',
      () async {
        final producer = _FakeAgentsProjectionSource(projection());
        final source = AgentsPresentationSource(projection: producer);
        addTearDown(source.dispose);
        final observation = await source.open();
        final published = <SourceChange<AgentsProjection>>[];
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
        expect(change.group.affects(agentsCatalogFields), isTrue);
        expect(
          change.group.position.compare(observation.initial.position),
          VersionRelation.newer,
        );
      },
    );

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeAgentsProjectionSource(projection());
        final source = AgentsPresentationSource(projection: producer);
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
      final producer = _FakeAgentsProjectionSource(projection());
      final source = AgentsPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final states = <ResourceSnapshot<AgentsProjection>>[];
      final observation = runtime.observe(source);
      final subscription = observation.snapshots.listen(states.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single.value, producer.current);
      expect(states.single.fieldGroup, agentsCatalogFields);

      producer.publish(projection(scanning: true));
      await pumpEventQueue();

      expect(states, hasLength(2));
      expect(states[1].value.scanning, isTrue);
      expect(states[1].position.isAfter(states[0].position), isTrue);
      expect(states[1].consistencyGroup!.affects(agentsCatalogFields), isTrue);
      expect(runtime.current(agentsCatalogFields)?.value.scanning, isTrue);
    });

    test('exposes a provider entry bound to the catalog resource', () {
      final producer = _FakeAgentsProjectionSource(projection());
      final source = AgentsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      final entry = presentationProviderEntry(source);
      expect(entry.resource, agentsCatalogFields);
    });
  });

  group('AgentsCatalogActions', () {
    test('dispatch typed intents with the pinned agents origin', () async {
      final intents = _RecordingAgentsIntents();
      final actions = AgentsCatalogActions.fromIntents(intents);

      expect(actions.origin.scope, agentsPresentationScope);
      expect(actions.origin.resource, agentsCatalogResource);

      await actions.scanAgents(showProgress: false, forceRescanKnown: false);
      await actions.selectAgent('codex');
      await actions.togglePinned('codex');
      await actions.startConversation('codex');
      await actions.addManualAgent('kimi', location: 'local');
      await actions.selectConversationSession(
        'codex',
        'session-1',
        nativeSessionId: 'native-1',
      );

      expect(intents.values, hasLength(6));
      final scan = intents.values[0] as ScanAgents;
      expect(scan.showProgress, isFalse);
      expect(scan.forceRescanKnown, isFalse);
      expect(intents.values[1], isA<SelectAgent>());
      expect(intents.values[2], isA<ToggleAgentPinned>());
      expect(intents.values[3], isA<StartAgentConversation>());
      final add = intents.values[4] as AddManualAgent;
      expect(add.command, 'kimi');
      expect(add.location, 'local');
      final selectSession = intents.values[5] as SelectAgentConversationSession;
      expect(selectSession.agentId, 'codex');
      expect(selectSession.sessionId, 'session-1');
      expect(selectSession.nativeSessionId, 'native-1');
    });

    test('adaptive flywheel actions dispatch typed intents', () async {
      final intents = _RecordingAgentsIntents();
      final actions = AgentsCatalogActions.fromIntents(intents);

      await actions.initializeAdaptiveFlywheel(initialRevision: 'rev-1');
      await actions.importAdaptiveFlywheelPackage('/tmp/pkg.zip');
      await actions.selectAdaptiveFlywheelDefinition('rev-1');
      await actions.saveAdaptiveFlywheelActorBindings(const [
        AdaptiveFlywheelAssignmentIntent(
          slotId: 'planner',
          ordinal: 0,
          agentId: 'codex',
          modelId: 'gpt-5',
          reasoningEffort: 'high',
        ),
      ]);
      await actions.refreshAdaptiveFlywheelModelCatalogs(const ['codex']);
      await actions.readAdaptiveFlywheelAssistantProfile();
      await actions.updateAdaptiveFlywheelAssistantProfile(
        agentId: 'codex',
        modelId: 'gpt-5',
        reasoningEffort: 'high',
      );

      expect(intents.values, hasLength(7));
      expect(
        (intents.values[0] as InitializeAdaptiveFlywheel).initialRevision,
        'rev-1',
      );
      expect(
        (intents.values[1] as ImportAdaptiveFlywheelPackage).path,
        '/tmp/pkg.zip',
      );
      expect(
        (intents.values[2] as SelectAdaptiveFlywheelDefinition).revision,
        'rev-1',
      );
      final save = intents.values[3] as SaveAdaptiveFlywheelActorBindings;
      expect(save.assignments.single.slotId, 'planner');
      expect(save.assignments.single.reasoningEffort, 'high');
      final refresh = intents.values[4] as RefreshAdaptiveFlywheelModelCatalogs;
      expect(refresh.agentIds, ['codex']);
      expect(intents.values[5], isA<ReadAdaptiveFlywheelAssistantProfile>());
      final update =
          intents.values[6] as UpdateAdaptiveFlywheelAssistantProfile;
      expect(update.agentId, 'codex');
      expect(update.modelId, 'gpt-5');
      expect(update.reasoningEffort, 'high');
    });

    test('inputs map the catalog projection without losing fields', () {
      final value = projection(
        selectedAgentId: 'codex',
        phase: PresentationPhase.failed,
        scanning: true,
      );
      final inputs = AgentsCatalogInputs.fromProjection(value);

      expect(inputs.scope, agentsPresentationScope);
      expect(inputs.targets, value.targets);
      expect(inputs.selectedAgentId, 'codex');
      expect(inputs.workingDirectoryLabel, value.workingDirectoryLabel);
      expect(inputs.phase, value.phase);
      expect(inputs.targetDetails, value.targetDetails);
      expect(inputs.mobileRuntime, value.mobileRuntime);
      expect(inputs.scanning, isTrue);
      expect(inputs.adding, value.adding);
      expect(inputs.adaptiveFlywheel, value.adaptiveFlywheel);
      expect(inputs, AgentsCatalogInputs.fromProjection(value));
    });
  });
}

final class _FakeAgentsProjectionSource
    implements ProjectionSource<AgentsProjection> {
  _FakeAgentsProjectionSource(this._current);

  AgentsProjection _current;
  final StreamController<ProjectionUpdate<AgentsProjection>> _changes =
      StreamController<ProjectionUpdate<AgentsProjection>>.broadcast(
        sync: true,
      );

  @override
  AgentsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentsProjection>> get changes => _changes.stream;

  void publish(AgentsProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<AgentsProjection>(value, trace: trace));
  }
}

final class _RecordingAgentsIntents implements IntentSink<AgentsIntent> {
  final List<AgentsIntent> values = <AgentsIntent>[];

  @override
  void send(AgentsIntent intent) => values.add(intent);
}
