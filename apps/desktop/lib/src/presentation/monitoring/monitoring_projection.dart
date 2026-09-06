import 'package:licoup/src/contracts/agent_usage_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class MonitoringProjection {
  MonitoringProjection({
    required Iterable<PresentationMetric> usage,
    required Iterable<PresentationMetric> quotas,
    required this.historyDays,
    required this.phase,
    this.report,
    Iterable<TargetCandidate> detectedTargets = const <TargetCandidate>[],
    Map<String, ProviderQuotaSnapshot> quotaSnapshots =
        const <String, ProviderQuotaSnapshot>{},
    this.refreshing = false,
    this.notice,
  }) : usage = immutablePresentationList(usage),
       quotas = immutablePresentationList(quotas),
       detectedTargets = immutablePresentationList(detectedTargets),
       quotaSnapshots = Map<String, ProviderQuotaSnapshot>.unmodifiable(
         quotaSnapshots,
       );

  final List<PresentationMetric> usage;
  final List<PresentationMetric> quotas;
  final int historyDays;
  final PresentationPhase phase;
  final AgentUsageReport? report;
  final List<TargetCandidate> detectedTargets;
  final Map<String, ProviderQuotaSnapshot> quotaSnapshots;
  final bool refreshing;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MonitoringProjection &&
          samePresentationList(other.usage, usage) &&
          samePresentationList(other.quotas, quotas) &&
          other.historyDays == historyDays &&
          other.phase == phase &&
          identical(other.report, report) &&
          samePresentationList(other.detectedTargets, detectedTargets) &&
          _sameQuotaSnapshots(other.quotaSnapshots, quotaSnapshots) &&
          other.refreshing == refreshing &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(usage),
    Object.hashAll(quotas),
    historyDays,
    phase,
    report,
    Object.hashAll(detectedTargets),
    Object.hashAllUnordered(
      quotaSnapshots.entries.map(
        (entry) => Object.hash(entry.key, identityHashCode(entry.value)),
      ),
    ),
    refreshing,
    notice,
  );
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
