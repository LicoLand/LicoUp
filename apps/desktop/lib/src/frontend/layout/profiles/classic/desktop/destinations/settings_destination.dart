import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/destinations/classic_destination_frame.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/destinations/classic_settings_presentation.dart';

Widget classicDesktopSettingsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateClassicDesktopDestination(data, ClientSection.settings);
  return LayoutDestinationPresentationScope(
    settings: const ClassicDesktopSettingsPresentation(),
    child: ClassicDesktopDestinationFrame(
      data: data,
      title: LicoStrings.of(context).settings,
      icon: Icons.tune_rounded,
      treatment: ClassicDesktopDestinationTreatment.preferences,
    ),
  );
}
