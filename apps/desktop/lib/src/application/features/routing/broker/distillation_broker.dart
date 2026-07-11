import 'package:flutter_client/src/application/features/routing/broker/distillation_prompt.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

/// Default [DistillationBroker]: assemble → dispatch → fidelity → retry/fallback.
class DefaultDistillationBroker implements DistillationBroker {
  DefaultDistillationBroker({
    DistillationPromptBuilder promptBuilder = const DistillationPromptBuilder(),
    List<DistillationAuditRecord>? auditSink,
  }) : _promptBuilder = promptBuilder,
       _auditSink = auditSink;

  final DistillationPromptBuilder _promptBuilder;
  final List<DistillationAuditRecord>? _auditSink;

  /// In-memory audit trail for the process lifetime (tests + callers).
  final List<DistillationAuditRecord> audits = [];

  @override
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  }) async {
    final now = request.now?.call() ?? DateTime.now().toUtc();
    final createdAt = now.toIso8601String();
    var usage = const DistillationUsage();

    final distiller = _selectDistiller(request: request, policy: policy);
    if (distiller == null) {
      final audit = DistillationAuditRecord(
        sourceSessionId: request.sourceSessionId,
        sourceAgentId: request.sourceAgentId,
        distillerAgentId: '',
        package: null,
        fidelity: null,
        usage: usage,
        createdAt: createdAt,
      );
      _recordAudit(audit);
      return DistillationFailure(
        reason:
            'No ready distiller available (primary and alternate are non-ready).',
        distillerUnavailable: true,
        usage: usage,
        audit: audit,
      );
    }

    final contract = policy.distillation.fidelityContract;
    final sourceClasses = request.contentClasses;
    final sessionId = request.distillerSessionId.trim().isEmpty
        ? 'distill-${request.sourceSessionId}'
        : request.distillerSessionId;

    final maxAttempts = contract.retryOnFailure
        ? (1 + contract.maxRetries.clamp(0, 8))
        : 1;

    List<String> missingSections = const [];
    DistillationPackage? lastPackage;
    FidelityCheckResult? lastFidelity;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final corrective = attempt > 0;
      final prompt = _promptBuilder.build(
        request: request,
        policy: policy,
        corrective: corrective,
        missingSections: missingSections,
      );

      final response = await send(
        DistillationLaneRequest(
          agentId: distiller,
          text: prompt,
          sessionId: sessionId,
          corrective: corrective,
        ),
      );
      usage = usage + response.usage;

      if (!response.ok) {
        final audit = _buildAudit(
          request: request,
          distillerAgentId: distiller,
          package: lastPackage,
          fidelity: lastFidelity,
          usage: usage,
          createdAt: createdAt,
        );
        _recordAudit(audit);
        return DistillationFailure(
          reason: response.errorMessage.isEmpty
              ? 'Distiller dispatch failed.'
              : response.errorMessage,
          usage: usage,
          audit: audit,
        );
      }

      final package = parseDistillationPackageResponse(
        response.text,
        sourceSessionId: request.sourceSessionId,
        sourceAgentId: request.sourceAgentId,
        createdAt: createdAt,
      );
      if (package == null) {
        missingSections = List.unmodifiable(contract.requiredSections);
        lastFidelity = FidelityCheckResult(
          passed: false,
          checkedSections: contract.requiredSections,
          missingSections: missingSections,
          message: 'Distiller response was not a valid handoff package.',
        );
        lastPackage = null;
        if (attempt + 1 >= maxAttempts) {
          break;
        }
        continue;
      }

      // Ensure source refs are always the request's, never raw transcript.
      final normalized = DistillationPackage(
        objective: package.objective,
        currentState: package.currentState,
        decisions: package.decisions,
        constraints: package.constraints,
        openItems: package.openItems,
        sourceSessionId: request.sourceSessionId,
        sourceAgentId: request.sourceAgentId,
        createdAt: createdAt,
      );
      lastPackage = normalized;

      final fidelity = checkDistillationFidelity(
        package: normalized,
        contract: contract,
        sourceClasses: sourceClasses,
      );
      lastFidelity = fidelity;

      if (fidelity.passed) {
        final audit = _buildAudit(
          request: request,
          distillerAgentId: distiller,
          package: normalized,
          fidelity: fidelity,
          usage: usage,
          createdAt: createdAt,
        );
        _recordAudit(audit);
        return DistillationSuccess(
          package: normalized,
          fidelity: fidelity,
          usage: usage,
          distillerAgentId: distiller,
          audit: audit,
        );
      }

      missingSections = fidelity.missingSections;
      if (attempt + 1 >= maxAttempts) {
        break;
      }
    }

    final retriesExhausted = contract.retryOnFailure && maxAttempts > 1;
    final audit = _buildAudit(
      request: request,
      distillerAgentId: distiller,
      package: lastPackage,
      fidelity: lastFidelity,
      usage: usage,
      createdAt: createdAt,
    );
    _recordAudit(audit);
    return DistillationFailure(
      reason:
          lastFidelity?.message ??
          'Distillation fidelity check failed; raw undistilled handoff is not permitted.',
      retriesExhausted: retriesExhausted,
      usage: usage,
      audit: audit,
    );
  }

  String? _selectDistiller({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
  }) {
    final ready = request.isDistillerReady ?? (_) => true;
    final primary = policy.distillation.defaultDistiller.trim();
    final alternate = policy.distillation.alternateDistiller.trim();

    if (primary.isNotEmpty && ready(primary)) {
      return primary;
    }
    if (alternate.isNotEmpty && ready(alternate)) {
      return alternate;
    }
    // Agent-level distillation directive: "self" means source agent.
    if (primary == 'self' && ready(request.sourceAgentId)) {
      return request.sourceAgentId;
    }
    if (primary.isEmpty && alternate.isEmpty) {
      // Fall back to source agent when policy omits distillers.
      if (ready(request.sourceAgentId)) {
        return request.sourceAgentId;
      }
    }
    return null;
  }

  DistillationAuditRecord _buildAudit({
    required DistillationRequest request,
    required String distillerAgentId,
    required DistillationPackage? package,
    required FidelityCheckResult? fidelity,
    required DistillationUsage usage,
    required String createdAt,
  }) {
    return DistillationAuditRecord(
      sourceSessionId: request.sourceSessionId,
      sourceAgentId: request.sourceAgentId,
      distillerAgentId: distillerAgentId,
      package: package,
      fidelity: fidelity,
      usage: usage,
      createdAt: createdAt,
    );
  }

  void _recordAudit(DistillationAuditRecord audit) {
    audits.add(audit);
    _auditSink?.add(audit);
  }
}
