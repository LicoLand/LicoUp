import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';

Widget buildBubbleMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => BubbleDestinationFrame(
  data: data,
  expectedDestination: ClientSection.monitoring,
  icon: Icons.monitor_heart_outlined,
  dockPlacement: BubbleDestinationDockPlacement.top,
  accent: BubbleDestinationAccent.info,
);
