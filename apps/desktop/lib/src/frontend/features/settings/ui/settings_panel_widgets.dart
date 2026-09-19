import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_dropdown_list.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

export 'package:licoup/src/frontend/features/settings/ui/settings_dropdown_list.dart';

const _appearanceSegmentLabelWidth = 72.0;
const _appearanceToggleWidth = 320.0;

/// One segmented control recipe for settings surfaces: a hairline rounded
/// track with an inset sliding thumb — the iOS idiom, in the interface's own
/// rounded-rectangle language. Shared by the appearance day/night toggle and
/// the client-update channel selector.
class SettingsSegmentedControl<T> extends StatelessWidget {
  const SettingsSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.disabledSegments = const {},
    this.enabled = true,
    this.segmentMinWidth = 88,
    this.width,
  });

  final List<({T value, String label})> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final Set<T> disabledSegments;
  final bool enabled;
  final double segmentMinWidth;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final count = segments.length;
    final selectedIndex = segments.indexWhere(
      (segment) => segment.value == selected,
    );
    final effectiveWidth = width ?? segmentMinWidth * count + 4;
    return SizedBox(
      width: effectiveWidth,
      child: DecoratedBox(
        decoration: continuousHairlineDecoration(
          color: colors.surfaceLow,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          stroke: colors.line,
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Opacity(
            opacity: enabled ? 1 : 0.55,
            child: SizedBox(
              height: 28,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final segmentWidth = constraints.maxWidth / count;
                  return Stack(
                    children: [
                      if (selectedIndex >= 0)
                        AnimatedPositioned(
                          duration: context.motion(LicoMotion.micro),
                          curve: LicoMotion.standard,
                          left: selectedIndex * segmentWidth,
                          width: segmentWidth,
                          top: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(
                                LicoRadius.chip - 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: colors.text.withValues(
                                    alpha: colors.isDark ? 0.22 : 0.10,
                                  ),
                                  blurRadius: 5,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Row(
                        children: [
                          for (var index = 0; index < count; index++)
                            Expanded(
                              child: _SettingsSegment(
                                label: segments[index].label,
                                selected: index == selectedIndex,
                                enabled:
                                    enabled &&
                                    !disabledSegments.contains(
                                      segments[index].value,
                                    ),
                                onTap: () => onChanged(segments[index].value),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSegment extends StatelessWidget {
  const _SettingsSegment({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
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
        : colors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(LicoRadius.chip - 2),
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: context.motion(LicoMotion.micro),
              curve: LicoMotion.standard,
              style: TextStyle(
                color: foreground,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                height: 1.15,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
    );
  }
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
    final toggle = SettingsSegmentedControl<AppearanceBrightnessSelection>(
      key: const Key('appearance-day-night-toggle'),
      segments: segments,
      selected: selection,
      onChanged: onChanged,
      disabledSegments: disabledSegments,
      segmentMinWidth: _appearanceSegmentLabelWidth,
      width: _appearanceToggleWidth,
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
