import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class MonitoringProjectionProducer
    implements ProjectionSource<MonitoringProjection> {
  MonitoringProjectionProducer(ClientController controller)
    : _controller = controller,
      _current = _read(controller) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      controller.agentUsageController.changes.listen(_handleChange),
      controller.providerQuotaController.changes.listen(_handleChange),
      controller.targetController.changes.listen(_handleChange),
    ];
  }

  final ClientController _controller;
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  final StreamController<ProjectionUpdate<MonitoringProjection>> _changes =
      StreamController<ProjectionUpdate<MonitoringProjection>>.broadcast(
        sync: true,
      );
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
