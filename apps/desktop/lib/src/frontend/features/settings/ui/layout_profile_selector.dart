import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

const _eagerProfileOptionLimit = 12;
const _virtualizedVisibleRows = 3;

final class LayoutProfileSelector extends StatelessWidget {
  const LayoutProfileSelector({
    super.key,
    required this.binding,
    required this.registry,
    required this.surface,
  });

  final SettingsBinding binding;
  final LayoutRegistry registry;
  final LayoutRuntimeSurface surface;

  @override
  Widget build(BuildContext context) {
    return AsyncRegion<SettingsLayoutInputs, IntentSink<SettingsIntent>>(
      source: settingsLayoutInputsProvider,
      actions: binding.intents,
      loading: (_, _) => const SizedBox.shrink(),
      data: (context, inputs, _) => _buildProjection(context, inputs),
    );
  }

  Widget _buildProjection(BuildContext context, SettingsLayoutInputs settings) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final choices = {
      for (final choice in settings.layoutChoices) choice.id: choice,
    };
    final profiles = registry.definitions.values
        .map((definition) => definition.profile)
        .where(
          (profile) =>
              choices.containsKey(profile.id.value) &&
              registry.definition(profile.id).bundles.containsKey(surface),
        )
        .toList(growable: false);
    final committing = settings.layoutPhase == PresentationPhase.applying;
    final loading = settings.layoutPhase == PresentationPhase.loading;
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final presentation = layoutSettingsPresentationOf(context);

    return presentation.frameSelector(
      context,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: strings.layoutProfile,
        child: Column(
          key: const ValueKey<String>('layout-profile-selector'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading)
              _LayoutSelectorStatus(
                key: const ValueKey<String>('layout-selector-loading'),
                label: strings.layoutLoading,
                progress: true,
                color: colors.accent,
              )
            else ...[
              if (settings.layoutFailureReasonCode case final errorCode
                  when errorCode.isNotEmpty)
                _LayoutSelectorStatus(
                  key: const ValueKey<String>('layout-selector-error'),
                  label: _layoutErrorLabel(strings, errorCode, errorCode),
                  progress: false,
                  color: colors.error,
                ),
              if (profiles.isNotEmpty)
                FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = LicoContentSpacing.item;
                      final gridPadding = presentation.selectorGridPadding
                          .resolve(Directionality.of(context));
                      final available =
                          constraints.maxWidth - gridPadding.horizontal;
                      final columnCount = _layoutColumnCapacity(
                        available,
                      ).clamp(1, profiles.length).toInt();
                      final itemWidth =
                          (available - gap * (columnCount - 1)) / columnCount;
                      Widget optionAt(int index) => SizedBox(
                        width: itemWidth,
                        child: FocusTraversalOrder(
                          order: NumericFocusOrder(index.toDouble()),
                          child: _LayoutProfileOption(
                            profile: profiles[index],
                            preview: registry
                                .definition(profiles[index].id)
                                .bundles[surface]!
                                .previewBuilder(
                                  context,
                                  _previewStyleFor(
                                    profiles[index],
                                    settings,
                                    choices,
                                  ),
                                ),
                            label: profiles[index].label.resolve(
                              strings.locale.languageCode,
                            ),
                            currentLabel: strings.currentLayout,
                            selected:
                                choices[profiles[index].id.value]!.selected,
                            committed:
                                choices[profiles[index].id.value]!.selected,
                            // Enabled state comes from the layout manager's
                            // per-profile selection choices (both built-in
                            // desktop layouts are selectable).
                            enabled:
                                !committing &&
                                choices[profiles[index].id.value]!.enabled,
                            reducedMotion: reducedMotion,
                            onPressed: () {
                              binding.intents.send(
                                SetLayoutPreference(profiles[index].id.value),
                              );
                            },
                          ),
                        ),
                      );
                      final options =
                          profiles.length <= _eagerProfileOptionLimit
                          ? Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                for (
                                  var index = 0;
                                  index < profiles.length;
                                  index++
                                )
                                  optionAt(index),
                              ],
                            )
                          : _VirtualizedLayoutProfileGrid(
                              itemCount: profiles.length,
                              columnCount: columnCount,
                              itemWidth: itemWidth,
                              gap: gap,
                              itemBuilder: optionAt,
                            );
                      return Padding(padding: gridPadding, child: options);
                    },
                  ),
                ),
              // The column-style control belongs to the committed profile and
              // only exists on desktop: mobile ignores profile styles, and a
              // profile without declared styles yields no choices.
              if (surface == LayoutRuntimeSurface.desktop &&
                  settings.layoutStyleChoices.isNotEmpty)
                for (final profile in profiles)
                  if (choices[profile.id.value]!.selected &&
                      profile.styles.isNotEmpty)
                    Padding(
                      key: const ValueKey<String>('layout-style-selector'),
                      padding: EdgeInsets.fromLTRB(
                        presentation.selectorGridPadding
                            .resolve(Directionality.of(context))
                            .left,
                        LicoContentSpacing.item,
                        presentation.selectorGridPadding
                            .resolve(Directionality.of(context))
                            .right,
                        0,
                      ),
                      child: _LayoutStyleSelector(
                        label: strings.layoutColumns,
                        profile: profile,
                        choices: settings.layoutStyleChoices,
                        languageCode: strings.locale.languageCode,
                        enabled: !committing,
                        onChanged: (styleId) => binding.intents.send(
                          SetLayoutStyle(profile.id.value, styleId.value),
                        ),
                      ),
                    ),
              const SizedBox(height: LicoContentSpacing.item),
              if (committing)
                _LayoutSelectorStatus(
                  key: const ValueKey<String>('layout-selector-committing'),
                  label: strings.layoutCommitting,
                  progress: true,
                  color: colors.accent,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The arrangement a profile card previews: the effective style for the
/// selected profile (its committed choice once available, else its declared
/// default) and the declared default for every other profile. Profiles that
/// declare no styles preview null.
LayoutStyleId? _previewStyleFor(
  LayoutProfileDescriptor profile,
  SettingsLayoutInputs settings,
  Map<String, PresentationChoice> choices,
) {
  if (profile.styles.isEmpty) {
    return null;
  }
  final isSelected = choices[profile.id.value]?.selected ?? false;
  if (isSelected) {
    for (final choice in settings.layoutStyleChoices) {
      if (choice.selected) {
        try {
          return LayoutStyleId.parse(choice.id);
        } on FormatException {
          break;
        }
      }
    }
  }
  return profile.defaultStyleId;
}

/// The column arrangement picker below the profile cards, built with the same
/// segmented control the appearance selector uses. Only rendered when the
/// committed profile declares styles on the desktop surface.
final class _LayoutStyleSelector extends StatelessWidget {
  const _LayoutStyleSelector({
    required this.label,
    required this.profile,
    required this.choices,
    required this.languageCode,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final LayoutProfileDescriptor profile;
  final List<PresentationChoice> choices;
  final String languageCode;
  final bool enabled;
  final ValueChanged<LayoutStyleId> onChanged;

  @override
  Widget build(BuildContext context) {
    LayoutStyleId? selected;
    for (final choice in choices) {
      if (choice.selected) {
        try {
          selected = LayoutStyleId.parse(choice.id);
        } on FormatException {
          selected = null;
        }
        break;
      }
    }
    final resolved = selected ?? profile.defaultStyleId;
    if (resolved == null) {
      return const SizedBox.shrink();
    }
    final disabled = <LayoutStyleId>{};
    for (final choice in choices) {
      if (choice.enabled) {
        continue;
      }
      try {
        disabled.add(LayoutStyleId.parse(choice.id));
      } on FormatException {
        continue;
      }
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: SettingsSegmentedControl<LayoutStyleId>(
        key: const ValueKey<String>('layout-style-segments'),
        segments: [
          for (final style in profile.styles)
            (value: style.id, label: style.label.resolve(languageCode)),
        ],
        selected: resolved,
        disabledSegments: disabled,
        enabled: enabled,
        onChanged: onChanged,
      ),
    );
  }
}

String _layoutErrorLabel(
  LicoStrings strings,
  String reasonCode,
  String fallback,
) {
  for (final code in LayoutSelectionErrorCode.values) {
    if (code.name == reasonCode) return strings.layoutSelectionError(code);
  }
  return fallback;
}

int _layoutColumnCapacity(double availableWidth) {
  if (availableWidth < 400) {
    return 1;
  }
  if (availableWidth < 780) {
    return 2;
  }
  // Wide grids grow with geometry; no catalog cardinality is encoded here.
  return (availableWidth / 195).floor();
}

final class _VirtualizedLayoutProfileGrid extends StatelessWidget {
  const _VirtualizedLayoutProfileGrid({
    required this.itemCount,
    required this.columnCount,
    required this.itemWidth,
    required this.gap,
    required this.itemBuilder,
  });

  final int itemCount;
  final int columnCount;
  final double itemWidth;
  final double gap;
  final Widget Function(int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final rowCount = (itemCount / columnCount).ceil();
    final visibleRows = rowCount.clamp(1, _virtualizedVisibleRows).toInt();
    final itemHeight = itemWidth * (10 / 16) + 52;
    final height = visibleRows * itemHeight + (visibleRows - 1) * gap;
    return SizedBox(
      height: height,
      child: GridView.builder(
        key: const ValueKey<String>('layout-profile-virtualized-grid'),
        primary: false,
        itemCount: itemCount,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columnCount,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: itemHeight,
        ),
        itemBuilder: (context, index) => itemBuilder(index),
      ),
    );
  }
}

final class _LayoutProfileOption extends StatelessWidget {
  const _LayoutProfileOption({
    required this.profile,
    required this.preview,
    required this.label,
    required this.currentLabel,
    required this.selected,
    required this.committed,
    required this.enabled,
    required this.reducedMotion,
    required this.onPressed,
  });

  final LayoutProfileDescriptor profile;
  final Widget preview;
  final String label;
  final String currentLabel;
  final bool selected;
  final bool committed;
  final bool enabled;
  final bool reducedMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final borderColor = selected ? colors.selectionInk : colors.line;
    final activate = enabled ? onPressed : null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                activate?.call();
                return null;
              },
            ),
          },
          child: AnimatedContainer(
            key: ValueKey<String>('layout-profile-option-${profile.id.value}'),
            duration: reducedMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            decoration: continuousHairlineDecoration(
              color: selected
                  ? colors.surface
                  : (colors.isDark
                        ? LicoPaneGlass.contentInnerCardFill
                        : colors.surfaceLow),
              stroke: borderColor,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: activate,
                canRequestFocus: enabled,
                mouseCursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                child: Padding(
                  padding: const EdgeInsets.all(LicoContentSpacing.compact),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Side gutters keep the thumbnail from touching the
                      // option card edge; the canvas stays full width below.
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LicoContentSpacing.compact,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(LicoRadius.well),
                          child: AspectRatio(
                            aspectRatio: 16 / 10,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: 320,
                                child: RepaintBoundary(child: preview),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: LicoContentSpacing.compact),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (committed)
                            Tooltip(
                              message: currentLabel,
                              child: Icon(
                                Icons.check_circle,
                                size: 16,
                                color: colors.accent,
                                semanticLabel: currentLabel,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _LayoutSelectorStatus extends StatelessWidget {
  const _LayoutSelectorStatus({
    super.key,
    required this.label,
    required this.progress,
    required this.color,
  });

  final String label;
  final bool progress;
  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.item,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
        LicoContentSpacing.item,
      ),
      child: Row(
        children: [
          if (progress) ...[
            SizedBox(
              width: LicoContentSpacing.item,
              height: LicoContentSpacing.item,
              child: LicoLoadingIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: LicoContentSpacing.compact),
          ] else ...[
            Icon(Icons.error_outline, size: 17, color: color),
            const SizedBox(width: LicoContentSpacing.compact),
          ],
          Expanded(child: Text(label)),
        ],
      ),
    ),
  );
}
