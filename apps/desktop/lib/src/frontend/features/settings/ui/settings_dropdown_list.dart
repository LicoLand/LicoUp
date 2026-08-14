import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// One row in a [SettingsDropdownList].
@immutable
class SettingsDropdownItem<T> {
  const SettingsDropdownItem({
    required this.value,
    required this.label,
    this.key,
  });

  final T value;
  final String label;
  final Key? key;
}

/// Shared settings dropdown chrome: filled rounded bar, current value on the
/// left, caret on the right; the open menu highlights the selected row and
/// shows a checkmark.
///
/// Lock is per instance. The widget itself stays interactive unless [locked]
/// is true or [enabled] is false.
class SettingsDropdownList<T> extends StatelessWidget {
  const SettingsDropdownList({
    super.key,
    required this.items,
    required this.value,
    required this.onSelected,
    this.locked = false,
    this.enabled = true,
  });

  final List<SettingsDropdownItem<T>> items;
  final T? value;
  final ValueChanged<T> onSelected;

  /// When true, tapping does not open the menu or change the selection.
  final bool locked;

  /// When false, tapping does not open the menu or change the selection.
  final bool enabled;

  bool get _interactive => enabled && !locked;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DropdownButtonFormField<T>(
      key: ValueKey<Object?>(value),
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        floatingLabelBehavior: FloatingLabelBehavior.never,
      ),
      selectedItemBuilder: (context) {
        return [
          for (final item in items)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ];
      },
      items: [
        for (final item in items)
          DropdownMenuItem<T>(
            key: item.key,
            value: item.value,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item.value == value
                          ? colors.primaryStrong
                          : colors.text,
                      fontWeight: item.value == value
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (item.value == value)
                  Icon(Icons.check, size: 16, color: colors.accentStrong),
              ],
            ),
          ),
      ],
      onChanged: _interactive
          ? (selected) {
              if (selected != null) {
                onSelected(selected);
              }
            }
          : null,
    );
  }
}
