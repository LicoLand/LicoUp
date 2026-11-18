import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

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

/// One plugin window as the dock shows it.
final class DesktopDockPlugin {
  const DesktopDockPlugin({
    required this.id,
    required this.name,
    required this.running,
  });

  final String id;
  final String name;
  final bool running;
}

/// The floating Desktop dock, centered at the bottom of the work area.
///
/// Three groups separated by hairline dividers: the arrangeable built-in apps
/// (drag to reorder, drop onto an icon to make a folder), then open and
/// pinned plugin windows, then Plugin Center and Settings. Hovering an icon
/// magnifies it and its neighbours by transform, never by layout, and shows
/// its label above it; reduced motion keeps every icon at rest. A dot under
/// an icon marks a running app; the active app's dot is brighter.
final class DesktopDockBar extends StatefulWidget {
  const DesktopDockBar({
    super.key,
    required this.entries,
    required this.transientApps,
    required this.plugins,
    required this.active,
    required this.running,
    required this.badges,
    required this.onOpen,
    required this.onMenu,
    required this.onOpenFolder,
    required this.onMoveEntry,
    required this.onMergeEntries,
    required this.onExtractFromFolder,
  });

  /// The arrangeable built-in group.
  final List<DesktopDockEntry> entries;

  /// Running built-in apps outside the arrangeable group; shown after it
  /// until they quit.
  final List<DesktopAppId> transientApps;

  final List<DesktopDockPlugin> plugins;
  final DesktopWorkItem active;
  final Set<DesktopWorkItem> running;

  /// Waiting decisions per item.
  final Map<DesktopWorkItem, int> badges;

  final ValueChanged<DesktopWorkItem> onOpen;
  final void Function(DesktopWorkItem item, Offset globalPosition) onMenu;
  final ValueChanged<String> onOpenFolder;
  final void Function(String storageId, int targetIndex) onMoveEntry;
  final void Function(String draggedStorageId, String targetStorageId)
  onMergeEntries;
  final void Function(String folderId, DesktopAppId app, int insertIndex)
  onExtractFromFolder;

  @override
  State<DesktopDockBar> createState() => _DesktopDockBarState();
}

final class _DesktopDockBarState extends State<DesktopDockBar> {
  int? _hoveredSlot;
  bool _dragging = false;

  double _scaleFor(BuildContext context, int slot) {
    final hovered = _hoveredSlot;
    if (hovered == null || _dragging) return 1;
    if (MediaQuery.disableAnimationsOf(context)) return 1;
    return switch ((slot - hovered).abs()) {
      0 => DesktopDesktopMetrics.dockHoverScale,
      1 => DesktopDesktopMetrics.dockNeighborScale,
      _ => 1,
    };
  }

  void _hover(int slot, bool entered) {
    if (entered) {
      if (_hoveredSlot != slot) setState(() => _hoveredSlot = slot);
    } else if (_hoveredSlot == slot) {
      setState(() => _hoveredSlot = null);
    }
  }

  void _dragChanged(bool dragging) {
    if (_dragging == dragging) return;
    setState(() {
      _dragging = dragging;
      if (dragging) _hoveredSlot = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    var slot = 0;
    Widget icon({
      required Key key,
      required DesktopWorkItem item,
      required Widget glyph,
      required String label,
    }) {
      final index = slot++;
      return _DockSlot(
        key: key,
        glyph: glyph,
        label: label,
        scale: _scaleFor(context, index),
        labelVisible: _hoveredSlot == index && !_dragging,
        active: widget.active == item,
        running: widget.running.contains(item),
        badge: widget.badges[item] ?? 0,
        dotKey: ValueKey<String>('desktop-dock-dot:${item.id}'),
        onHover: (entered) => _hover(index, entered),
        onTap: () => widget.onOpen(item),
        onSecondaryTapDown: (position) => widget.onMenu(item, position),
      );
    }

    Widget appIcon(DesktopAppId app, Key key) => icon(
      key: key,
      item: DesktopWorkApp(app),
      glyph: _DockGlyph(
        icon: desktopAppIcon(app),
        glow: colors.isDark && widget.active == DesktopWorkApp(app)
            ? colors.accentGlow
            : null,
      ),
      label: desktopAppLabel(strings, app),
    );

    final builtIn = <Widget>[
      _DockGap(
        key: const Key('desktop-dock-gap-0'),
        restWidth: DesktopDesktopMetrics.dockIconGap / 2,
        onAcceptEntry: (id) => widget.onMoveEntry(id, 0),
        onAcceptFolderChild: (folderId, app) =>
            widget.onExtractFromFolder(folderId, app, 0),
      ),
      for (var index = 0; index < widget.entries.length; index++) ...[
        _buildEntry(context, widget.entries[index], () => slot++),
        _DockGap(
          key: Key('desktop-dock-gap-${index + 1}'),
          restWidth: index == widget.entries.length - 1
              ? DesktopDesktopMetrics.dockIconGap / 2
              : DesktopDesktopMetrics.dockIconGap,
          onAcceptEntry: (id) => widget.onMoveEntry(id, index + 1),
          onAcceptFolderChild: (folderId, app) =>
              widget.onExtractFromFolder(folderId, app, index + 1),
        ),
      ],
      for (final app in widget.transientApps) ...[
        const SizedBox(width: DesktopDesktopMetrics.dockIconGap / 2),
        appIcon(app, Key('desktop-dock-running-app:${app.name}')),
      ],
    ];
    final plugins = <Widget>[
      for (var index = 0; index < widget.plugins.length; index++) ...[
        if (index > 0) const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
        icon(
          key: Key('desktop-dock-plugin-${widget.plugins[index].id}'),
          item: DesktopWorkPlugin(widget.plugins[index].id),
          glyph: _DockMonogram(name: widget.plugins[index].name),
          label: widget.plugins[index].name,
        ),
      ],
    ];
    final system = <Widget>[
      for (var index = 0; index < desktopDockSystemApps.length; index++) ...[
        if (index > 0) const SizedBox(width: DesktopDesktopMetrics.dockIconGap),
        appIcon(
          desktopDockSystemApps[index],
          Key('desktop-dock-pin-${desktopDockSystemApps[index].name}'),
        ),
      ],
    ];

    return Semantics(
      container: true,
      label: DesktopDesktopCopy.dockLabel(strings),
      child: MouseRegion(
        onExit: (_) {
          if (_hoveredSlot != null) setState(() => _hoveredSlot = null);
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: GlassEdgeLight(
            borderRadius: BorderRadius.circular(
              DesktopDesktopMetrics.dockRadius,
            ),
            rimWidth: 1,
            rimHi: colors.isDark
                ? DesktopDesktopGlass.dockRimHi
                : DesktopDesktopGlass.dockRimHiLight,
            rimLo: colors.isDark
                ? DesktopDesktopGlass.dockRimLo
                : DesktopDesktopGlass.dockRimLoLight,
            child: Container(
              key: const Key('desktop-dock'),
              height: DesktopDesktopMetrics.dockHeight,
              padding: const EdgeInsets.only(
                left:
                    DesktopDesktopMetrics.dockPaddingH -
                    DesktopDesktopMetrics.dockIconGap / 2,
                right: DesktopDesktopMetrics.dockPaddingH,
              ),
              decoration: ShapeDecoration(
                color: DesktopDesktopGlass.dockFill(colors),
                shape: ContinuousRoundedBorder(
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.dockRadius,
                  ),
                ),
                shadows: DesktopDesktopGlass.dockShadows(isDark: colors.isDark),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...builtIn,
                  if (plugins.isNotEmpty) ...[
                    const _DockDivider(
                      key: Key('desktop-dock-divider-plugins'),
                    ),
                    ...plugins,
                  ],
                  const _DockDivider(key: Key('desktop-dock-divider-system')),
                  ...system,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEntry(
    BuildContext context,
    DesktopDockEntry entry,
    int Function() nextSlot,
  ) {
    final strings = LicoStrings.of(context);
    // Drag feedback renders in the root overlay, outside the shell's palette
    // scope, so the palette is re-provided around every feedback subtree.
    final palette = context.layoutPalette;
    final index = nextSlot();
    final (Widget glyph, String label, DesktopWorkItem? item) = switch (entry) {
      DesktopDockAppEntry(app: final app) => (
        _DockGlyph(
          icon: desktopAppIcon(app),
          glow: palette.isDark && widget.active == DesktopWorkApp(app)
              ? palette.brandGlow
              : null,
        ),
        desktopAppLabel(strings, app),
        DesktopWorkApp(app),
      ),
      DesktopDockFolderEntry(children: final children) => (
        _DockFolderGlyph(children: children),
        DesktopDesktopCopy.dockFolderLabel(strings),
        null,
      ),
    };
    final children = switch (entry) {
      DesktopDockFolderEntry(children: final children) => [
        for (final app in children) DesktopWorkApp(app),
      ],
      _ => const <DesktopWorkApp>[],
    };
    final active = item != null
        ? widget.active == item
        : children.contains(widget.active);
    final running = item != null
        ? widget.running.contains(item)
        : children.any(widget.running.contains);
    final badge = item != null
        ? widget.badges[item] ?? 0
        : children.fold<int>(
            0,
            (sum, child) => sum + (widget.badges[child] ?? 0),
          );
    Widget tile({required double scale, required bool labelVisible}) =>
        _DockSlot(
          glyph: glyph,
          label: label,
          scale: scale,
          labelVisible: labelVisible,
          active: active,
          running: running,
          badge: badge,
          dotKey: ValueKey<String>('desktop-dock-dot:${entry.storageId}'),
          onHover: (entered) => _hover(index, entered),
          onTap: () => switch (entry) {
            DesktopDockAppEntry(app: final app) => widget.onOpen(
              DesktopWorkApp(app),
            ),
            DesktopDockFolderEntry(id: final id) => widget.onOpenFolder(id),
          },
          onSecondaryTapDown: item == null
              ? null
              : (position) => widget.onMenu(item, position),
        );
    return LongPressDraggable<DesktopDockDragData>(
      key: Key('desktop-dock-entry-${entry.storageId}'),
      data: DesktopDockEntryDrag(entry.storageId),
      onDragStarted: () => _dragChanged(true),
      onDragEnd: (_) => _dragChanged(false),
      feedback: LayoutPaletteScope(
        palette: palette,
        child: Material(
          color: Colors.transparent,
          child: Transform.scale(
            scale: 1.12,
            child: SizedBox(
              width: DesktopDesktopMetrics.dockIconExtent,
              height: DesktopDesktopMetrics.dockHeight,
              child: tile(scale: 1, labelVisible: false),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: tile(scale: 1, labelVisible: false),
      ),
      child: DragTarget<DesktopDockDragData>(
        onWillAcceptWithDetails: (details) =>
            details.data is DesktopDockEntryDrag &&
            (details.data as DesktopDockEntryDrag).storageId != entry.storageId,
        onAcceptWithDetails: (details) {
          final data = details.data;
          if (data is DesktopDockEntryDrag) {
            widget.onMergeEntries(data.storageId, entry.storageId);
          }
        },
        builder: (context, candidates, rejected) => tile(
          scale: candidates.isNotEmpty ? 1.14 : _scaleFor(context, index),
          labelVisible: _hoveredSlot == index && !_dragging,
        ),
      ),
    );
  }
}

/// One dock position: the magnified tile, the label above it while hovered,
/// the running dot below it and the waiting-decisions badge. Magnification
/// is a transform anchored at the tile's bottom edge, so neighbours never
/// move.
final class _DockSlot extends StatelessWidget {
  const _DockSlot({
    super.key,
    required this.glyph,
    required this.label,
    required this.scale,
    required this.labelVisible,
    required this.active,
    required this.running,
    required this.badge,
    required this.dotKey,
    required this.onHover,
    required this.onTap,
    required this.onSecondaryTapDown,
  });

  final Widget glyph;
  final String label;
  final double scale;
  final bool labelVisible;
  final bool active;
  final bool running;
  final int badge;
  final Key dotKey;
  final ValueChanged<bool> onHover;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final duration = context.motion(LicoMotion.micro);
    final isDark = colors.isDark;
    // labelVisible is the slot's hover state (parent-tracked): the hovered
    // tile gets a wash and a brighter glyph, the active tile a quiet fill
    // plus hairline.
    final tileFill = active
        ? DesktopDesktopGlass.dockTileActiveFill(isDark: isDark)
        : labelVisible
        ? DesktopDesktopGlass.dockTileHoverFill(isDark: isDark)
        : null;
    final tileRim = active
        ? DesktopDesktopGlass.dockTileActiveRim(isDark: isDark)
        : null;
    final glyphColor = active
        ? colors.selectionInk
        : labelVisible
        ? colors.text
        : colors.textSecondary;
    final monogramColor = glyphColor;
    const extent = DesktopDesktopMetrics.dockIconExtent;
    const bottom =
        (DesktopDesktopMetrics.dockHeight -
            DesktopDesktopMetrics.dockIconExtent) /
        2;
    final semanticsLabel = badge > 0
        ? '$label, ${DesktopDesktopCopy.dockWaitingDecisions(strings, badge)}'
        : label;
    return Semantics(
      button: true,
      selected: active,
      label: semanticsLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown == null
              ? null
              : (details) => onSecondaryTapDown!(details.globalPosition),
          child: SizedBox(
            width: extent,
            height: DesktopDesktopMetrics.dockHeight,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.bottomCenter,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottom,
                  height: extent,
                  child: AnimatedScale(
                    scale: scale,
                    alignment: Alignment.bottomCenter,
                    duration: duration,
                    curve: LicoMotion.standard,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: AnimatedContainer(
                            duration: duration,
                            curve: LicoMotion.standard,
                            decoration: continuousHairlineDecoration(
                              color: tileFill,
                              borderRadius: BorderRadius.circular(
                                DesktopDesktopMetrics.dockIconRadius,
                              ),
                              stroke: tileRim,
                              strokeWidth: 0.5,
                            ),
                            child: Center(
                              child: IconTheme.merge(
                                data: IconThemeData(
                                  color: glyphColor,
                                  size: DesktopDesktopMetrics.dockIconGlyphSize,
                                ),
                                child: DefaultTextStyle.merge(
                                  style: TextStyle(color: monogramColor),
                                  child: glyph,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (badge > 0)
                          Positioned(
                            top: -4,
                            right: -4,
                            child: _DockBadge(count: badge),
                          ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 3,
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      key: dotKey,
                      duration: duration,
                      curve: LicoMotion.standard,
                      width: DesktopDesktopMetrics.dockActiveDotDiameter,
                      height: DesktopDesktopMetrics.dockActiveDotDiameter,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: !running && !active
                            ? Colors.transparent
                            : active
                            ? colors.primary
                            : DesktopDesktopGlass.dockDotColor(isDark: isDark),
                      ),
                    ),
                  ),
                ),
                if (labelVisible)
                  Positioned(
                    bottom: bottom + extent * scale + 8,
                    child: IgnorePointer(child: _DockLabel(label: label)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _DockGlyph extends StatelessWidget {
  const _DockGlyph({required this.icon, this.glow});

  final IconData icon;
  final Color? glow;

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    shadows: [if (glow != null) Shadow(color: glow!, blurRadius: 10)],
  );
}

/// A plugin window's tile glyph: the first letter of its name.
final class _DockMonogram extends StatelessWidget {
  const _DockMonogram({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final letter = trimmed.isEmpty
        ? '?'
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
    return Text(
      letter,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    );
  }
}

/// A folder tile: a 2x2 mini grid of its first child icons.
final class _DockFolderGlyph extends StatelessWidget {
  const _DockFolderGlyph({required this.children});

  final List<DesktopAppId> children;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color;
    return SizedBox.square(
      dimension: 28,
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        children: [
          for (final app in children.take(4))
            Icon(desktopAppIcon(app), size: 12, color: color),
        ],
      ),
    );
  }
}

final class _DockBadge extends StatelessWidget {
  const _DockBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Container(
      constraints: const BoxConstraints(
        minWidth: DesktopDesktopMetrics.dockBadgeExtent,
      ),
      height: DesktopDesktopMetrics.dockBadgeExtent,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: continuousHairlineDecoration(
        color: colors.unreadBadgeFill,
        borderRadius: BorderRadius.circular(999),
        stroke: DesktopDesktopGlass.dockFill(colors),
        strokeWidth: 1.5,
      ),
      child: Text(
        count > 9 ? '9+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

final class _DockLabel extends StatelessWidget {
  const _DockLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Container(
      key: const Key('desktop-dock-label'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: continuousHairlineDecoration(
        color: DesktopDesktopGlass.dockLabelFill(isDark: colors.isDark),
        borderRadius: BorderRadius.circular(8),
        stroke: DesktopDesktopGlass.dockLabelRim(isDark: colors.isDark),
        strokeWidth: 0.5,
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          color: colors.text,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

final class _DockDivider extends StatelessWidget {
  const _DockDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: SizedBox(
        width: 0.5,
        height: 24,
        child: ColoredBox(
          color: DesktopDesktopGlass.dockDividerColor(isDark: colors.isDark),
        ),
      ),
    );
  }
}

/// The narrow drop zone between entries. Accepts entry drags (insert
/// reorder) and folder-child drags (extract at this position), expanding on
/// hover so the insertion point reads clearly.
final class _DockGap extends StatelessWidget {
  const _DockGap({
    super.key,
    required this.restWidth,
    required this.onAcceptEntry,
    required this.onAcceptFolderChild,
  });

  final double restWidth;
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
            : restWidth,
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

/// The folder open view: a glass panel above the dock listing the folder's
/// apps. Opening an app or tapping outside dismisses; dragging a child onto
/// a dock gap extracts it from the folder.
final class DesktopDockFolderView extends StatelessWidget {
  const DesktopDockFolderView({
    super.key,
    required this.folderId,
    required this.children,
    required this.active,
    required this.onOpenApp,
    required this.onDismiss,
  });

  final String folderId;
  final List<DesktopAppId> children;
  final DesktopWorkItem active;
  final ValueChanged<DesktopAppId> onOpenApp;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    Widget tile(DesktopAppId app) => SizedBox(
      width: 72,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: DesktopDesktopMetrics.dockIconExtent,
            height: DesktopDesktopMetrics.dockHeight - 8,
            child: _DockSlot(
              glyph: _DockGlyph(icon: desktopAppIcon(app)),
              label: desktopAppLabel(strings, app),
              scale: 1,
              labelVisible: false,
              active: active == DesktopWorkApp(app),
              running: false,
              badge: 0,
              dotKey: ValueKey<String>('desktop-folder-dot-${app.name}'),
              onHover: (_) {},
              onTap: () => onOpenApp(app),
              onSecondaryTapDown: null,
            ),
          ),
          Text(
            desktopAppLabel(strings, app),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              key: const Key('desktop-folder-popup'),
              constraints: const BoxConstraints(maxWidth: 340),
              padding: const EdgeInsets.all(14),
              decoration: continuousHairlineDecoration(
                color: DesktopDesktopGlass.dockFill(colors),
                borderRadius: BorderRadius.circular(20),
                stroke: LicoPaneGlass.cardBorder(
                  colors.line,
                  isDark: colors.isDark,
                ),
                strokeWidth: 0.5,
                shadows: DesktopDesktopGlass.dockShadows(isDark: colors.isDark),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 8,
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
                          child: Transform.scale(scale: 1.12, child: tile(app)),
                        ),
                      ),
                      child: tile(app),
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
