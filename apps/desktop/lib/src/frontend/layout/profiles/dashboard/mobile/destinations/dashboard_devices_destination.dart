import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

Widget buildDashboardMobileDevicesDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireDevicesDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$dashboardMobileRestorationPrefix.devices',
    child: Semantics(
      key: const Key('dashboard-mobile-devices-destination'),
      container: true,
      explicitChildNodes: true,
      child: CustomPaint(
        foregroundPainter: ContinuousEdgeHairlinePainter(
          color: colors.primaryStrong,
          edge: AxisDirection.left,
          width: DashboardMobileMetrics.hairline * 2,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: colors.background),
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: data.content.buildDestination(context, data.destination),
          ),
        ),
      ),
    ),
  );
}

void _requireDevicesDestination(ClientSection destination) {
  if (destination != ClientSection.devices) {
    throw const FormatException(
      'dashboard_mobile_devices_destination_mismatch',
    );
  }
}
