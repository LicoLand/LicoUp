import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/presentation/studio_desktop_destination_presentations.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_desktop_chrome_metrics.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_safari_sidebar.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_sidebar_content_top_bar.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_status_bar.dart';

/// Native desktop shell: Safari-style left navigation card + unified canvas.
Widget buildStudioDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _StudioSafariShell(data: data);

Widget buildStudioDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _StudioSafariShell(data: data);

final class _StudioSafariShell extends StatefulWidget {
  const _StudioSafariShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_StudioSafariShell> createState() => _StudioSafariShellState();
}

final class _StudioSafariShellState extends State<_StudioSafariShell> {
  bool _sidebarCollapsed = false;
  double _sidebarWidth = studioSafariSidebarWidth;

  void _toggleSidebarCollapsed() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
  }

  void _onSidebarWidthDelta(double delta) {
    setState(() {
      _sidebarWidth = (_sidebarWidth + delta)
          .clamp(studioSafariSidebarMinWidth, studioSafariSidebarMaxWidth)
          .toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('studio_desktop_surface_invalid');
    }
    final colors = context.layoutPalette;
    final canvas = studioDesktopAgentsPresentation.canvasColor(colors);

    return Semantics(
      key: const ValueKey<String>('studio-desktop-safari-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: ClipRRect(
        borderRadius: StudioDesktopChromeMetrics.windowBorderRadius,
        child: Material(
          color: canvas,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StudioSafariSidebar(
                chrome: data.chrome,
                section: data.activeDestination,
                onSelectSection: data.onSelectDestination,
                width: _sidebarWidth,
                onWidthDelta: _onSidebarWidthDelta,
                collapsed: _sidebarCollapsed,
                onToggleCollapsed: _toggleSidebarCollapsed,
              ),
              Expanded(
                child: ColoredBox(
                  color: canvas,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      StudioSidebarContentTopBar(
                        section: data.activeDestination,
                        onSearchSelect: data.onSelectDestination,
                        backgroundColor: canvas,
                      ),
                      Expanded(
                        child: Semantics(
                          key: ValueKey<String>(
                            'studio-desktop-focus-${data.initialFocusTarget}',
                          ),
                          container: true,
                          explicitChildNodes: true,
                          child: data.destination,
                        ),
                      ),
                      StudioStatusBar(
                        chrome: data.chrome,
                        backgroundColor: canvas,
                        showTopBorder: false,
                      ),
                    ],
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
