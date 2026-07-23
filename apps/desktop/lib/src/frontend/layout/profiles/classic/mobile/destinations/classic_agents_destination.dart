import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_mobile_agents_presentation.dart';

Widget buildClassicAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyAgentsContract(data);
  final content = data.content.buildDestination(context, ClientSection.agents);
  return LayoutDestinationPresentationScope(
    agents: const ClassicMobileAgentsPresentation(),
    child: RestorationScope(
      restorationId: '$classicMobileRestorationPrefix.agents.content',
      child: const ClassicMobileComponentKit().card(
        context,
        key: const ValueKey<String>('classic-mobile-agents-card'),
        child: KeyedSubtree(
          key: const ValueKey<String>('classic-mobile-agents-content'),
          child: content,
        ),
      ),
    ),
  );
}

void _verifyAgentsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.agents ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'classic_mobile_agents_destination_contract_invalid',
    );
  }
  for (final channel in const {
    LayoutStateChannels.agentsHistory,
    LayoutStateChannels.agentsSidebar,
  }) {
    data.state.read(channel);
  }
}
