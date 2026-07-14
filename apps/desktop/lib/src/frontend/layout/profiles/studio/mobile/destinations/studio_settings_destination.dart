import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

Widget buildStudioMobileSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireSettingsDestination(data.destination);
  final colors = context.licoColors;
  return RestorationScope(
    restorationId: '$studioMobileRestorationPrefix.settings',
    child: Semantics(
      key: const Key('studio-mobile-settings-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.surfaceLow,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: data.content.buildDestination(context, data.destination),
        ),
      ),
    ),
  );
}

void _requireSettingsDestination(ClientSection destination) {
  if (destination != ClientSection.settings) {
    throw const FormatException('studio_mobile_settings_destination_mismatch');
  }
}
