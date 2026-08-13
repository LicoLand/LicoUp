import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';

Widget buildMessagingMobilePairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requirePairingDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$messagingMobileRestorationPrefix.mobile-relay',
    child: Semantics(
      key: const Key('messaging-mobile-pairing-destination'),
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            left: BorderSide(
              color: colors.primaryStrong,
              width: MessagingMobileMetrics.hairline * 2,
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
    throw const FormatException(
      'messaging_mobile_pairing_destination_mismatch',
    );
  }
}
