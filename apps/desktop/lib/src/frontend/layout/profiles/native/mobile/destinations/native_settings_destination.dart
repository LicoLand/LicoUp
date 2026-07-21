import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/mobile/native_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/mobile/presentation/native_mobile_destination_presentations.dart';

Widget buildNativeMobileSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireSettingsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$nativeMobileRestorationPrefix.settings',
    child: Semantics(
      key: const Key('native-mobile-settings-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.surfaceLow,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            settings: nativeMobileSettingsPresentation,
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
    throw const FormatException('native_mobile_settings_destination_mismatch');
  }
}
