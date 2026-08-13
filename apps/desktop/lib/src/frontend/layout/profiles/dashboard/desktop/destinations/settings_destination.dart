import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_settings_presentation.dart';

Widget dashboardDesktopSettingsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateDashboardDesktopDestination(data, ClientSection.settings);
  return LayoutDestinationPresentationScope(
    settings: const DashboardDesktopSettingsPresentation(),
    child: DashboardDesktopDestinationFrame(
      data: data,
      title: LicoStrings.of(context).settings,
    ),
  );
}
