import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/destinations/native_destination_frame.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/presentation/native_desktop_destination_presentations.dart';

Widget buildNativeAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  agents: nativeDesktopAgentsPresentation,
  child: NativeDestinationFrame(
    data: data,
    expectedDestination: ClientSection.agents,
  ),
);
