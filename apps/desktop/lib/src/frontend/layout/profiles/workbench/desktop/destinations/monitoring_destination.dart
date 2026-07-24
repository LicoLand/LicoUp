import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

Widget workbenchDesktopMonitoringDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.monitoring);
  return WorkbenchDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).tokenUsage,
    icon: Icons.insights_rounded,
    treatment: WorkbenchDesktopDestinationTreatment.analytics,
  );
}
