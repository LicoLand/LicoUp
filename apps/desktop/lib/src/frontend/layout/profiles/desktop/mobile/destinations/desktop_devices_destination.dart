import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_tokens.dart';

Widget buildDesktopDevicesDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyDevicesContract(data);
  final content = data.content.buildDestination(context, ClientSection.devices);
  return RestorationScope(
    restorationId: '$desktopMobileRestorationPrefix.devices.content',
    child: const DesktopMobileComponentKit().card(
      context,
      key: const ValueKey<String>('desktop-mobile-devices-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('desktop-mobile-devices-content'),
        child: content,
      ),
    ),
  );
}

void _verifyDevicesContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.devices ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'desktop_mobile_devices_destination_contract_invalid',
    );
  }
}
