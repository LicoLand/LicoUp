import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _eagerProfileOptionLimit = 12;
const _virtualizedVisibleRows = 3;

final class LayoutProfileSelector extends StatefulWidget {
  const LayoutProfileSelector({
    super.key,
    required this.manager,
    required this.registry,
    required this.surface,
  });

  final LayoutManager manager;
  final LayoutRegistry registry;
  final LayoutRuntimeSurface surface;

  @override
  State<LayoutProfileSelector> createState() => _LayoutProfileSelectorState();
}

final class _LayoutProfileSelectorState extends State<LayoutProfileSelector> {
  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_handleSelection);
  }

  @override
  void didUpdateWidget(LayoutProfileSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.manager, widget.manager)) {
      oldWidget.manager.removeListener(_handleSelection);
      widget.manager.addListener(_handleSelection);
    }
  }

  @override
  void dispose() {
    widget.manager.removeListener(_handleSelection);
    super.dispose();
  }

  void _handleSelection(LayoutSelectionState _) {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(widget.manager.catalog, widget.registry.catalog)) {
      throw const FormatException('layout_selector_catalog_mismatch');
    }

    final strings = LicoStrings.of(context);
    final state = widget.manager.state;
    final colors = context.licoColors;
    final profiles = widget.manager.catalog.profiles;
    final effectiveProfile = widget.manager.catalog.profile(state.effectiveId);
    final committedProfile = widget.manager.catalog.profile(state.committedId);
    final committing = state.status == LayoutSelectionStatus.committing;
    final loading = state.status == LayoutSelectionStatus.loading;
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);

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
              if (state.errorCode case final errorCode?)
                _LayoutSelectorStatus(
                  key: const ValueKey<String>('layout-selector-error'),
                  label: strings.layoutSelectionError(errorCode),
                  progress: false,
                  color: colors.error,
                ),
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
                          preview: widget.registry
                              .definition(profiles[index].id)
                              .bundles[widget.surface]!
                              .previewBuilder(context),
                          label: profiles[index].label.resolve(
                            strings.locale.languageCode,
                          ),
                          currentLabel: strings.currentLayout,
                          selected: identical(
                            profiles[index],
                            effectiveProfile,
                          ),
                          committed: identical(
                            profiles[index],
                            committedProfile,
                          ),
                          // The Dashboard layout is not ready yet: it stays
                          // visible as a preview but cannot be selected.
                          enabled:
                              !committing &&
                              profiles[index].id.value != 'dashboard',
                          reducedMotion: reducedMotion,
                          onPressed: () {
                            unawaited(
                              widget.manager.selectLayout(profiles[index].id),
                            );
                          },
                        ),
                      ),
                    );
                    final options = profiles.length <= _eagerProfileOptionLimit
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
              const SizedBox(height: LicoContentSpacing.item),
              if (committing)
                _LayoutSelectorStatus(
                  key: const ValueKey<String>('layout-selector-committing'),
                  label: strings.layoutCommitting,
                  progress: true,
                  color: colors.accent,
                ),
              Padding(
                padding: presentation.selectorActionPadding,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const ValueKey<String>('layout-selector-reset'),
                    onPressed: committing
                        ? null
                        : () {
                            unawaited(widget.manager.resetLayout());
                          },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.restart_alt_outlined, size: 17),
                        const SizedBox(width: LicoContentSpacing.compact),
                        Flexible(
                          child: Text(
                            strings.resetLayout,
                            textAlign: TextAlign.end,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
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
    final itemHeight = itemWidth * (10 / 16) + 50;
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
    final borderColor = selected ? colors.primaryStrong : colors.line;
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
            decoration: BoxDecoration(
              color: selected ? colors.surface : colors.surfaceLow,
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
              borderRadius: BorderRadius.circular(10),
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
                          borderRadius: BorderRadius.circular(6),
                          child: AspectRatio(
                            aspectRatio: 16 / 8,
                            child: FittedBox(
                              fit: BoxFit.cover,
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
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
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
