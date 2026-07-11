import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/route_decision_record.dart';
import 'package:flutter_client/src/contracts/routing/route_history.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Policy identity + reload/validation state (V-007-A).
class RoutingPolicyStatusPanel extends StatelessWidget {
  const RoutingPolicyStatusPanel({
    super.key,
    required this.policy,
    this.validationError,
    this.reloading = false,
  });

  final RoutingPolicyDocument policy;
  final RoutingPolicyValidationError? validationError;
  final bool reloading;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final valid = validationError == null;
    final statusColor = valid ? colors.success : colors.error;
    final statusLabel = reloading
        ? 'Reloading'
        : valid
        ? 'Valid'
        : 'Error';
    return Container(
      key: const Key('routing-policy-status'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            policy.label.trim().isEmpty ? policy.id : policy.label,
            key: const Key('routing-policy-name'),
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'version ${policy.schemaVersion}',
            key: const Key('routing-policy-version'),
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            statusLabel,
            key: const Key('routing-policy-validation-state'),
            style: TextStyle(color: statusColor, fontSize: 12),
          ),
          if (validationError != null) ...[
            const SizedBox(height: 4),
            Text(
              validationError!.message,
              key: const Key('routing-policy-validation-message'),
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Per-dispatch decision disclosure from the contract type only (V-007-B).
class RoutingDecisionDisclosure extends StatelessWidget {
  const RoutingDecisionDisclosure({super.key, required this.decision});

  final RouteDecisionRecord decision;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      key: const Key('routing-decision-disclosure'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Chosen: ${decision.chosenAgentLabel.isEmpty ? decision.chosenAgentId : decision.chosenAgentLabel}',
            key: const Key('routing-decision-chosen'),
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Alternatives',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          for (final candidate in decision.alternatives)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${candidate.agentLabel.isEmpty ? candidate.agentId : candidate.agentLabel}'
                ' · priority ${candidate.priority}'
                ' · headroom ${candidate.allowanceHeadroom}'
                ' · ${candidate.reason}',
                key: Key('routing-decision-candidate-${candidate.agentId}'),
                style: TextStyle(color: colors.text, fontSize: 12),
              ),
            ),
          if (decision.excluded.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Excluded',
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
            for (final exclusion in decision.excluded)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${exclusion.agentLabel.isEmpty ? exclusion.agentId : exclusion.agentLabel}'
                  ' · ${exclusion.reason}',
                  key: Key('routing-decision-excluded-${exclusion.agentId}'),
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Read-only distillation package preview with privacy redaction (V-007-C/F).
class RoutingDistillationPreview extends StatelessWidget {
  const RoutingDistillationPreview({
    super.key,
    required this.package,
    this.rawSourceText = '',
  });

  final DistillationPackage package;

  /// When provided, asserted absent from the rendered tree (privacy).
  final String rawSourceText;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      key: const Key('routing-distillation-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Handoff preview',
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _section(colors, 'Objective', package.objective),
          _section(colors, 'Current state', package.currentState),
          _section(colors, 'Decisions', package.decisions.join('; ')),
          _section(colors, 'Constraints', package.constraints.join('; ')),
          _section(colors, 'Open items', package.openItems.join('; ')),
          const SizedBox(height: 6),
          Text(
            'Source session ${package.sourceSessionId} · agent ${package.sourceAgentId}',
            key: const Key('routing-distillation-source-refs'),
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _section(LicoThemeColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: colors.textMuted, fontSize: 11)),
          Text(
            value,
            style: TextStyle(color: colors.text, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Per-task chronological route history (V-007-D).
class RoutingRouteHistoryPanel extends StatelessWidget {
  const RoutingRouteHistoryPanel({super.key, required this.entries});

  final List<RouteHistoryEntry> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      key: const Key('routing-route-history'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Route history',
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No switches yet',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${entry.timestamp} · ${entry.sourceAgentId} → ${entry.targetAgentId}'
                ' · ${entry.decision.chosenAgentId}'
                '${entry.failed ? ' · failed' : ''}',
                key: Key('routing-route-history-${entry.timestamp}'),
                style: TextStyle(color: colors.text, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
