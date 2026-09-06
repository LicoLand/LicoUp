import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_tokens.dart';

Widget buildDesktopPairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyPairingContract(data);
  final content = data.content.buildDestination(
    context,
    ClientSection.mobileRelay,
  );
  return RestorationScope(
    restorationId: '$desktopMobileRestorationPrefix.mobile-relay.content',
    child: const DesktopMobileComponentKit().card(
      context,
      key: const ValueKey<String>('desktop-mobile-pairing-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('desktop-mobile-pairing-content'),
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
      'desktop_mobile_pairing_destination_contract_invalid',
    );
  }
}
