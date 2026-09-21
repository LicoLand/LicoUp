import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// One features-grid entry. Built-in entries launch a [DesktopAppId]; the
/// trailing plugin slot is a documented extension point: future
/// user-developed plugins register their own [DesktopFeatureGridEntry] values
/// and appear in the same matrix.
final class DesktopFeatureGridEntry {
  const DesktopFeatureGridEntry({this.app, this.isPluginSlot = false});

  final DesktopAppId? app;

  /// The reserved slot where future user plugins appear.
  final bool isPluginSlot;
}

/// The 功能 panel: the Desktop left pane's default content — a scrollable
/// matrix of rounded-square app tiles for every feature app plus the plugin
/// extension slot. Tapping a tile opens the app in the left pane.
final class DesktopFeaturesGrid extends StatelessWidget {
  const DesktopFeaturesGrid({
    super.key,
    required this.onLaunchApp,
    this.extraEntries = const [],
  });

  final ValueChanged<DesktopAppId> onLaunchApp;

  /// Plugin extension point: additional entries future user plugins supply.
  final List<DesktopFeatureGridEntry> extraEntries;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    final entries = <DesktopFeatureGridEntry>[
      for (final app in desktopFeatureApps) DesktopFeatureGridEntry(app: app),
      const DesktopFeatureGridEntry(isPluginSlot: true),
      ...extraEntries,
    ];
    return Semantics(
      key: const Key('desktop-launchpad'),
      container: true,
      label: DesktopDesktopCopy.appStoreTitle(strings),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              DesktopDesktopCopy.appStoreTitle(strings),
              maxLines: 1,
              style: TextStyle(
                color: colors.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              key: const Key('desktop-features-grid-scroll'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Wrap(
                spacing: DesktopDesktopMetrics.featuresColumnGap,
                runSpacing: DesktopDesktopMetrics.featuresRowGap,
                children: [
                  for (final entry in entries)
                    entry.isPluginSlot
                        ? const _DesktopFeatureGridPluginSlot()
                        : _DesktopFeatureGridTile(
                            key: Key(
                              'desktop-launchpad-app-${entry.app!.name}',
                            ),
                            app: entry.app!,
                            onTap: () => onLaunchApp(entry.app!),
                          ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DesktopFeatureGridTile extends StatefulWidget {
  const _DesktopFeatureGridTile({
    super.key,
    required this.app,
    required this.onTap,
  });

  final DesktopAppId app;
  final VoidCallback onTap;

  @override
  State<_DesktopFeatureGridTile> createState() =>
      _DesktopFeatureGridTileState();
}

final class _DesktopFeatureGridTileState
    extends State<_DesktopFeatureGridTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    final label = desktopAppLabel(strings, widget.app);
    final duration = context.motion(LicoMotion.micro);
    final fill = _hovered
        ? DesktopDesktopGlass.hoverFill(isDark: colors.isDark)
        : Colors.transparent;
    final rim = DesktopDesktopGlass.cardBorder(
      colors.line,
      isDark: colors.isDark,
    ).withAlpha(_hovered ? 110 : 0);
    return Semantics(
      button: true,
      label: label,
      // No Tooltip: the label is already visible under the tile, and a hover
      // tooltip survives the pane swap — an offstage (kept-alive) tile never
      // receives the exit event that would dismiss it.
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: duration,
                curve: LicoMotion.standard,
                width: DesktopDesktopMetrics.featuresIconExtent,
                height: DesktopDesktopMetrics.featuresIconExtent,
                decoration: continuousHairlineDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.featuresIconRadius,
                  ),
                  stroke: rim,
                  strokeWidth: 0.5,
                ),
                child: Center(
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: _hovered ? colors.text : colors.textSecondary,
                    ),
                    duration: duration,
                    curve: LicoMotion.standard,
                    builder: (context, color, _) => Icon(
                      desktopAppIcon(widget.app),
                      size: 26,
                      color: color,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: 76,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reserved matrix slot future user-developed plugins occupy.
final class _DesktopFeatureGridPluginSlot extends StatelessWidget {
  const _DesktopFeatureGridPluginSlot();

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    final label = DesktopDesktopCopy.pluginSlotLabel(strings);
    return Tooltip(
      message: label,
      waitDuration: LicoMotion.tooltipWait,
      child: Column(
        key: const Key('desktop-launchpad-plugin-slot'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: DesktopDesktopMetrics.featuresIconExtent,
            height: DesktopDesktopMetrics.featuresIconExtent,
            decoration: continuousHairlineDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(
                DesktopDesktopMetrics.featuresIconRadius,
              ),
              stroke: DesktopDesktopGlass.cardBorder(
                colors.line,
                isDark: colors.isDark,
              ),
              strokeWidth: 0.5,
            ),
            child: Icon(Icons.add_rounded, size: 24, color: colors.textMuted),
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: 76,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
