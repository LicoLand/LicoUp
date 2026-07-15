import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';

Widget buildClassicPairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyPairingContract(data);
  final content = data.content.buildDestination(
    context,
    ClientSection.mobileRelay,
  );
  return RestorationScope(
    restorationId: '$classicMobileRestorationPrefix.mobile-relay.content',
    child: const ClassicMobileComponentKit().card(
      context,
      key: const ValueKey<String>('classic-mobile-pairing-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('classic-mobile-pairing-content'),
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
      'classic_mobile_pairing_destination_contract_invalid',
    );
  }
}
