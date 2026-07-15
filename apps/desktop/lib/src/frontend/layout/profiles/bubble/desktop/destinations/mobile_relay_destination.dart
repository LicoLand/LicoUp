import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';

Widget buildBubbleMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => BubbleDestinationFrame(
  data: data,
  expectedDestination: ClientSection.mobileRelay,
  icon: Icons.phonelink_ring_outlined,
  dockPlacement: BubbleDestinationDockPlacement.trailing,
  accent: BubbleDestinationAccent.success,
);
