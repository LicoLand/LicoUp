import 'package:flutter/material.dart';

import '../l10n/lico_strings.dart';
import '../services/agent_service.dart';
import 'agent_brand_icon.dart';
import 'theme.dart';

class TargetCard extends StatelessWidget {
  const TargetCard({
    super.key,
    required this.target,
    required this.onInspect,
    required this.onPlan,
  });

  final TargetCandidate target;
  final ValueChanged<String> onInspect;
  final ValueChanged<String> onPlan;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Card(
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AgentBrandIcon(
                  target: target,
                  selected: target.status != 'not-detected',
                  detected: target.status != 'not-detected',
                  size: 40,
                  iconSize: 28,
                ),
                const SizedBox(width: 12),
                Expanded(child: _TargetTitle(target: target)),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    _targetStatusLabel(target, strings),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => onInspect(target.target),
                      child: Text(strings.inspect),
                    ),
                    FilledButton(
                      onPressed: () => onPlan(target.target),
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        minimumSize: const Size(80, 32),
                      ),
                      child: Text(
                        strings.plan,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _targetStatusLabel(TargetCandidate target, LicoStrings strings) {
    return switch (target.status) {
      'configured' => strings.configured,
      'detected' => strings.detected,
      'manual' => strings.manual,
      _ => strings.unavailable,
    };
  }
}

class _TargetTitle extends StatelessWidget {
  const _TargetTitle({required this.target});

  final TargetCandidate target;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final configured = target.configured;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          target.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: configured ? colors.success : colors.textMuted,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              configured ? strings.configured : strings.notConfigured,
              style: TextStyle(
                color: configured ? colors.success : colors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
