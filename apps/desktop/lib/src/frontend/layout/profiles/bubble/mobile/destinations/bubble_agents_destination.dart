import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/presentation/bubble_mobile_destination_presentations.dart';

Widget buildBubbleMobileAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireAgentsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$bubbleMobileRestorationPrefix.agents',
    child: Semantics(
      key: const Key('bubble-mobile-agents-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.background,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            agents: bubbleMobileAgentsPresentation,
            child: data.content.buildDestination(context, data.destination),
          ),
        ),
      ),
    ),
  );
}

void _requireAgentsDestination(ClientSection destination) {
  if (destination != ClientSection.agents) {
    throw const FormatException('bubble_mobile_agents_destination_mismatch');
  }
}
