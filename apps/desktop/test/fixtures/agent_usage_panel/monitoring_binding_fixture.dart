import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_effect.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class MonitoringBindingFixture {
  MonitoringBindingFixture(ClientController controller)
    : _projection = _MonitoringProjectionSource(controller),
      _effects = _MonitoringEffectSource(),
      _intents = _MonitoringIntentSink(controller) {
    _intents.effects = _effects;
    binding = MonitoringBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final _MonitoringProjectionSource _projection;
  final _MonitoringEffectSource _effects;
  final _MonitoringIntentSink _intents;
  late final MonitoringBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _projection.close();
    await _effects.close();
  }
}

final class _MonitoringProjectionSource
    implements ProjectionSource<MonitoringProjection> {
  _MonitoringProjectionSource(this._controller)
    : _current = _read(_controller) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      _controller.agentUsageController.changes.listen(_handleChange),
      _controller.providerQuotaController.changes.listen(_handleChange),
      _controller.targetController.changes.listen(_handleChange),
    ];
  }

  final ClientController _controller;
  final StreamController<ProjectionUpdate<MonitoringProjection>> _changes =
      StreamController<ProjectionUpdate<MonitoringProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  MonitoringProjection _current;
  bool _closed = false;

  @override
  MonitoringProjection get current => _current;

  @override
  Stream<ProjectionUpdate<MonitoringProjection>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) {
    if (_closed) return;
    final next = _read(_controller);
    if (next == _current) return;
    _current = next;
    _changes.add(
      ProjectionUpdate<MonitoringProjection>(
        next,
        trace: change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await _changes.close();
  }

  static MonitoringProjection _read(ClientController controller) {
    final report = controller.agentUsageController.report;
    final snapshots = controller.providerQuotaController.snapshots;
    final detected = controller.targetController.orderedConversationTargets(
      controller.targetController.targets.where(
        (target) => target.status != 'not-detected',
      ),
    );
    return MonitoringProjection(
      report: report,
      detectedTargets: detected,
      quotaSnapshots: snapshots,
      refreshing: controller.agentUsageController.scanning,
      usage: <PresentationMetric>[
        PresentationMetric(
          id: 'total-tokens',
          label: 'Total tokens',
          value: report?.totalTokens ?? 0,
          unit: 'tokens',
        ),
        PresentationMetric(
          id: 'agent-count',
          label: 'Agents',
          value: report?.agentCount ?? 0,
          unit: 'agents',
        ),
      ],
      quotas: <PresentationMetric>[
        for (final entry in snapshots.entries)
          if (entry.value.hasQuotaWindows)
            PresentationMetric(
              id: entry.key,
              label: entry.value.provider,
              value: entry.value.ringUsedPercent,
              unit: 'percent',
            ),
      ],
      historyDays: controller.agentUsageController.historyDays,
      phase: controller.agentUsageController.scanning
          ? PresentationPhase.loading
          : report == null
          ? PresentationPhase.idle
          : PresentationPhase.ready,
    );
  }
}

final class _MonitoringIntentSink implements IntentSink<MonitoringIntent> {
  _MonitoringIntentSink(this._controller);

  final ClientController _controller;
  late _MonitoringEffectSource effects;

  @override
  void send(MonitoringIntent intent) {
    switch (intent) {
      case RefreshMonitoring():
        _run(
          () async => Future.wait<void>([
            _controller.agentUsageController.scan(forceRefresh: true),
            _controller.providerQuotaController.refresh(forceRefresh: true),
          ]),
          intent,
        );
      case StartAutomaticMonitoring():
        _controller.startAgentUsagePolling();
        if (_controller.agentUsageReport == null) {
          _run(
            () => _controller.ensureAgentUsageLoadedAndFresh(limit: 20),
            intent,
          );
        }
      case StopAutomaticMonitoring():
        _controller.stopAgentUsagePolling();
      case SetMonitoringHistoryDays(:final days):
        _run(
          () => _controller.agentUsageController.setHistoryDays(days),
          intent,
        );
    }
  }

  void _run(Future<void> Function() action, MonitoringIntent intent) {
    unawaited(
      action().catchError((Object _) {
        effects.add(
          MonitoringRefreshRejected(
            'monitoring_refresh_failed',
            trace: intent.trace,
          ),
        );
      }),
    );
  }
}

final class _MonitoringEffectSource implements EffectSource<MonitoringEffect> {
  final StreamController<MonitoringEffect> _effects =
      StreamController<MonitoringEffect>.broadcast(sync: true);
  bool _closed = false;

  @override
  Stream<MonitoringEffect> get effects => _effects.stream;

  void add(MonitoringEffect effect) {
    if (!_closed) _effects.add(effect);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _effects.close();
  }
}
