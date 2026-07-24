import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

Widget buildWorkbenchPairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyPairingContract(data);
  final content = data.content.buildDestination(
    context,
    ClientSection.mobileRelay,
  );
  return RestorationScope(
    restorationId: '$workbenchMobileRestorationPrefix.mobile-relay.content',
    child: const WorkbenchMobileComponentKit().card(
      context,
      key: const ValueKey<String>('workbench-mobile-pairing-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('workbench-mobile-pairing-content'),
        child: content,
      ),
    ),
  );
}

void _verifyPairingContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.mobileRelay ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'workbench_mobile_pairing_destination_contract_invalid',
    );
  }
}
