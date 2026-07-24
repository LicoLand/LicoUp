import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/shell/native_glass.dart';

/// Native destination adapter: every destination rests inside one
/// container card standing off the window's trailing and bottom edges.
/// Agents uses the quieter workspace tone (its detail nests as a separate
/// inner card); single-pane destinations use the lightest detail tone.
final class NativeDestinationFrame extends StatelessWidget {
  const NativeDestinationFrame({
    super.key,
    required this.data,
    required this.expectedDestination,
  });

  final LayoutDestinationBuildContext data;
  final ClientSection expectedDestination;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop ||
        data.destination != expectedDestination) {
      throw const FormatException('native_desktop_destination_mismatch');
    }

    final destination = data.content.buildDestination(
      context,
      expectedDestination,
    );
    final colors = context.layoutPalette;
    final framed = Padding(
      padding: const EdgeInsets.only(
        right: NativeDesktopChromeMetrics.detailCardMargin,
        bottom: NativeDesktopChromeMetrics.detailCardMargin,
      ),
      child: Container(
        decoration: expectedDestination == ClientSection.agents
            ? NativeGlass.workspaceCard(colors)
            : NativeGlass.detailCard(colors),
        child: ClipRRect(
          borderRadius: NativeGlass.detailCardClipRadius,
          child: destination,
        ),
      ),
    );
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: KeyedSubtree(
        key: ValueKey<String>(
          'native-desktop-destination-${expectedDestination.name}',
        ),
        child: KeyedSubtree(
          key: ValueKey<String>(
            'native-desktop-${expectedDestination.name}-content',
          ),
          child: framed,
        ),
      ),
    );
  }
}
