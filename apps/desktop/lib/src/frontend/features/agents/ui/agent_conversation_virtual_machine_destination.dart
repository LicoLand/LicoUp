import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shows the exact SSH destination selected for a VM-backed conversation.
///
/// The caller projects only the display-safe destination, keeping this shared
/// presentation component independent from target and runtime models.
class ConversationVirtualMachineDestinationChip extends StatelessWidget {
  const ConversationVirtualMachineDestinationChip({
    super.key,
    required this.destination,
  });

  final String destination;

  @override
  Widget build(BuildContext context) {
    if (destination.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.licoColors;
    final label = LicoStrings.of(
      context,
    ).virtualMachineDestination(destination);
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Container(
          key: const Key('conversation-virtual-machine-destination'),
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns_outlined, size: 13, color: colors.accent),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  'SSH · $destination',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
