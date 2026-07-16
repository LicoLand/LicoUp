import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class MobileAgentsEmptyState extends StatelessWidget {
  const MobileAgentsEmptyState({
    super.key,
    required this.scanning,
    required this.onAddAgent,
  });

  final bool scanning;
  final VoidCallback onAddAgent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, color: colors.textMuted, size: 34),
            const SizedBox(height: 12),
            Text(
              scanning
                  ? strings.scanningLocalAgents
                  : strings.noLocalAgentsFound,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!scanning) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('mobile-empty-add-agent-button'),
                onPressed: onAddAgent,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(strings.addAgent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
