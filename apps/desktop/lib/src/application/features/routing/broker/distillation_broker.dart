import 'dart:math' as math;

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

    final execution = _resolveExecution(request: request, policy: policy);
    final inputWindow = buildDistillationInputWindow(
      request.turns,
      preserveFields: execution.preserveFields,
    );
    final boundedRequest = request.withTurns(inputWindow.turns);

    final distiller = _selectDistiller(
      request: boundedRequest,
      policy: policy,
      preferredDistiller: execution.distiller,
    );
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

    final contract = execution.contract;
    final sourceClasses = boundedRequest.contentClasses;
    var sessionId = request.distillerSessionId.trim();

    final maxAttempts = contract.retryOnFailure
        ? (1 + contract.maxRetries.clamp(0, 8))
        : 1;

    List<String> missingSections = const [];
    DistillationPackage? lastPackage;
    FidelityCheckResult? lastFidelity;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final corrective = attempt > 0;
      final prompt = _promptBuilder.build(
        request: boundedRequest,
        policy: policy,
        contract: contract,
        preserveFields: execution.preserveFields,
        inputWindow: inputWindow,
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
      if (response.sessionId.trim().isNotEmpty) {
        sessionId = response.sessionId.trim();
      }
      usage = usage + response.usage;

      if (!response.ok) {
        final audit = _buildAudit(
          request: boundedRequest,
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
        sourceSessionId: boundedRequest.sourceSessionId,
        sourceAgentId: boundedRequest.sourceAgentId,
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
        sourceSessionId: boundedRequest.sourceSessionId,
        sourceAgentId: boundedRequest.sourceAgentId,
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
          request: boundedRequest,
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

      missingSections = List.unmodifiable({
        ...fidelity.missingSections,
        ...fidelity.uncoveredSections,
      });
      if (attempt + 1 >= maxAttempts) {
        break;
      }
    }

    final retriesExhausted = contract.retryOnFailure && maxAttempts > 1;
    final audit = _buildAudit(
      request: boundedRequest,
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
    required String preferredDistiller,
  }) {
    final ready = request.isDistillerReady ?? (_) => true;
    final configured = preferredDistiller.trim();
    final primary = configured == 'self'
        ? request.sourceAgentId.trim()
        : configured.isNotEmpty
        ? configured
        : policy.distillation.defaultDistiller.trim();
    final alternate = policy.distillation.alternateDistiller.trim();

    if (primary.isNotEmpty && ready(primary)) {
      return primary;
    }
    if (alternate.isNotEmpty && ready(alternate)) {
      return alternate;
    }
    if (primary.isEmpty && alternate.isEmpty) {
      // Fall back to source agent when policy omits distillers.
      if (ready(request.sourceAgentId)) {
        return request.sourceAgentId;
      }
    }
    return null;
  }

  _DistillationExecution _resolveExecution({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
  }) {
    RoutingPolicyAgent? sourceAgent;
    for (final agent in policy.agents) {
      if (agent.id == request.sourceAgentId) {
        sourceAgent = agent;
        break;
      }
    }
    final directive = sourceAgent?.distillation;
    final global = policy.distillation.fidelityContract;
    final supportedSections = const {
      'objective',
      'currentState',
      'decisions',
      'constraints',
      'openItems',
    };
    final preserveFields = <String>{
      ...global.requiredSections,
      ...?directive?.preserveFields.where(supportedSections.contains),
      'objective',
      'decisions',
      'constraints',
    };
    final maxLength = math.min(
      global.maxPackageLength,
      directive?.maxLength ?? global.maxPackageLength,
    );
    return _DistillationExecution(
      distiller:
          directive?.distiller.trim() ??
          policy.distillation.defaultDistiller.trim(),
      preserveFields: Set.unmodifiable(preserveFields),
      contract: RoutingFidelityContract(
        requiredSections: List.unmodifiable(preserveFields),
        maxPackageLength: maxLength,
        retryOnFailure: global.retryOnFailure,
        maxRetries: global.maxRetries,
      ),
    );
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

class _DistillationExecution {
  const _DistillationExecution({
    required this.distiller,
    required this.preserveFields,
    required this.contract,
  });

  final String distiller;
  final Set<String> preserveFields;
  final RoutingFidelityContract contract;
}
