import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

Widget buildWorkbenchAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyAgentsContract(data);
  final content = data.content.buildDestination(context, ClientSection.agents);
  return RestorationScope(
    restorationId: '$workbenchMobileRestorationPrefix.agents.content',
    child: const WorkbenchMobileComponentKit().card(
      context,
      key: const ValueKey<String>('workbench-mobile-agents-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('workbench-mobile-agents-content'),
        child: content,
      ),
    ),
  );
}

void _verifyAgentsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.agents ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.profileId != LayoutProfileId.workbench ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'workbench_mobile_agents_destination_contract_invalid',
    );
  }
  // The scoped read validates that the parent catalog declared this bounded
  // presentation address. Domain state remains exclusively in the content port.
  data.state.read(
    destination: ClientSection.agents,
    surfaceId: 'content-scroll',
  );
}
