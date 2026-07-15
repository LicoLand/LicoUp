import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/presentation/bubble_desktop_destination_presentations.dart';

Widget buildBubbleSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  settings: bubbleDesktopSettingsPresentation,
  child: BubbleDestinationFrame(
    data: data,
    expectedDestination: ClientSection.settings,
    icon: Icons.tune_outlined,
    dockPlacement: BubbleDestinationDockPlacement.leading,
    accent: BubbleDestinationAccent.info,
  ),
);
