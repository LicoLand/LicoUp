import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Drag payloads for dock interactions.
sealed class DesktopDockDragData {
  const DesktopDockDragData();
}

/// Computes the dock bar's outer width for a window [maxWidth] (already
/// clamped to the bar's own max) and the current [entryCount]. Shared by the
/// bar and the shell's floating input row so the two stay aligned as the bar
/// stretches.
double desktopDockBarWidth({required double maxWidth, required int entryCount}) {
  const entrySlot =
      DesktopDesktopMetrics.dockIconExtent +
      DesktopDesktopMetrics.dockIconGap;
  const fixedExtent =
      DesktopDesktopMetrics.dockIconExtent * 2 +
      DesktopDesktopMetrics.dockIconGap * 3 +
      1 +
      DesktopDesktopMetrics.dockInputSlotExtent +
      8;
  final contentExtent =
      fixedExtent +
      entryCount * entrySlot +
      (entryCount == 0 ? 0 : DesktopDesktopMetrics.dockDropZoneExtent);
  final minWidth = DesktopDesktopMetrics.dockBarMinWidth.clamp(0.0, maxWidth);
  return contentExtent.clamp(minWidth, maxWidth);
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

/// The floating capsule dock bar: pinned 设置 and 功能 icons leftmost, the
/// persisted entry strip (apps and folders) with drag reorder and
/// drop-onto-icon folder creation, and a reserved slot on the right for the
/// contextual input capsule (the shell floats the input above that slot so a
/// multiline composer can grow upward past the bar's clip).
final class DesktopDockBar extends StatelessWidget {
  const DesktopDockBar({
    super.key,
    required this.entries,
    required this.openApps,
    required this.activeApp,
    required this.settingsActive,
    required this.appStoreOpen,
    required this.onOpenSettings,
    required this.onToggleAppStore,
    required this.onLaunchApp,
    required this.onCloseApp,
    required this.onMoveEntry,
    required this.onMergeEntries,
    required this.onOpenFolder,
    required this.onExtractFromFolder,
  });

  final List<DesktopDockEntry> entries;
  final Set<DesktopAppId> openApps;
  final DesktopAppId? activeApp;
  final bool settingsActive;
  final bool appStoreOpen;
  final VoidCallback onOpenSettings;
  final VoidCallback onToggleAppStore;
  final ValueChanged<DesktopAppId> onLaunchApp;
  final ValueChanged<DesktopAppId> onCloseApp;
  final void Function(String storageId, int targetIndex) onMoveEntry;
  final void Function(String draggedStorageId, String targetStorageId)
  onMergeEntries;
  final ValueChanged<String> onOpenFolder;
  final void Function(String folderId, DesktopAppId app, int insertIndex)
  onExtractFromFolder;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final media = MediaQuery.of(context);
    final maxBarWidth =
        (media.size.width - DesktopDesktopMetrics.dockBarSideInset * 2).clamp(
          0.0,
          DesktopDesktopMetrics.dockBarMaxWidth,
        );
    final barWidth = desktopDockBarWidth(
      maxWidth: maxBarWidth,
      entryCount: entries.length,
    );

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DesktopDesktopMetrics.dockBarSideInset,
          0,
          DesktopDesktopMetrics.dockBarSideInset,
          DesktopDesktopMetrics.dockBarBottomInset,
        ),
        child: Semantics(
          container: true,
          label: 'Dock',
          child: Container(
            key: const Key('desktop-dock-bar'),
            width: barWidth,
            height: DesktopDesktopMetrics.dockBarHeight,
            decoration: BoxDecoration(
              color: desktopDesktopSurfaceBlack,
              borderRadius: BorderRadius.circular(
                DesktopDesktopMetrics.dockBarRadius,
              ),
              border: Border.all(color: DesktopDesktopOnBlack.line, width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 26,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              children: [
                const SizedBox(width: DesktopDesktopMetrics.dockIconGap + 2),
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
                  active: appStoreOpen,
                  tooltip: DesktopDesktopCopy.openAppStoreTooltip(strings),
                  onTap: onToggleAppStore,
                ),
                const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
                Container(
                  width: 0.5,
                  height: 30,
                  color: DesktopDesktopOnBlack.line,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('desktop-dock-entries-strip'),
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: Row(
                      children: [
                        _DesktopDockGapTarget(
                          key: const Key('desktop-dock-gap-0'),
                          onAcceptEntry: (storageId) =>
                              onMoveEntry(storageId, 0),
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
                                onExtractFromFolder(
                                  folderId,
                                  app,
                                  index + 1,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Reserved slot for the contextual input row; the shell
                // floats the actual input above it as a separate layer so a
                // growing composer escapes the bar's clip.
                const SizedBox(
                  width: DesktopDesktopMetrics.dockInputSlotExtent,
                ),
              ],
            ),
          ),
        ),
      ),
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
                active: openApps.contains(app) || activeApp == app,
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

/// One dock icon: a rounded-square glass tile with an active dot below.
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: context.motion(LicoMotion.micro),
                  width: DesktopDesktopMetrics.dockIconExtent,
                  height: DesktopDesktopMetrics.dockIconExtent,
                  decoration: BoxDecoration(
                    color: _hovered
                        ? DesktopDesktopOnBlack.hoverOverlay
                        : desktopDesktopSurfaceBlack,
                    borderRadius: BorderRadius.circular(
                      DesktopDesktopMetrics.dockIconRadius,
                    ),
                    border: Border.all(
                      color: DesktopDesktopOnBlack.line,
                      width: 0.5,
                    ),
                  ),
                  child: Icon(
                    widget.icon,
                    size: DesktopDesktopMetrics.dockIconGlyphSize,
                    color: _hovered || widget.active
                        ? DesktopDesktopOnBlack.text
                        : DesktopDesktopOnBlack.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: context.motion(LicoMotion.micro),
                  width: DesktopDesktopMetrics.dockActiveDotDiameter,
                  height: DesktopDesktopMetrics.dockActiveDotDiameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.active
                        ? DesktopDesktopOnBlack.textSecondary
                        : Colors.transparent,
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: DesktopDesktopMetrics.dockIconExtent,
                  height: DesktopDesktopMetrics.dockIconExtent,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: desktopDesktopSurfaceBlack,
                    borderRadius: BorderRadius.circular(
                      DesktopDesktopMetrics.dockIconRadius,
                    ),
                    border: Border.all(
                      color: DesktopDesktopOnBlack.line,
                      width: 0.5,
                    ),
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
                          color: DesktopDesktopOnBlack.textSecondary,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Container(
                  width: DesktopDesktopMetrics.dockActiveDotDiameter,
                  height: DesktopDesktopMetrics.dockActiveDotDiameter,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.transparent,
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

/// The folder open view: a pure black panel floating above the dock listing
/// the folder's apps. Launching an app or tapping outside dismisses;
/// dragging a child onto a dock gap extracts it from the folder.
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
            decoration: BoxDecoration(
              color: desktopDesktopSurfaceBlack,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: DesktopDesktopOnBlack.line, width: 0.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
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
