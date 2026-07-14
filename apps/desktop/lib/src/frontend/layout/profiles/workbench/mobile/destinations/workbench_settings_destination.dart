import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

Widget buildWorkbenchSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifySettingsContract(data);
  final content = data.content.buildDestination(
    context,
    ClientSection.settings,
  );
  return RestorationScope(
    restorationId: '$workbenchMobileRestorationPrefix.settings.content',
    child: const WorkbenchMobileComponentKit().card(
      context,
      key: const ValueKey<String>('workbench-mobile-settings-card'),
      child: KeyedSubtree(
        key: const ValueKey<String>('workbench-mobile-settings-content'),
        child: content,
      ),
    ),
  );
}

void _verifySettingsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.settings ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.profileId != LayoutProfileId.workbench ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'workbench_mobile_settings_destination_contract_invalid',
    );
  }
  data.state.read(
    destination: ClientSection.settings,
    surfaceId: 'content-scroll',
  );
}
