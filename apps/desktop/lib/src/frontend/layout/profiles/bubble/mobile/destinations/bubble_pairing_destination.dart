import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';

Widget buildBubbleMobilePairingDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requirePairingDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$bubbleMobileRestorationPrefix.mobile-relay',
    child: Semantics(
      key: const Key('bubble-mobile-pairing-destination'),
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            left: BorderSide(
              color: colors.primary,
              width: BubbleMobileMetrics.hairline * 2,
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
    throw const FormatException('bubble_mobile_pairing_destination_mismatch');
  }
}
