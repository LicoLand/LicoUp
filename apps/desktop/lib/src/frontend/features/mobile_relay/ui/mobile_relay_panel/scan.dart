import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class MobileRelayScanPairingPrompt extends StatelessWidget {
  const MobileRelayScanPairingPrompt({
    super.key,
    required this.colors,
    required this.label,
  });

  final LicoThemeColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('mobile-relay-scan-pairing-prompt'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          MinimalScanIcon(color: colors.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
