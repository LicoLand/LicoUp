import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Drag payloads for dock interactions.
sealed class DesktopDockDragData {
  const DesktopDockDragData();
}

/// An entry-level drag (reorder through gaps, merge onto another entry).
final class DesktopDockEntryDrag extends DesktopDockDragData {
  const DesktopDockEntryDrag(this.storageId);

  final String storageId;
}

/// A drag of one app out of a folder's open view; gap targets accept it to
/// extract the app back into the entry list.
final class DesktopDockFolderChildDrag extends DesktopDockDragData {
  const DesktopDockFolderChildDrag({required this.folderId, required this.app});

  final String folderId;
  final DesktopAppId app;
}

/// The full-width Desktop bottom bar: two rounded boxes on the shared glass
/// recipe. The left box is the navigation icon strip — a filled glass
/// container with no border stroke, icons shown directly inside, every icon
/// vertically centered (its active dot overlays the tile and never
/// participates in layout). The right box is the conversation composer,
/// supplied by the shell. As icons come and go the strip's width animates
/// and the composer stretches or shrinks in response; no vertical divider
/// separates the two boxes.
final class DesktopDockBar extends StatelessWidget {
  const DesktopDockBar({
    super.key,
    required this.entries,
    required this.openApps,
    required this.selectedApp,
    required this.settingsActive,
    required this.featuresActive,
    required this.collapsed,
    required this.collapsedStripExtent,
    this.stripWidthDuration = const Duration(milliseconds: 240),
    required this.recencyApps,
    required this.composer,
    required this.onOpenSettings,
    required this.onOpenFeatures,
    required this.onLaunchApp,
    required this.onCloseApp,
    required this.onMoveEntry,
    required this.onMergeEntries,
    required this.onOpenFolder,
    required this.onExtractFromFolder,
  });

  final List<DesktopDockEntry> entries;
  final Set<DesktopAppId> openApps;
  final DesktopAppId? selectedApp;
  final bool settingsActive;
  final bool featuresActive;

  /// Left-pane-collapsed presentation: the strip locks to the snapped width
  /// shared with the conversation list above it and shows the pinned icons
  /// plus the most recently used apps.
  final bool collapsed;
  final double collapsedStripExtent;

  /// Width-change animation for the strip; zero while the list edge is being
  /// dragged so the strip tracks the drag exactly.
  final Duration stripWidthDuration;
  final List<DesktopAppId> recencyApps;

  /// The conversation composer box; the bar stretches it horizontally.
  final Widget composer;

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenFeatures;
  final ValueChanged<DesktopAppId> onLaunchApp;
  final ValueChanged<DesktopAppId> onCloseApp;
  final void Function(String storageId, int targetIndex) onMoveEntry;
  final void Function(String draggedStorageId, String targetStorageId)
  onMergeEntries;
  final ValueChanged<String> onOpenFolder;
  final void Function(String folderId, DesktopAppId app, int insertIndex)
  onExtractFromFolder;

  /// The strip's hugging width for [entryCount] dock entries: two pinned
  /// icons, the entry tiles, and the drop gaps between them.
  static double stripContentExtent(int entryCount) {
    const pins =
        DesktopDesktopMetrics.dockIconExtent * 2 +
        DesktopDesktopMetrics.dockIconGap * 2;
    if (entryCount == 0) {
      return DesktopDesktopMetrics.dockBoxPaddingH * 2 + pins;
    }
    return DesktopDesktopMetrics.dockBoxPaddingH * 2 +
        pins +
        DesktopDesktopMetrics.dockIconGap +
        entryCount *
            (DesktopDesktopMetrics.dockIconExtent +
                DesktopDesktopMetrics.dockIconGap) -
        DesktopDesktopMetrics.dockIconGap +
        (entryCount + 1) * (DesktopDesktopMetrics.dockDropZoneExtent / 2);
  }

  /// The composer never shrinks below this width; the strip yields the rest.
  static const double composerMinExtent = 280;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxStrip = math
            .max(
              DesktopDesktopMetrics.dockIconSlotsExtent(
                DesktopDesktopMetrics.dockMinIconSlots,
              ),
              constraints.maxWidth -
                  DesktopDesktopMetrics.regionGap -
                  composerMinExtent,
            )
            .toDouble();
        final stripWidth = collapsed
            ? collapsedStripExtent.clamp(0.0, constraints.maxWidth).toDouble()
            : math.min(stripContentExtent(entries.length), maxStrip);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            DesktopDesktopMetrics.windowInset,
            0,
            DesktopDesktopMetrics.windowInset,
            DesktopDesktopMetrics.regionGap,
          ),
          child: Row(
            key: const Key('desktop-dock-bar'),
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedContainer(
                duration: stripWidthDuration,
                curve: LicoMotion.emphasized,
                width: stripWidth,
                height: DesktopDesktopMetrics.dockBarHeight,
                decoration: continuousHairlineDecoration(
                  color: DesktopDesktopGlass.cardFill(isDark: colors.isDark),
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.dockBarRadius,
                  ),
                  shadows: DesktopDesktopGlass.cardShadows(
                    isDark: colors.isDark,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.dockBarRadius,
                  ),
                  child: Semantics(
                    container: true,
                    label: 'Dock',
                    child: collapsed
                        ? _buildCollapsedStrip(context, strings)
                        : _buildFullStrip(context, strings),
                  ),
                ),
              ),
              const SizedBox(width: DesktopDesktopMetrics.regionGap),
              Expanded(child: composer),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPins(BuildContext context, LicoStrings strings) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopDockIcon(
          key: const Key('desktop-dock-pin-settings'),
          icon: Icons.settings_outlined,
          label: strings.settings,
          active: settingsActive,
          onTap: onOpenSettings,
        ),
        const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
        DesktopDockIcon(
          key: const Key('desktop-dock-pin-features'),
          icon: Icons.grid_view_rounded,
          label: strings.features,
          active: featuresActive,
          tooltip: DesktopDesktopCopy.openAppStoreTooltip(strings),
          onTap: onOpenFeatures,
        ),
      ],
    );
  }

  /// The full strip: pinned icons plus the persisted entries with drag
  /// reorder and drop-onto-icon folder creation.
  Widget _buildFullStrip(BuildContext context, LicoStrings strings) {
    return Row(
      children: [
        const SizedBox(width: DesktopDesktopMetrics.dockBoxPaddingH),
        _buildPins(context, strings),
        if (entries.isNotEmpty) ...[
          const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
          Expanded(
            child: SingleChildScrollView(
              key: const Key('desktop-dock-entries-strip'),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  _DesktopDockGapTarget(
                    key: const Key('desktop-dock-gap-0'),
                    onAcceptEntry: (storageId) => onMoveEntry(storageId, 0),
                    onAcceptFolderChild: (folderId, app) =>
                        onExtractFromFolder(folderId, app, 0),
                  ),
                  for (var index = 0; index < entries.length; index++) ...[
                    _buildEntry(context, entries[index]),
                    _DesktopDockGapTarget(
                      key: Key('desktop-dock-gap-${index + 1}'),
                      onAcceptEntry: (storageId) =>
                          onMoveEntry(storageId, index + 1),
                      onAcceptFolderChild: (folderId, app) =>
                          onExtractFromFolder(folderId, app, index + 1),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ] else
          const Spacer(),
        const SizedBox(width: DesktopDesktopMetrics.dockBoxPaddingH),
      ],
    );
  }

  /// The collapsed strip: pinned icons plus the most recently used open apps,
  /// in recency order, so the pinned minimum (设置, 功能, last app) is always
  /// what survives the narrowest snap.
  Widget _buildCollapsedStrip(BuildContext context, LicoStrings strings) {
    return Row(
      children: [
        const SizedBox(width: DesktopDesktopMetrics.dockBoxPaddingH),
        _buildPins(context, strings),
        if (recencyApps.isNotEmpty) ...[
          const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
          Expanded(
            child: SingleChildScrollView(
              key: const Key('desktop-dock-entries-strip'),
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (final app in recencyApps) ...[
                    DesktopDockIcon(
                      key: Key('desktop-dock-entry-app:${app.name}'),
                      icon: desktopAppIcon(app),
                      label: desktopAppLabel(strings, app),
                      active: openApps.contains(app) || selectedApp == app,
                      onTap: () => onLaunchApp(app),
                      onSecondaryTap: () => onCloseApp(app),
                    ),
                    const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
                  ],
                ],
              ),
            ),
          ),
        ] else
          const Spacer(),
        const SizedBox(width: DesktopDesktopMetrics.dockBoxPaddingH),
      ],
    );
  }

  Widget _buildEntry(BuildContext context, DesktopDockEntry entry) {
    final strings = LicoStrings.of(context);
    // Drag feedback renders in the root overlay, outside the shell's palette
    // scope, so the palette is re-provided around every feedback subtree.
    final palette = context.layoutPalette;
    switch (entry) {
      case DesktopDockAppEntry(app: final app):
        final label = desktopAppLabel(strings, app);
        return LongPressDraggable<DesktopDockDragData>(
          key: Key('desktop-dock-entry-${entry.storageId}'),
          data: DesktopDockEntryDrag(entry.storageId),
          feedback: LayoutPaletteScope(
            palette: palette,
            child: Material(
              color: Colors.transparent,
              child: Transform.scale(
                scale: 1.12,
                child: DesktopDockIcon(
                  icon: desktopAppIcon(app),
                  label: label,
                  active: true,
                  onTap: () {},
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: DesktopDockIcon(
              icon: desktopAppIcon(app),
              label: label,
              active: openApps.contains(app),
              onTap: () {},
            ),
          ),
          child: DragTarget<DesktopDockDragData>(
            onWillAcceptWithDetails: (details) =>
                details.data is DesktopDockEntryDrag &&
                (details.data as DesktopDockEntryDrag).storageId !=
                    entry.storageId,
            onAcceptWithDetails: (details) {
              final data = details.data;
              if (data is DesktopDockEntryDrag) {
                onMergeEntries(data.storageId, entry.storageId);
              }
            },
            builder: (context, candidates, rejected) => AnimatedScale(
              scale: candidates.isNotEmpty ? 1.14 : 1,
              duration: context.motion(LicoMotion.micro),
              child: DesktopDockIcon(
                icon: desktopAppIcon(app),
                label: label,
                active: openApps.contains(app) || selectedApp == app,
                onTap: () => onLaunchApp(app),
                onSecondaryTap: () => onCloseApp(app),
              ),
            ),
          ),
        );
      case DesktopDockFolderEntry(id: final id, children: final children):
        return LongPressDraggable<DesktopDockDragData>(
          key: Key('desktop-dock-entry-${entry.storageId}'),
          data: DesktopDockEntryDrag(entry.storageId),
          feedback: LayoutPaletteScope(
            palette: palette,
            child: Material(
              color: Colors.transparent,
              child: Transform.scale(
                scale: 1.12,
                child: DesktopDockFolderIcon(
                  children: children,
                  label: DesktopDesktopCopy.dockFolderLabel(strings),
                  onTap: () {},
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: DesktopDockFolderIcon(
              children: children,
              label: DesktopDesktopCopy.dockFolderLabel(strings),
              onTap: () {},
            ),
          ),
          child: DragTarget<DesktopDockDragData>(
            onWillAcceptWithDetails: (details) =>
                details.data is DesktopDockEntryDrag &&
                (details.data as DesktopDockEntryDrag).storageId !=
                    entry.storageId,
            onAcceptWithDetails: (details) {
              final data = details.data;
              if (data is DesktopDockEntryDrag) {
                onMergeEntries(data.storageId, entry.storageId);
              }
            },
            builder: (context, candidates, rejected) => AnimatedScale(
              scale: candidates.isNotEmpty ? 1.14 : 1,
              duration: context.motion(LicoMotion.micro),
              child: DesktopDockFolderIcon(
                children: children,
                label: DesktopDesktopCopy.dockFolderLabel(strings),
                onTap: () => onOpenFolder(id),
              ),
            ),
          ),
        );
    }
  }
}

/// One dock icon: a rounded-square glass tile, vertically centered in the
/// bar. The active dot overlays the tile's bottom edge and never
/// participates in layout, so the tile's center never shifts. Hover and
/// selection animate one color value per surface with the same timing, so a
/// hover pass reads as a single uniform color change.
final class DesktopDockIcon extends StatefulWidget {
  const DesktopDockIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.tooltip,
    this.onSecondaryTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final String? tooltip;
  final VoidCallback? onSecondaryTap;

  @override
  State<DesktopDockIcon> createState() => DesktopDockIconState();
}

final class DesktopDockIconState extends State<DesktopDockIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final duration = context.motion(LicoMotion.micro);
    final fill = widget.active
        ? colors.primary.withValues(alpha: colors.isDark ? 0.22 : 0.15)
        : _hovered
        ? DesktopDesktopGlass.hoverFill(isDark: colors.isDark)
        : Colors.transparent;
    final rim = widget.active
        ? colors.accent.withAlpha(colors.isDark ? 130 : 160)
        : DesktopDesktopGlass.cardBorder(
            colors.line,
            isDark: colors.isDark,
          ).withAlpha(_hovered ? 110 : 0);
    final glyph = widget.active
        ? colors.accent
        : _hovered
        ? colors.text
        : colors.textSecondary;
    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.label,
      child: Tooltip(
        message: widget.tooltip ?? widget.label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onSecondaryTap: widget.onSecondaryTap,
            child: SizedBox.square(
              dimension: DesktopDesktopMetrics.dockIconExtent,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: AnimatedContainer(
                      duration: duration,
                      curve: LicoMotion.standard,
                      decoration: continuousHairlineDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(
                          DesktopDesktopMetrics.dockIconRadius,
                        ),
                        stroke: rim,
                        strokeWidth: 0.5,
                      ),
                      child: Center(
                        child: TweenAnimationBuilder<Color?>(
                          tween: ColorTween(end: glyph),
                          duration: duration,
                          curve: LicoMotion.standard,
                          builder: (context, color, _) => Icon(
                            widget.icon,
                            size: DesktopDesktopMetrics.dockIconGlyphSize,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -7,
                    child: IgnorePointer(
                      child: Center(
                        child: AnimatedContainer(
                          duration: duration,
                          curve: LicoMotion.standard,
                          width: DesktopDesktopMetrics.dockActiveDotDiameter,
                          height: DesktopDesktopMetrics.dockActiveDotDiameter,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.active
                                ? colors.textSecondary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A folder tile: a 2x2 mini grid of its first child icons.
final class DesktopDockFolderIcon extends StatelessWidget {
  const DesktopDockFolderIcon({
    super.key,
    required this.children,
    required this.label,
    required this.onTap,
  });

  final List<DesktopAppId> children;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: SizedBox.square(
              dimension: DesktopDesktopMetrics.dockIconExtent,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: continuousHairlineDecoration(
                  color: DesktopDesktopGlass.controlFill(isDark: colors.isDark),
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.dockIconRadius,
                  ),
                  stroke: DesktopDesktopGlass.cardBorder(
                    colors.line,
                    isDark: colors.isDark,
                  ),
                  strokeWidth: 0.5,
                ),
                child: GridView.count(
                  crossAxisCount: 2,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                  children: [
                    for (final app in children.take(4))
                      Icon(
                        desktopAppIcon(app),
                        size: 12,
                        color: colors.textSecondary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The narrow drop zone between entries. Accepts entry drags (insert
/// reorder) and folder-child drags (extract at this position), expanding on
/// hover so the insertion point reads clearly.
final class _DesktopDockGapTarget extends StatelessWidget {
  const _DesktopDockGapTarget({
    super.key,
    required this.onAcceptEntry,
    required this.onAcceptFolderChild,
  });

  final ValueChanged<String> onAcceptEntry;
  final void Function(String folderId, DesktopAppId app) onAcceptFolderChild;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return DragTarget<DesktopDockDragData>(
      onWillAcceptWithDetails: (details) =>
          details.data is DesktopDockEntryDrag ||
          details.data is DesktopDockFolderChildDrag,
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is DesktopDockEntryDrag) {
          onAcceptEntry(data.storageId);
        } else if (data is DesktopDockFolderChildDrag) {
          onAcceptFolderChild(data.folderId, data.app);
        }
      },
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: context.motion(LicoMotion.micro),
        width: candidates.isNotEmpty
            ? DesktopDesktopMetrics.dockDropZoneExtent + 10
            : DesktopDesktopMetrics.dockDropZoneExtent / 2,
        height: DesktopDesktopMetrics.dockIconExtent,
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: context.motion(LicoMotion.micro),
          width: 2,
          height: candidates.isNotEmpty ? 30 : 0,
          decoration: BoxDecoration(
            color: candidates.isNotEmpty ? colors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }
}

/// The folder open view: a glass panel floating above the dock listing the
/// folder's apps. Launching an app or tapping outside dismisses; dragging a
/// child onto a dock gap extracts it from the folder.
final class DesktopDockFolderView extends StatelessWidget {
  const DesktopDockFolderView({
    super.key,
    required this.folderId,
    required this.children,
    required this.onLaunchApp,
    required this.onDismiss,
  });

  final String folderId;
  final List<DesktopAppId> children;
  final ValueChanged<DesktopAppId> onLaunchApp;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Container(
            key: const Key('desktop-folder-popup'),
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.all(16),
            decoration: continuousHairlineDecoration(
              color: DesktopDesktopGlass.cardFill(isDark: colors.isDark),
              borderRadius: BorderRadius.circular(20),
              stroke: DesktopDesktopGlass.cardBorder(
                colors.line,
                isDark: colors.isDark,
              ),
              strokeWidth: 0.5,
              shadows: DesktopDesktopGlass.cardShadows(isDark: colors.isDark),
            ),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final app in children)
                  LongPressDraggable<DesktopDockDragData>(
                    key: Key('desktop-folder-child-${app.name}'),
                    data: DesktopDockFolderChildDrag(
                      folderId: folderId,
                      app: app,
                    ),
                    feedback: LayoutPaletteScope(
                      palette: colors,
                      child: Material(
                        color: Colors.transparent,
                        child: Transform.scale(
                          scale: 1.12,
                          child: DesktopDockIcon(
                            icon: desktopAppIcon(app),
                            label: desktopAppLabel(strings, app),
                            active: true,
                            onTap: () {},
                          ),
                        ),
                      ),
                    ),
                    child: DesktopDockIcon(
                      icon: desktopAppIcon(app),
                      label: desktopAppLabel(strings, app),
                      active: true,
                      onTap: () => onLaunchApp(app),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
