import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

Widget workbenchDesktopPluginManagementDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.pluginManagement);
  return WorkbenchDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).pluginManagement,
    icon: Icons.extension_outlined,
    treatment: WorkbenchDesktopDestinationTreatment.extensions,
  );
}
