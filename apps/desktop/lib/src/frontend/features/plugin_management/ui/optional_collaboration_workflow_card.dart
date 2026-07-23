import 'package:flutter/material.dart';

final class OptionalCollaborationWorkflowCard extends StatelessWidget {
  const OptionalCollaborationWorkflowCard({
    super.key,
    required this.icon,
    required this.title,
    required this.policy,
    required this.isChinese,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String policy;
  final bool isChinese;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _PolicyBadge(label: isChinese ? '仅手动' : 'Manual only'),
              ],
            ),
            const SizedBox(height: 8),
            Text(policy, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

final class _PolicyBadge extends StatelessWidget {
  const _PolicyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
