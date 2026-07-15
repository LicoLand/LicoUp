import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

Widget buildWorkbenchFeedDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifyFeedContract(data);
  final content = data.content.buildDestination(context, ClientSection.feed);
  return RestorationScope(
    restorationId: '$workbenchMobileRestorationPrefix.feed.content',
    child: const WorkbenchMobileComponentKit().card(
      context,
      key: const ValueKey<String>('workbench-mobile-feed-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('workbench-mobile-feed-content'),
        child: content,
      ),
    ),
  );
}

void _verifyFeedContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.feed ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'workbench_mobile_feed_destination_contract_invalid',
    );
  }
}
