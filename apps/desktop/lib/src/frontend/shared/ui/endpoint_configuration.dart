import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared URL editor used by local and remote endpoint cards.
final class EndpointUrlField extends StatelessWidget {
  const EndpointUrlField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.hintText,
    required this.saveTooltip,
    required this.onSave,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hintText;
  final String saveTooltip;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.link_outlined),
        hintText: hintText,
        suffixIcon: IconButton(
          tooltip: saveTooltip,
          icon: const Icon(Icons.save_outlined),
          onPressed: enabled ? onSave : null,
        ),
      ),
      onSubmitted: enabled ? (_) => onSave?.call() : null,
    );
  }
}

/// Shared two-column endpoint status row.
class EndpointStatusRow extends StatelessWidget {
  const EndpointStatusRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: TextStyle(color: colors.textMuted)),
          ),
          Expanded(
            child: SelectableText(
              display,
              style: TextStyle(color: valueColor ?? colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
