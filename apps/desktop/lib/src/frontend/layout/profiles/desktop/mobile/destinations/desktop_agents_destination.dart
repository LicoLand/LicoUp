import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_mobile_agents_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_tokens.dart';

Widget buildDesktopAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyAgentsContract(data);
  return LayoutDestinationPresentationScope(
    agents: const DesktopMobileAgentsPresentation(),
    child: Builder(
      builder: (context) {
        final content = data.content.buildDestination(
          context,
          ClientSection.agents,
        );
        return RestorationScope(
          restorationId: '$desktopMobileRestorationPrefix.agents.content',
          child: const DesktopMobileComponentKit().card(
            context,
            key: const ValueKey<String>('desktop-mobile-agents-card'),
            child: KeyedSubtree(
              key: const ValueKey<String>('desktop-mobile-agents-content'),
              child: content,
            ),
          ),
        );
      },
    ),
  );
}

void _verifyAgentsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.agents ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'desktop_mobile_agents_destination_contract_invalid',
    );
  }
  for (final channel in const {
    LayoutStateChannels.agentsHistory,
    LayoutStateChannels.agentsSidebar,
  }) {
    data.state.read(channel);
  }
}
