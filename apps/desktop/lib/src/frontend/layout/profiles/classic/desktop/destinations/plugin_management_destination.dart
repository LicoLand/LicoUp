import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/classic_destination_frame.dart';

Widget classicDesktopPluginManagementDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateClassicDesktopDestination(data, ClientSection.pluginManagement);
  return ClassicDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).pluginManagement,
    icon: Icons.extension_outlined,
    treatment: ClassicDesktopDestinationTreatment.extensions,
  );
}
