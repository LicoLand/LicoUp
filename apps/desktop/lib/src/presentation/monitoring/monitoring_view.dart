import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_resources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Narrow renderer-facing inputs for the usage observation view.
///
/// The usage report and quota snapshots pass through unmodified so
/// late-arriving costs and in-flight entries stay observable; nothing here
/// turns an estimate into a settlement.
final class MonitoringUsageInputs {
  const MonitoringUsageInputs({
    required this.scope,
    required this.usage,
    required this.quotas,
    required this.historyDays,
    required this.phase,
    required this.detectedTargets,
    required this.quotaSnapshots,
    required this.refreshing,
    this.report,
    this.notice,
  });

  factory MonitoringUsageInputs.fromProjection(
    MonitoringProjection projection,
  ) => MonitoringUsageInputs(
    scope: monitoringPresentationScope,
    usage: projection.usage,
    quotas: projection.quotas,
    historyDays: projection.historyDays,
    phase: projection.phase,
    detectedTargets: projection.detectedTargets,
    quotaSnapshots: projection.quotaSnapshots,
    refreshing: projection.refreshing,
    report: projection.report,
    notice: projection.notice,
  );

  final ResourceScope scope;
  final List<PresentationMetric> usage;
  final List<PresentationMetric> quotas;
  final int historyDays;
  final PresentationPhase phase;
  final List<TargetCandidate> detectedTargets;
  final Map<String, ProviderQuotaSnapshot> quotaSnapshots;
  final bool refreshing;
  final AgentUsageReport? report;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MonitoringUsageInputs &&
          other.scope == scope &&
          samePresentationList(other.usage, usage) &&
          samePresentationList(other.quotas, quotas) &&
          other.historyDays == historyDays &&
          other.phase == phase &&
          samePresentationList(other.detectedTargets, detectedTargets) &&
          _sameQuotaSnapshots(other.quotaSnapshots, quotaSnapshots) &&
          other.refreshing == refreshing &&
          identical(other.report, report) &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    Object.hashAll(usage),
    Object.hashAll(quotas),
    historyDays,
    phase,
    Object.hashAll(detectedTargets),
    Object.hashAllUnordered(
      quotaSnapshots.entries.map(
        (entry) => Object.hash(entry.key, identityHashCode(entry.value)),
      ),
    ),
    refreshing,
    report,
    notice,
  );
}

/// Narrow renderer actions for usage observation. Every dispatch carries the
/// pinned originating scope so asynchronous failures stay attributable.
final class MonitoringUsageActions {
  const MonitoringUsageActions({
    required this.origin,
    required this.refresh,
    required this.startAutomatic,
    required this.stopAutomatic,
    required this.setHistoryDays,
  });

  factory MonitoringUsageActions.fromIntents(
    IntentSink<MonitoringIntent> intents,
  ) {
    const origin = ActionOrigin(
      scope: monitoringPresentationScope,
      resource: monitoringUsageResource,
    );
    final channel = CallbackActions<MonitoringIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return MonitoringUsageActions(
      origin: origin,
      refresh: () => channel.dispatch(const RefreshMonitoring()),
      startAutomatic: () => channel.dispatch(const StartAutomaticMonitoring()),
      stopAutomatic: () => channel.dispatch(const StopAutomaticMonitoring()),
      setHistoryDays: (days) =>
          channel.dispatch(SetMonitoringHistoryDays(days)),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function() refresh;
  final FutureOr<void> Function() startAutomatic;
  final FutureOr<void> Function() stopAutomatic;
  final FutureOr<void> Function(int days) setHistoryDays;
}

bool _sameQuotaSnapshots(
  Map<String, ProviderQuotaSnapshot> left,
  Map<String, ProviderQuotaSnapshot> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!identical(entry.value, right[entry.key])) return false;
  }
  return true;
}
