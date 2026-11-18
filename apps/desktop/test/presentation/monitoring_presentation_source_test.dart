import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_resources.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/monitoring/monitoring_presentation_source.dart';

void main() {
  MonitoringProjection projection({
    PresentationPhase phase = PresentationPhase.ready,
    bool refreshing = false,
    AgentUsageReport? report,
    Map<String, ProviderQuotaSnapshot> quotaSnapshots = const {},
  }) => MonitoringProjection(
    usage: const [
      PresentationMetric(
        id: 'total-tokens',
        label: 'Total tokens',
        value: 42,
        unit: 'tokens',
      ),
    ],
    quotas: const [],
    historyDays: 7,
    phase: phase,
    report: report,
    quotaSnapshots: quotaSnapshots,
    refreshing: refreshing,
  );

  AgentUsageReport report() => const AgentUsageReport(
    schemaVersion: AgentUsageReport.currentSchemaVersion,
    generatedAt: '2026-09-19T00:00:00Z',
    summary: <String, dynamic>{'totalTokens': 42},
    agents: <AgentUsageAgentSummary>[],
    warnings: <String>['late-arriving-costs-pending'],
  );

  ProviderQuotaSnapshot quotaSnapshot() => const ProviderQuotaSnapshot(
    agentId: 'codex',
    provider: 'openai',
    status: ProviderQuotaStatus.live,
    windows: <ProviderQuotaWindow>[],
    identity: ProviderQuotaIdentity(accountLabel: 'synthetic'),
    capturedAt: '2026-09-19T00:00:00Z',
    staleAfterSeconds: 60,
  );

  group('MonitoringPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeMonitoringProjectionSource(projection());
      final source = MonitoringPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, monitoringUsageFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, monitoringUsageFields);
      expect(initial.resource, monitoringUsageResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(monitoringUsageFields), isTrue);
    });

    test(
      'publishes base-matched changes with monotonic versions and trace',
      () async {
        final producer = _FakeMonitoringProjectionSource(projection());
        final source = MonitoringPresentationSource(projection: producer);
        addTearDown(source.dispose);
        final observation = await source.open();
        final published = <SourceChange<MonitoringProjection>>[];
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
        expect(change.group.affects(monitoringUsageFields), isTrue);
        expect(
          change.group.position.compare(observation.initial.position),
          VersionRelation.newer,
        );
      },
    );

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeMonitoringProjectionSource(projection());
        final source = MonitoringPresentationSource(projection: producer);
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
      final producer = _FakeMonitoringProjectionSource(projection());
      final source = MonitoringPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final states = <ResourceSnapshot<MonitoringProjection>>[];
      final observation = runtime.observe(source);
      final subscription = observation.snapshots.listen(states.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single.value, producer.current);
      expect(states.single.fieldGroup, monitoringUsageFields);

      producer.publish(projection(refreshing: true));
      await pumpEventQueue();

      expect(states, hasLength(2));
      expect(states[1].value.refreshing, isTrue);
      expect(states[1].position.isAfter(states[0].position), isTrue);
      expect(
        states[1].consistencyGroup!.affects(monitoringUsageFields),
        isTrue,
      );
      expect(runtime.current(monitoringUsageFields)?.value.refreshing, isTrue);
    });

    test('exposes a provider entry bound to the usage resource', () {
      final producer = _FakeMonitoringProjectionSource(projection());
      final source = MonitoringPresentationSource(projection: producer);
      addTearDown(source.dispose);

      final entry = presentationProviderEntry(source);
      expect(entry.resource, monitoringUsageFields);
    });
  });

  group('MonitoringUsageActions', () {
    test('dispatch typed intents with the pinned monitoring origin', () async {
      final intents = _RecordingMonitoringIntents();
      final actions = MonitoringUsageActions.fromIntents(intents);

      expect(actions.origin.scope, monitoringPresentationScope);
      expect(actions.origin.resource, monitoringUsageResource);

      await actions.refresh();
      await actions.startAutomatic();
      await actions.stopAutomatic();
      await actions.setHistoryDays(30);

      expect(intents.values, hasLength(4));
      expect(intents.values[0], isA<RefreshMonitoring>());
      expect(intents.values[1], isA<StartAutomaticMonitoring>());
      expect(intents.values[2], isA<StopAutomaticMonitoring>());
      expect((intents.values[3] as SetMonitoringHistoryDays).days, 30);
    });

    test(
      'inputs pass the full usage observation through without estimating',
      () {
        final usageReport = report();
        final snapshot = quotaSnapshot();
        final value = projection(
          phase: PresentationPhase.failed,
          refreshing: true,
          report: usageReport,
          quotaSnapshots: {'codex': snapshot},
        );
        final inputs = MonitoringUsageInputs.fromProjection(value);

        expect(inputs.scope, monitoringPresentationScope);
        expect(inputs.usage, value.usage);
        expect(inputs.quotas, value.quotas);
        expect(inputs.historyDays, 7);
        expect(inputs.phase, value.phase);
        expect(inputs.refreshing, isTrue);
        // The settled report and provider snapshots stay the owner's facts:
        // identical instances, never reconstructed estimates.
        expect(identical(inputs.report, usageReport), isTrue);
        expect(identical(inputs.quotaSnapshots['codex'], snapshot), isTrue);
        expect(inputs.detectedTargets, value.detectedTargets);
        expect(inputs, MonitoringUsageInputs.fromProjection(value));
      },
    );
  });
}

final class _FakeMonitoringProjectionSource
    implements ProjectionSource<MonitoringProjection> {
  _FakeMonitoringProjectionSource(this._current);

  MonitoringProjection _current;
  final StreamController<ProjectionUpdate<MonitoringProjection>> _changes =
      StreamController<ProjectionUpdate<MonitoringProjection>>.broadcast(
        sync: true,
      );

  @override
  MonitoringProjection get current => _current;

  @override
  Stream<ProjectionUpdate<MonitoringProjection>> get changes => _changes.stream;

  void publish(MonitoringProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<MonitoringProjection>(value, trace: trace));
  }
}

final class _RecordingMonitoringIntents
    implements IntentSink<MonitoringIntent> {
  final List<MonitoringIntent> values = <MonitoringIntent>[];

  @override
  void send(MonitoringIntent intent) => values.add(intent);
}
