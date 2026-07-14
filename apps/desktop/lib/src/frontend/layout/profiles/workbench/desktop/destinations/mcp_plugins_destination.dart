import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

Widget workbenchDesktopMcpPluginsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.mcpPlugins);
  return WorkbenchDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).extensionsHub,
    icon: Icons.extension_rounded,
    treatment: WorkbenchDesktopDestinationTreatment.extensions,
  );
}
