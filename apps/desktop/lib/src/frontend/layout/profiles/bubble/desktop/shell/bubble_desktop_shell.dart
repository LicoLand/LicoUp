import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/chrome/bubble_desktop_chrome.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/chrome/bubble_desktop_glass.dart';

/// Bubble-owned carefully tuned sidebar-rail desktop chrome.
Widget buildBubbleDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _BubbleSidebarRailShell(data: data);

Widget buildBubbleDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _BubbleSidebarRailShell(data: data);

final class _BubbleSidebarRailShell extends StatelessWidget {
  const _BubbleSidebarRailShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('bubble_desktop_surface_invalid');
    }
    final palette = context.layoutPalette;

    return Semantics(
      key: const ValueKey<String>('bubble-desktop-sidebar-rail-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: ClipRRect(
        borderRadius: BubbleDesktopControlMetrics.windowBorderRadius,
        child: Material(
          color: palette.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BubbleDesktopSidebarRail(
                chrome: data.chrome,
                section: data.activeDestination,
                onSelectSection: data.onSelectDestination,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    BubbleDesktopContentTopBar(
                      section: data.activeDestination,
                      onSearchSelect: data.onSelectDestination,
                    ),
                    Expanded(
                      child: Semantics(
                        key: ValueKey<String>(
                          'bubble-desktop-focus-${data.initialFocusTarget}',
                        ),
                        container: true,
                        explicitChildNodes: true,
                        child: data.destination,
                      ),
                    ),
                    BubbleDesktopStatusBar(chrome: data.chrome),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
