import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class SettingsDropdownRow<T> extends StatelessWidget {
  const SettingsDropdownRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: presentation.rowPadding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final titleRow = Row(
            children: [
              Icon(icon, color: colors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: titleStyle)),
            ],
          );
          final dropdown = DropdownButtonFormField<T>(
            initialValue: value,
            decoration: _dropdownDecorationWithoutLabel(),
            items: items,
            onChanged: onChanged,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [titleRow, const SizedBox(height: 8), dropdown],
            );
          }
          return Row(
            children: [
              Expanded(child: titleRow),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: dropdown,
              ),
            ],
          );
        },
      ),
    );
  }
}

InputDecoration _dropdownDecorationWithoutLabel() {
  return const InputDecoration(
    floatingLabelBehavior: FloatingLabelBehavior.never,
  );
}
