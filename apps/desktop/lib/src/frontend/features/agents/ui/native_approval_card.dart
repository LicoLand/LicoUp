import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

/// Allow/Deny decisions for the local native permission requests an Agent
/// parked in the visible conversation.
final class NativeApprovalCard extends StatelessWidget {
  const NativeApprovalCard({
    super.key,
    required this.approvals,
    required this.intents,
    this.errorCode = '',
  });

  final List<NativeApprovalRequestProjection> approvals;
  final IntentSink<ConversationIntent> intents;
  final String errorCode;

  @override
  Widget build(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    final colors = context.licoColors;
    return Card(
      key: const Key('native-approval-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined, color: colors.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chinese ? '等待审批' : 'Waiting for approval',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            for (final approval in approvals)
              _ApprovalRow(
                key: Key('native-approval-${approval.pendingOperationId}'),
                approval: approval,
                intents: intents,
                chinese: chinese,
              ),
            if (errorCode.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  chinese
                      ? '审批未送达（$errorCode），请重试。'
                      : 'The decision was not delivered ($errorCode). '
                            'Try again.',
                  key: const Key('native-approval-error'),
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _ApprovalRow extends StatelessWidget {
  const _ApprovalRow({
    super.key,
    required this.approval,
    required this.intents,
    required this.chinese,
  });

  final NativeApprovalRequestProjection approval;
  final IntentSink<ConversationIntent> intents;
  final bool chinese;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final summary = approval.summary.isEmpty
        ? (chinese ? '智能体请求权限' : 'The agent requests permission')
        : approval.summary;
    final enabled = !approval.resolving;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${approval.agentId} · $summary'),
                if (approval.requestedTools.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      approval.requestedTools.join(', '),
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('native-approval-deny-${approval.pendingOperationId}'),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            onPressed: enabled
                ? () => intents.send(
                    ResolveNativeApproval(
                      approval.pendingOperationId,
                      allow: false,
                    ),
                  )
                : null,
            child: Text(chinese ? '拒绝' : 'Deny'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            key: Key('native-approval-allow-${approval.pendingOperationId}'),
            onPressed: enabled
                ? () => intents.send(
                    ResolveNativeApproval(
                      approval.pendingOperationId,
                      allow: true,
                    ),
                  )
                : null,
            child: Text(chinese ? '允许' : 'Allow'),
          ),
        ],
      ),
    );
  }
}
