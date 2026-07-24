import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

Widget workbenchDesktopMobileRelayDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.mobileRelay);
  return WorkbenchDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).mobileRelay,
    icon: Icons.devices_rounded,
    treatment: WorkbenchDesktopDestinationTreatment.relay,
  );
}
