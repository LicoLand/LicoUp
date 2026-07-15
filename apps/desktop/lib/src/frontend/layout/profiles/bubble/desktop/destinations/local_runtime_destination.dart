import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';

Widget buildBubbleLocalRuntimeDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => BubbleDestinationFrame(
  data: data,
  expectedDestination: ClientSection.localRuntime,
  icon: Icons.terminal_outlined,
  dockPlacement: BubbleDestinationDockPlacement.leading,
  accent: BubbleDestinationAccent.warning,
);
