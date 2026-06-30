import 'package:flutter/material.dart';

import 'theme.dart';

class AgentsEmptyState extends StatelessWidget {
  const AgentsEmptyState({super.key, required this.onAddTarget});

  final VoidCallback onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined, color: colors.textMuted, size: 32),
          const SizedBox(height: 10),
          Text(
            'No supported targets detected.',
            style: TextStyle(color: colors.textMuted),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onAddTarget,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add target'),
          ),
        ],
      ),
    );
  }
}
