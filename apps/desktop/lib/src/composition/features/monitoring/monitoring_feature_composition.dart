import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_effect.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/projections/monitoring/monitoring_projection_producer.dart';

final class MonitoringFeatureComposition {
  MonitoringFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _projection = MonitoringProjectionProducer(controller),
       _effects = _MonitoringEffects(),
       _intents = _MonitoringIntents(
         controller,
         beginRendererIntent: beginRendererIntent,
       ) {
    _intents.effects = _effects;
    binding = MonitoringBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final MonitoringProjectionProducer _projection;
  final _MonitoringEffects _effects;
  final _MonitoringIntents _intents;
  late final MonitoringBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _projection.close();
    await _effects.close();
  }
}

final class _MonitoringEffects implements EffectSource<MonitoringEffect> {
  final StreamController<MonitoringEffect> _controller =
      StreamController<MonitoringEffect>.broadcast(sync: true);

  @override
  Stream<MonitoringEffect> get effects => _controller.stream;

  void add(MonitoringEffect effect) => _controller.add(effect);

  Future<void> close() => _controller.close();
}

final class _MonitoringIntents implements IntentSink<MonitoringIntent> {
  _MonitoringIntents(
    this._controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late _MonitoringEffects effects;

  @override
  void send(MonitoringIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshMonitoring():
        _run(() async {
          await Future.wait<void>([
            _controller.agentUsageController.scan(forceRefresh: true),
            _controller.providerQuotaController.refresh(forceRefresh: true),
          ]);
        }, trace);
      case StartAutomaticMonitoring():
        _controller.startAgentUsagePolling();
        if (_controller.agentUsageReport == null) {
          _run(
            () => _controller.ensureAgentUsageLoadedAndFresh(limit: 20),
            trace,
          );
        }
      case StopAutomaticMonitoring():
        _controller.stopAgentUsagePolling();
      case SetMonitoringHistoryDays(:final days):
        _run(
          () => _controller.agentUsageController.setHistoryDays(days),
          trace,
        );
    }
  }

  void _run(Future<void> Function() action, TraceContext? trace) {
    unawaited(
      action().catchError((Object _) {
        effects.add(
          MonitoringRefreshRejected('monitoring_refresh_failed', trace: trace),
        );
      }),
    );
  }
}
