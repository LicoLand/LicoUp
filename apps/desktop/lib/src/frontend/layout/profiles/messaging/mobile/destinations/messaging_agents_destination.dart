import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/presentation/messaging_mobile_destination_presentations.dart';

/// The Messaging mobile Agents destination: installs the messaging
/// presentation strategy so the shared workspace renders the flat
/// conversation list and participant flow on the phone surface.
Widget buildMessagingMobileAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireAgentsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$messagingMobileRestorationPrefix.agents',
    child: Semantics(
      key: const Key('messaging-mobile-agents-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.background,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: LayoutDestinationPresentationScope(
              agents: messagingMobileAgentsPresentation,
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
    ),
  );
}

void _requireAgentsDestination(ClientSection destination) {
  if (destination != ClientSection.agents) {
    throw const FormatException('messaging_mobile_agents_destination_mismatch');
  }
}
