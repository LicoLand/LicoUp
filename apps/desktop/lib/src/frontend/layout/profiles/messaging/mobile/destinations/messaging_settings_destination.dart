import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/presentation/messaging_mobile_destination_presentations.dart';

Widget buildMessagingMobileSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireSettingsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$messagingMobileRestorationPrefix.settings',
    child: Semantics(
      key: const Key('messaging-mobile-settings-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.surfaceLow,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            settings: messagingMobileSettingsPresentation,
            child: Builder(
              builder: (profileContext) => data.content.buildDestination(
                profileContext,
                data.destination,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _requireSettingsDestination(ClientSection destination) {
  if (destination != ClientSection.settings) {
    throw const FormatException(
      'messaging_mobile_settings_destination_mismatch',
    );
  }
}
