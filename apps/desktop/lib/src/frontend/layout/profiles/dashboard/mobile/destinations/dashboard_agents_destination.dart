import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_material_scope.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/presentation/dashboard_mobile_destination_presentations.dart';

/// The Dashboard mobile Agents destination: installs the messaging
/// presentation strategy so the shared workspace renders the flat
/// conversation list and participant flow on the phone surface.
Widget buildDashboardMobileAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireAgentsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$dashboardMobileRestorationPrefix.agents',
    child: Semantics(
      key: const Key('dashboard-mobile-agents-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.background,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: LayoutDestinationPresentationScope(
              agents: dashboardMobileAgentsPresentation,
              child: ConversationMaterialScope(
                opaqueBubbles: true,
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
    ),
  );
}

void _requireAgentsDestination(ClientSection destination) {
  if (destination != ClientSection.agents) {
    throw const FormatException('dashboard_mobile_agents_destination_mismatch');
  }
}
