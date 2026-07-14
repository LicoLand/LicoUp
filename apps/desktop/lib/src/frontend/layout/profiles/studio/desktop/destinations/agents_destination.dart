import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/studio_destination_frame.dart';

Widget buildStudioAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => StudioDestinationFrame(
  data: data,
  expectedDestination: ClientSection.agents,
  icon: Icons.account_tree_outlined,
  dockPlacement: StudioDestinationDockPlacement.trailing,
  accent: StudioDestinationAccent.success,
);
