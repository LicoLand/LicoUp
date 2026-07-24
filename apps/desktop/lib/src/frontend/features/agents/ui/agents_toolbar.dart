import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentsToolbar extends StatelessWidget {
  const AgentsToolbar({
    super.key,
    required this.scanning,
    required this.adding,
    required this.onRescan,
    required this.onAddTarget,
  });

  final bool scanning;
  final bool adding;
  final VoidCallback onRescan;
  final VoidCallback onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      alignment: WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: adding ? null : onAddTarget,
              icon: const Icon(Icons.add, size: 18),
              label: Text(adding ? strings.adding : strings.addTarget),
            ),
            FilledButton.icon(
              onPressed: scanning ? null : onRescan,
              icon: scanning
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.info,
                      ),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: Text(scanning ? strings.scanning : strings.rescan),
            ),
          ],
        ),
      ],
    );
  }
}
