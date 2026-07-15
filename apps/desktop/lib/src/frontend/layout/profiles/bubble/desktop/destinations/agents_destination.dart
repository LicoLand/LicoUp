import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_destination_frame.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/desktop/presentation/bubble_desktop_destination_presentations.dart';

Widget buildBubbleAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => LayoutDestinationPresentationScope(
  agents: bubbleDesktopAgentsPresentation,
  child: BubbleDestinationFrame(
    data: data,
    expectedDestination: ClientSection.agents,
    icon: Icons.account_tree_outlined,
    dockPlacement: BubbleDestinationDockPlacement.trailing,
    accent: BubbleDestinationAccent.success,
  ),
);
