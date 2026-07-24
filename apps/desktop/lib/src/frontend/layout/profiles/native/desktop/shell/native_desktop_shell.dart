import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_glass.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_icon_rail.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_top_bar.dart';

/// Native desktop shell in three flat layers: the icon rail and the top
/// band rest directly on the window background (lowest layer), the
/// conversation list sits one quiet step above it, and the destination
/// detail is the lightest, topmost surface. No floating cards, no title
/// band, no canvas seam.
Widget buildNativeDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _NativeLiquidShell(data: data);

Widget buildNativeDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _NativeLiquidShell(data: data);

final class _NativeLiquidShell extends StatelessWidget {
  const _NativeLiquidShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    assert(
      data.environment.surface == LayoutRuntimeSurface.desktop,
      'native_desktop_surface_invalid',
    );
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      return ColoredBox(color: colors.background);
    }

    return Semantics(
      key: const ValueKey<String>('native-desktop-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: ClipRRect(
        borderRadius: NativeDesktopChromeMetrics.windowBorderRadius,
        child: Material(
          color: colors.background,
          child: DecoratedBox(
            decoration: NativeGlass.windowAmbient(colors),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NativeIconRail(
                  chrome: data.chrome,
                  section: data.activeDestination,
                  onSelectSection: data.onSelectDestination,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NativeTopBar(chrome: data.chrome),
                      Expanded(
                        child: Semantics(
                          key: ValueKey<String>(
                            'native-desktop-focus-${data.initialFocusTarget}',
                          ),
                          container: true,
                          explicitChildNodes: true,
                          child: data.destination,
                        ),
                      ),
                    ],
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
