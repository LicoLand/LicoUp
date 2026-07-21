import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/native_destination_frame.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/presentation/native_desktop_destination_presentations.dart';

Widget buildNativeSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: nativeDesktopSettingsPresentation,
  child: NativeDestinationFrame(
    data: data,
    expectedDestination: ClientSection.settings,
  ),
);
