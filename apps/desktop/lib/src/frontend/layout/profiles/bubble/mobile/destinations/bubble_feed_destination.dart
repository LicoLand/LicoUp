import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';

Widget buildBubbleMobileFeedDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _requireFeedDestination(data.destination);
  final colors = context.layoutPalette;
  return RestorationScope(
    restorationId: '$bubbleMobileRestorationPrefix.feed',
    child: Semantics(
      key: const Key('bubble-mobile-feed-destination'),
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            top: BorderSide(
              color: colors.info.withAlpha(colors.isDark ? 96 : 64),
              width: BubbleMobileMetrics.hairline,
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

void _requireFeedDestination(ClientSection destination) {
  if (destination != ClientSection.feed) {
    throw const FormatException('bubble_mobile_feed_destination_mismatch');
  }
}
