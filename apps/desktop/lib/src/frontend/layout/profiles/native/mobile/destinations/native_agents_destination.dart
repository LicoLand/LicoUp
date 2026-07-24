import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/native_mobile_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/native/mobile/presentation/native_mobile_destination_presentations.dart';

Widget buildNativeMobileAgentsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireAgentsDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$nativeMobileRestorationPrefix.agents',
    child: Semantics(
      key: const Key('native-mobile-agents-destination'),
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        color: colors.background,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: LayoutDestinationPresentationScope(
            agents: nativeMobileAgentsPresentation,
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

void _requireAgentsDestination(ClientSection destination) {
  if (destination != ClientSection.agents) {
    throw const FormatException('native_mobile_agents_destination_mismatch');
  }
}
