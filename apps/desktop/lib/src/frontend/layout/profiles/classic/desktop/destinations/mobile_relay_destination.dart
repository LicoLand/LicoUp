import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/destinations/classic_destination_frame.dart';

Widget classicDesktopMobileRelayDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateClassicDesktopDestination(data, ClientSection.mobileRelay);
  return ClassicDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).mobileRelay,
    icon: Icons.devices_rounded,
    treatment: ClassicDesktopDestinationTreatment.relay,
  );
}
