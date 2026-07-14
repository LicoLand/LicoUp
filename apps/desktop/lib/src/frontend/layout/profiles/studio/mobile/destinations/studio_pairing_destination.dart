import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

Widget buildStudioMobilePairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requirePairingDestination(data.destination);
  final colors = context.licoColors;
  return RestorationScope(
    restorationId: '$studioMobileRestorationPrefix.mobile-relay',
    child: Semantics(
      key: const Key('studio-mobile-pairing-destination'),
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            left: BorderSide(
              color: colors.primary,
              width: StudioMobileMetrics.hairline * 2,
            ),
          ),
        ),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: data.content.buildDestination(context, data.destination),
        ),
      ),
    ),
  );
}

void _requirePairingDestination(ClientSection destination) {
  if (destination != ClientSection.mobileRelay) {
    throw const FormatException('studio_mobile_pairing_destination_mismatch');
  }
}
