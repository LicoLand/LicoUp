import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/studio_destination_frame.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/presentation/studio_desktop_destination_presentations.dart';

Widget buildStudioSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: studioDesktopSettingsPresentation,
  child: StudioDestinationFrame(
    data: data,
    expectedDestination: ClientSection.settings,
  ),
);
