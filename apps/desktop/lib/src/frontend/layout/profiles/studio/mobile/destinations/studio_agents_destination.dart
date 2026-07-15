import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/presentation/studio_mobile_destination_presentations.dart';

Widget buildStudioMobileAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireAgentsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$studioMobileRestorationPrefix.agents',
    child: Semantics(
      key: const Key('studio-mobile-agents-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.background,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            agents: studioMobileAgentsPresentation,
            child: Builder(
              builder: (profileContext) => data.content.buildDestination(
                profileContext,
                data.destination,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _requireAgentsDestination(ClientSection destination) {
  if (destination != ClientSection.agents) {
    throw const FormatException('studio_mobile_agents_destination_mismatch');
  }
}
