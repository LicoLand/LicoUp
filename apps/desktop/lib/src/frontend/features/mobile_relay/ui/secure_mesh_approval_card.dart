import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class SecureMeshApprovalCard extends StatelessWidget {
  const SecureMeshApprovalCard({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final busy = controller.isMobileRelayBusy;
    final inbox = controller.secureMeshApprovalInbox;
    final pending = inbox
        .where((item) => item.isPending)
        .toList(growable: false);
    return Container(
      key: const Key('secure-mesh-approval-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  strings.remoteApproval,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              OutlinedButton(
                key: const Key('secure-mesh-approval-refresh'),
                onPressed: busy
                    ? null
                    : () => controller.refreshSecureMeshApprovalInbox(),
                child: Text(strings.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            strings.remoteApprovalHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: 14),
          if (pending.isEmpty)
            Text(
              strings.remoteApprovalEmpty,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          for (final item in pending.take(8)) ...[
            const SizedBox(height: 10),
            Container(
              key: Key('secure-mesh-approval-item-${item.pendingOperationId}'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.line.withAlpha(70)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InfoLine(label: strings.agent, value: item.requesterAgentId),
                  _InfoLine(label: strings.risk, value: item.riskLevel),
                  _InfoLine(label: strings.summary, value: item.displaySummary),
                  _InfoLine(label: strings.expires, value: item.expiresAt),
                  if (item.requestedTools.isNotEmpty)
                    _InfoLine(
                      label: strings.tools,
                      value: item.requestedTools.join(', '),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        key: Key(
                          'secure-mesh-approval-allow-${item.pendingOperationId}',
                        ),
                        onPressed: busy || item.responseNonce.trim().isEmpty
                            ? null
                            : () => controller.resolveSecureMeshApproval(
                                pendingOperationId: item.pendingOperationId,
                                allow: true,
                                respondingEndpointId:
                                    item.originEndpointId.isEmpty
                                    ? 'local-trusted-endpoint'
                                    : item.originEndpointId,
                                responseNonce: item.responseNonce,
                              ),
                        child: Text(strings.allow),
                      ),
                      OutlinedButton(
                        key: Key(
                          'secure-mesh-approval-deny-${item.pendingOperationId}',
                        ),
                        onPressed: busy || item.responseNonce.trim().isEmpty
                            ? null
                            : () => controller.resolveSecureMeshApproval(
                                pendingOperationId: item.pendingOperationId,
                                allow: false,
                                respondingEndpointId:
                                    item.originEndpointId.isEmpty
                                    ? 'local-trusted-endpoint'
                                    : item.originEndpointId,
                                responseNonce: item.responseNonce,
                              ),
                        child: Text(strings.deny),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (inbox.any((item) => !item.isPending)) ...[
            const SizedBox(height: 16),
            Text(
              strings.remoteApprovalHistory,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            for (final item in inbox.where((entry) => !entry.isPending).take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${item.requesterAgentId} · ${_statusLabel(strings, item)}',
                  key: Key(
                    'secure-mesh-approval-history-${item.pendingOperationId}',
                  ),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(LicoStrings strings, SecureMeshApprovalRequest item) {
    return switch (item.status) {
      SecureMeshApprovalStatus.pending => strings.remoteApprovalStatusPending,
      SecureMeshApprovalStatus.resolved =>
        item.decision == SecureMeshApprovalDecision.allow
            ? strings.remoteApprovalStatusAllowed
            : strings.remoteApprovalStatusDenied,
      SecureMeshApprovalStatus.expired => strings.remoteApprovalStatusExpired,
      SecureMeshApprovalStatus.failed => strings.remoteApprovalStatusFailed,
    };
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
