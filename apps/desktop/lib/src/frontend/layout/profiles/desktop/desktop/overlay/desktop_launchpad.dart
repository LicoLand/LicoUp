import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// One Launchpad grid entry. Built-in entries launch a [DesktopAppId]; the
/// trailing plugin slot is a documented extension point: future
/// user-developed plugins register their own [DesktopLaunchpadEntry] values
/// through [DesktopLaunchpad.extraEntries] and appear in the same matrix.
final class DesktopLaunchpadEntry {
  const DesktopLaunchpadEntry({this.app, this.isPluginSlot = false});

  final DesktopAppId? app;

  /// The reserved slot where future user plugins appear.
  final bool isPluginSlot;
}

/// The Launchpad-style app store: a centered, pure black floating rounded
/// panel with a matrix of rounded-square app icons covering the seven
/// feature apps, 对话, and the plugin extension slot. Tapping the scrim
/// dismisses; tapping an icon launches the app.
final class DesktopLaunchpad extends StatelessWidget {
  const DesktopLaunchpad({
    super.key,
    required this.onLaunchApp,
    required this.onDismiss,
    this.extraEntries = const [],
  });

  final ValueChanged<DesktopAppId> onLaunchApp;
  final VoidCallback onDismiss;

  /// Plugin extension point: additional entries future user plugins supply.
  final List<DesktopLaunchpadEntry> extraEntries;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final entries = <DesktopLaunchpadEntry>[
      for (final app in desktopLaunchpadBuiltinApps)
        DesktopLaunchpadEntry(app: app),
      const DesktopLaunchpadEntry(isPluginSlot: true),
      ...extraEntries,
    ];
    return Semantics(
      key: const Key('desktop-launchpad'),
      container: true,
      label: DesktopDesktopCopy.appStoreTitle(strings),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: DesktopDesktopMetrics.launchpadMaxWidth,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: desktopDesktopSurfaceBlack,
                  borderRadius: BorderRadius.circular(
                    DesktopDesktopMetrics.launchpadRadius,
                  ),
                  border: Border.all(
                    color: DesktopDesktopOnBlack.line,
                    width: 0.5,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x73000000),
                      blurRadius: 36,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 36,
                    vertical: 32,
                  ),
                  child: Wrap(
                    spacing: DesktopDesktopMetrics.launchpadColumnGap,
                    runSpacing: DesktopDesktopMetrics.launchpadRowGap,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final entry in entries)
                        entry.isPluginSlot
                            ? const _DesktopLaunchpadPluginSlot()
                            : _DesktopLaunchpadIcon(
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
            ),
          ),
        ),
      ),
    );
  }
}

final class _DesktopLaunchpadIcon extends StatefulWidget {
  const _DesktopLaunchpadIcon({
    super.key,
    required this.app,
    required this.onTap,
  });

  final DesktopAppId app;
  final VoidCallback onTap;

  @override
  State<_DesktopLaunchpadIcon> createState() => _DesktopLaunchpadIconState();
}

final class _DesktopLaunchpadIconState extends State<_DesktopLaunchpadIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = desktopAppLabel(strings, widget.app);
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
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
                  duration: context.motion(LicoMotion.micro),
                  width: DesktopDesktopMetrics.launchpadIconExtent,
                  height: DesktopDesktopMetrics.launchpadIconExtent,
                  decoration: BoxDecoration(
                    color: _hovered
                        ? DesktopDesktopOnBlack.hoverOverlay
                        : desktopDesktopSurfaceBlack,
                    borderRadius: BorderRadius.circular(
                      DesktopDesktopMetrics.launchpadIconRadius,
                    ),
                    border: Border.all(
                      color: DesktopDesktopOnBlack.line,
                      width: 0.5,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    desktopAppIcon(widget.app),
                    size: 28,
                    color: _hovered
                        ? DesktopDesktopOnBlack.text
                        : DesktopDesktopOnBlack.textSecondary,
                  ),
                ),
                const SizedBox(height: 7),
                SizedBox(
                  width: 84,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: DesktopDesktopOnBlack.text,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
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

/// The reserved matrix slot future user-developed plugins occupy.
final class _DesktopLaunchpadPluginSlot extends StatelessWidget {
  const _DesktopLaunchpadPluginSlot();

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final label = DesktopDesktopCopy.pluginSlotLabel(strings);
    return Tooltip(
      message: label,
      child: Column(
        key: const Key('desktop-launchpad-plugin-slot'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: DesktopDesktopMetrics.launchpadIconExtent,
            height: DesktopDesktopMetrics.launchpadIconExtent,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(
                DesktopDesktopMetrics.launchpadIconRadius,
              ),
              border: Border.all(color: DesktopDesktopOnBlack.line, width: 0.5),
            ),
            child: const Icon(
              Icons.add_rounded,
              size: 24,
              color: DesktopDesktopOnBlack.textMuted,
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            width: 84,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: DesktopDesktopOnBlack.textMuted,
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
