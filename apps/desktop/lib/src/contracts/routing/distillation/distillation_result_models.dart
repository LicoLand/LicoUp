import 'distillation_package_models.dart';
import 'distillation_usage_audit.dart';

sealed class DistillationResult {
  const DistillationResult();
}

class DistillationSuccess extends DistillationResult {
  const DistillationSuccess({
    required this.package,
    required this.fidelity,
    this.usage = const DistillationUsage(),
    this.distillerAgentId = '',
    this.audit = const DistillationAuditRecord.empty(),
  });

  final DistillationPackage package;
  final FidelityCheckResult fidelity;
  final DistillationUsage usage;
  final String distillerAgentId;
  final DistillationAuditRecord audit;
}

class DistillationFailure extends DistillationResult {
  const DistillationFailure({
    required this.reason,
    this.retriesExhausted = false,
    this.distillerUnavailable = false,
    this.usage = const DistillationUsage(),
    this.audit = const DistillationAuditRecord.empty(),
  });

  final String reason;
  final bool retriesExhausted;
  final bool distillerUnavailable;
  final DistillationUsage usage;
  final DistillationAuditRecord audit;
}
