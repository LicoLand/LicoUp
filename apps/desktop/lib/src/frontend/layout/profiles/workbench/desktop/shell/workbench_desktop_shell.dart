import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_chrome.dart';

/// Workbench-owned carefully tuned top-bar desktop chrome.
Widget buildWorkbenchDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _WorkbenchTopbarShell(data: data);

Widget buildWorkbenchDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _WorkbenchTopbarShell(data: data);

final class _WorkbenchTopbarShell extends StatelessWidget {
  const _WorkbenchTopbarShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('workbench_desktop_surface_invalid');
    }
    final colors = context.layoutPalette;

    return Semantics(
      key: const ValueKey<String>('workbench-desktop-topbar-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: ClipRRect(
        borderRadius: WorkbenchDesktopChromeMetrics.windowBorderRadius,
        child: Material(
          color: colors.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WorkbenchDesktopTopBar(
                chrome: data.chrome,
                section: data.activeDestination,
                onSelectSection: data.onSelectDestination,
                onSearchSelect: data.onSelectDestination,
              ),
              Expanded(
                child: Semantics(
                  key: ValueKey<String>(
                    'workbench-desktop-focus-${data.initialFocusTarget}',
                  ),
                  container: true,
                  explicitChildNodes: true,
                  child: data.destination,
                ),
              ),
              WorkbenchDesktopStatusBar(chrome: data.chrome),
            ],
          ),
        ),
      ),
    );
  }
}
