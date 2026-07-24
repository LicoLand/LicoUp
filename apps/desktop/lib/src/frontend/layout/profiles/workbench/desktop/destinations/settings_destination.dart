import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_settings_presentation.dart';

Widget workbenchDesktopSettingsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.settings);
  return LayoutDestinationPresentationScope(
    settings: const WorkbenchDesktopSettingsPresentation(),
    child: WorkbenchDesktopDestinationFrame(
      data: data,
      title: LicoStrings.of(context).settings,
      icon: Icons.tune_rounded,
      treatment: WorkbenchDesktopDestinationTreatment.preferences,
    ),
  );
}
