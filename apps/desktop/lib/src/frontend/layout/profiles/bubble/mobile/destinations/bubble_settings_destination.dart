import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/mobile/presentation/bubble_mobile_destination_presentations.dart';

Widget buildBubbleMobileSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireSettingsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$bubbleMobileRestorationPrefix.settings',
    child: Semantics(
      key: const Key('bubble-mobile-settings-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.surfaceLow,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            settings: bubbleMobileSettingsPresentation,
            child: data.content.buildDestination(context, data.destination),
          ),
        ),
      ),
    ),
  );
}

void _requireSettingsDestination(ClientSection destination) {
  if (destination != ClientSection.settings) {
    throw const FormatException('bubble_mobile_settings_destination_mismatch');
  }
}
