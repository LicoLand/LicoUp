import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _appearanceDaySegment = 'day';
const _appearanceNightSegment = 'night';
const _appearanceSystemSegment = 'system';
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
              Icon(icon, color: colors.textSecondary, size: 18),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(child: Text(title, style: titleStyle)),
            ],
          );
          final dropdown = DropdownButtonFormField<T>(
            initialValue: value,
            isExpanded: true,
            decoration: _dropdownDecorationWithoutLabel(),
            items: items,
            onChanged: onChanged,
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

InputDecoration _dropdownDecorationWithoutLabel() {
  return const InputDecoration(
    floatingLabelBehavior: FloatingLabelBehavior.never,
  );
}

class SettingsDayNightToggleRow extends StatelessWidget {
  const SettingsDayNightToggleRow({
    super.key,
    required this.selection,
    required this.onChanged,
  });

  final AppearanceBrightnessSelection selection;
  final ValueChanged<AppearanceBrightnessSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w600,
    );
    final selected = switch (selection) {
      AppearanceBrightnessSelection.light => _appearanceDaySegment,
      AppearanceBrightnessSelection.dark => _appearanceNightSegment,
      AppearanceBrightnessSelection.system => _appearanceSystemSegment,
    };
    final toggle = SizedBox(
      width: _appearanceToggleWidth,
      child: SegmentedButton<String>(
        key: const Key('appearance-day-night-toggle'),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: _appearanceSystemSegment,
            label: _appearanceSegmentLabel(strings.followSystem),
          ),
          ButtonSegment(
            value: _appearanceDaySegment,
            label: _appearanceSegmentLabel(strings.appearanceDay),
          ),
          ButtonSegment(
            value: _appearanceNightSegment,
            label: _appearanceSegmentLabel(strings.appearanceNight),
          ),
        ],
        selected: {selected},
        onSelectionChanged: (value) {
          onChanged(switch (value.single) {
            _appearanceDaySegment => AppearanceBrightnessSelection.light,
            _appearanceNightSegment => AppearanceBrightnessSelection.dark,
            _ => AppearanceBrightnessSelection.system,
          });
        },
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
