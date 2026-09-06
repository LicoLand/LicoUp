import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_dropdown_list.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:licoup/src/frontend/features/settings/ui/settings_dropdown_list.dart';

const _appearanceSegmentLabelWidth = 72.0;
const _appearanceToggleWidth = 320.0;

Widget _appearanceSegmentLabel(String label) {
  return SizedBox(
    width: _appearanceSegmentLabelWidth,
    child: Center(
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );
}

class SettingsDropdownRow<T> extends StatelessWidget {
  const SettingsDropdownRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.onSelected,
    this.dropdownKey,
    this.locked = false,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final T? value;
  final List<SettingsDropdownItem<T>> items;
  final ValueChanged<T> onSelected;
  final Key? dropdownKey;

  /// Appearance locks this instance. Language and other siblings stay
  /// interactive unless they pass [locked] themselves.
  final bool locked;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final presentation = layoutSettingsPresentationOf(context);
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
              Icon(icon, color: colors.textSecondary, size: 18),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(child: Text(title, style: titleStyle)),
            ],
          );
          final dropdown = SettingsDropdownList<T>(
            key: dropdownKey,
            items: items,
            value: value,
            onSelected: onSelected,
            locked: locked,
            enabled: enabled,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleRow,
                const SizedBox(height: LicoContentSpacing.compact),
                dropdown,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: titleRow),
              const SizedBox(width: LicoContentSpacing.item),
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

class SettingsDayNightToggleRow extends StatelessWidget {
  const SettingsDayNightToggleRow({
    super.key,
    required this.selection,
    required this.onChanged,
    this.disabledSegments = const {},
  });

  final AppearanceBrightnessSelection selection;
  final ValueChanged<AppearanceBrightnessSelection> onChanged;

  /// Brightness choices that are not ready yet and render disabled.
  final Set<AppearanceBrightnessSelection> disabledSegments;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final presentation = layoutSettingsPresentationOf(context);
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w600,
    );
    final segments = [
      (
        value: AppearanceBrightnessSelection.system,
        label: strings.followSystem,
      ),
      (
        value: AppearanceBrightnessSelection.light,
        label: strings.appearanceDay,
      ),
      (
        value: AppearanceBrightnessSelection.dark,
        label: strings.appearanceNight,
      ),
    ];
    // SegmentedButton cannot disable individual segments, so the toggle is a
    // custom three-segment row where each segment decides its own enabled
    // state.
    final toggle = SizedBox(
      width: _appearanceToggleWidth,
      child: DecoratedBox(
        key: const Key('appearance-day-night-toggle'),
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          border: Border.all(color: colors.line),
        ),
        child: Row(
          children: [
            for (var index = 0; index < segments.length; index++) ...[
              if (index > 0)
                Container(width: 1, height: 20, color: colors.line),
              Expanded(
                child: _DayNightSegment(
                  label: _appearanceSegmentLabel(segments[index].label),
                  selected: selection == segments[index].value,
                  enabled: !disabledSegments.contains(segments[index].value),
                  onTap: () => onChanged(segments[index].value),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: presentation.rowPadding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final titleRow = Row(
            children: [
              Icon(
                Icons.brightness_6_outlined,
                color: colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Text(strings.appearanceDayNight, style: titleStyle),
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleRow,
                const SizedBox(height: LicoContentSpacing.compact),
                toggle,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: titleRow),
              const SizedBox(width: LicoContentSpacing.item),
              toggle,
            ],
          );
        },
      ),
    );
  }
}

class _DayNightSegment extends StatelessWidget {
  const _DayNightSegment({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Widget label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final foreground = !enabled
        ? colors.textMuted.withAlpha(110)
        : selected
        ? colors.primaryStrong
        : colors.text;
    final background = selected ? colors.surface : Colors.transparent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(7),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: foreground,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
            child: label,
          ),
        ),
      ),
    );
  }
}
