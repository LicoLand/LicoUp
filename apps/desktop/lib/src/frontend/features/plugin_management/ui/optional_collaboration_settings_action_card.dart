import 'package:flutter/material.dart';

final class OptionalCollaborationSettingsActionCard extends StatelessWidget {
  const OptionalCollaborationSettingsActionCard({
    super.key,
    required this.title,
    required this.confirmation,
    required this.buttonLabel,
    required this.value,
    required this.busy,
    required this.onChanged,
    required this.onPressed,
    this.detail = '',
    this.destructive = false,
  });

  final String title;
  final String detail;
  final String confirmation;
  final String buttonLabel;
  final bool value;
  final bool busy;
  final bool destructive;
  final ValueChanged<bool?> onChanged;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(detail),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: value,
              onChanged: busy ? null : onChanged,
              title: Text(confirmation),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: destructive
                  ? OutlinedButton(
                      onPressed: busy ? null : onPressed,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      child: Text(buttonLabel),
                    )
                  : FilledButton(
                      onPressed: busy ? null : onPressed,
                      child: Text(buttonLabel),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
