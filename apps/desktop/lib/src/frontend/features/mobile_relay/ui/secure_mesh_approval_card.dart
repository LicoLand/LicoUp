import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

class SecureMeshApprovalCard extends StatelessWidget {
  const SecureMeshApprovalCard({
    super.key,
    required this.projection,
    required this.intents,
  });

  final MobileRelayProjection projection;
  final IntentSink<MobileRelayIntent> intents;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final pending = projection.approvals
        .where((item) => item.state == RelayApprovalState.pending)
        .toList(growable: false);
    return Container(
      key: const Key('secure-mesh-approval-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.card),
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
                onPressed: projection.busy
                    ? null
                    : () => intents.send(const RefreshRelayApprovals()),
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
              key: Key('secure-mesh-approval-item-${item.id}'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LicoRadius.floating),
                border: Border.all(color: colors.line.withAlpha(70)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InfoLine(label: strings.agent, value: item.requesterLabel),
                  _InfoLine(label: strings.risk, value: item.capabilityLabel),
                  _InfoLine(label: strings.summary, value: item.summary),
                  _InfoLine(label: strings.expires, value: item.expiresLabel),
                  if (item.requestedToolLabels.isNotEmpty)
                    _InfoLine(
                      label: strings.tools,
                      value: item.requestedToolLabels.join(', '),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        key: Key('secure-mesh-approval-allow-${item.id}'),
                        onPressed: projection.busy || !item.resolvable
                            ? null
                            : () => intents.send(
                                ResolveRelayApproval(item.id, true),
                              ),
                        child: Text(strings.allow),
                      ),
                      OutlinedButton(
                        key: Key('secure-mesh-approval-deny-${item.id}'),
                        onPressed: projection.busy || !item.resolvable
                            ? null
                            : () => intents.send(
                                ResolveRelayApproval(item.id, false),
                              ),
                        child: Text(strings.deny),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          if (projection.approvals.any(
            (item) => item.state != RelayApprovalState.pending,
          )) ...[
            const SizedBox(height: 16),
            Text(
              strings.remoteApprovalHistory,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            for (final item
                in projection.approvals
                    .where((entry) => entry.state != RelayApprovalState.pending)
                    .take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${item.requesterLabel} · ${_statusLabel(strings, item)}',
                  key: Key('secure-mesh-approval-history-${item.id}'),
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

  String _statusLabel(LicoStrings strings, RelayApprovalProjection item) {
    return switch (item.state) {
      RelayApprovalState.pending => strings.remoteApprovalStatusPending,
      RelayApprovalState.allowed => strings.remoteApprovalStatusAllowed,
      RelayApprovalState.denied => strings.remoteApprovalStatusDenied,
      RelayApprovalState.expired => strings.remoteApprovalStatusExpired,
      RelayApprovalState.failed => strings.remoteApprovalStatusFailed,
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
