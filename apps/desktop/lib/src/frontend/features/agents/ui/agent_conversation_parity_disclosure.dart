import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Sanitized parity disclosure copy for conversation send gates.
/// Never includes paths, digests, hostnames, or machine identity.
class ConversationParityDisclosureCopy {
  const ConversationParityDisclosureCopy({
    required this.reasonCode,
    required this.reasonLabel,
    required this.unblockLabel,
    required this.unblockAction,
  });

  final String reasonCode;
  final String reasonLabel;
  final String? unblockLabel;
  final ConversationParityUnblockAction? unblockAction;
}

enum ConversationParityUnblockAction { rescanAgents, editPolicy }

ConversationParityDisclosureCopy conversationParityDisclosureCopy({
  required LicoStrings strings,
  required String reasonCode,
  bool orchestration = false,
}) {
  if (orchestration) {
    return ConversationParityDisclosureCopy(
      reasonCode: 'orchestration_policy_required',
      reasonLabel: strings.configurePolicyBeforeSend,
      unblockLabel: strings.editPolicy,
      unblockAction: ConversationParityUnblockAction.editPolicy,
    );
  }
  final normalized = reasonCode.trim().isEmpty
      ? 'native_conversation_parity_unverified'
      : reasonCode.trim();
  final label = strings.conversationParityReason(normalized);
  final action = switch (normalized) {
    'evidence_missing' ||
    'evidence_incomplete' ||
    'evidence_stale_or_incomplete' ||
    'runtime_evidence_binding_mismatch' ||
    'native_conversation_parity_unverified' =>
      ConversationParityUnblockAction.rescanAgents,
    _ => null,
  };
  return ConversationParityDisclosureCopy(
    reasonCode: normalized,
    reasonLabel: label,
    unblockLabel: action == null ? null : strings.scanAssistantAgents,
    unblockAction: action,
  );
}

class ConversationParityDisclosurePanel extends StatelessWidget {
  const ConversationParityDisclosurePanel({
    super.key,
    required this.target,
    this.compact = false,
  });

  final TargetCandidate target;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final readiness = target.conversationReadiness;
    final color = switch (readiness) {
      'ready' => colors.success,
      'partial' || 'unverified' => colors.warning,
      'failed' || 'blocked' => colors.error,
      _ => colors.textMuted,
    };
    final matrix = target.conversationCapabilityMatrix;
    final codes = target.conversationSummaryCodes;
    final evidenceAge = target.conversationEvidenceAge.isEmpty
        ? 'absent'
        : target.conversationEvidenceAge;
    final structuralCause = codes.isNotEmpty
        ? codes.first
        : target.conversationBlocker.trim();

    return MenuAnchor(
      key: const Key('conversation-parity-disclosure'),
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceLow),
        elevation: const WidgetStatePropertyAll(6),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: colors.line),
          ),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(10)),
        maximumSize: WidgetStatePropertyAll(
          Size(compact ? 280 : 340, 360),
        ),
      ),
      menuChildren: [
        SizedBox(
          width: compact ? 260 : 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DisclosureLine(
                label: strings.conversationParityEvidenceAge,
                value: strings.conversationParityEvidenceAgeValue(evidenceAge),
                valueKey: const Key('conversation-parity-evidence-age'),
              ),
              if (structuralCause.isNotEmpty)
                _DisclosureLine(
                  label: strings.conversationParityBlockedCause,
                  value: strings.conversationParityReason(structuralCause),
                  valueKey: const Key('conversation-parity-blocked-cause'),
                ),
              const SizedBox(height: 6),
              Text(
                strings.conversationParityCapabilities,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              KeyedSubtree(
                key: const Key('conversation-parity-capabilities'),
                child: matrix.isEmpty
                    ? Text(
                        strings.conversationParityCapabilitiesUnavailable,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                        ),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: matrix.entries.map((entry) {
                          final supported = entry.value == true;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: (supported ? colors.success : colors.textMuted)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${entry.key}:${supported ? 'yes' : 'no'}',
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }).toList(growable: false),
                      ),
              ),
            ],
          ),
        ),
      ],
      builder: (context, controller, child) {
        return InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          borderRadius: BorderRadius.circular(999),
          child: Container(
            key: const Key('conversation-parity-readiness'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.42)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  readiness.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  controller.isOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 14,
                  color: color,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ConversationParitySendGateBanner extends StatelessWidget {
  const ConversationParitySendGateBanner({
    super.key,
    required this.copy,
    this.onUnblock,
  });

  final ConversationParityDisclosureCopy copy;
  final VoidCallback? onUnblock;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      key: const Key('conversation-parity-send-gate'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              copy.reasonLabel,
              key: const Key('conversation-parity-send-gate-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (copy.unblockAction != null && onUnblock != null)
            TextButton(
              key: const Key('conversation-parity-send-gate-unblock'),
              onPressed: onUnblock,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(copy.unblockLabel ?? strings.scanAssistantAgents),
            ),
        ],
      ),
    );
  }
}

class _DisclosureLine extends StatelessWidget {
  const _DisclosureLine({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: TextStyle(color: colors.textMuted, fontSize: 11),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(
              text: value,
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        key: valueKey,
      ),
    );
  }
}
