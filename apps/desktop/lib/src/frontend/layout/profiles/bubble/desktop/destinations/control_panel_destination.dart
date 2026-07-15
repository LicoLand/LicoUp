import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';

Widget buildBubbleControlPanelDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => BubbleDestinationFrame(
  data: data,
  expectedDestination: ClientSection.controlPanel,
  icon: Icons.dashboard_customize_outlined,
  dockPlacement: BubbleDestinationDockPlacement.top,
  accent: BubbleDestinationAccent.primary,
);
