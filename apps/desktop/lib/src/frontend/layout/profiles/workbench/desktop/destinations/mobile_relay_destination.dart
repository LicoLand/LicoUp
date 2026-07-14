import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

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
