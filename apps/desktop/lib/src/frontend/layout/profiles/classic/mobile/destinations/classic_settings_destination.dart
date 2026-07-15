import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/destinations/classic_mobile_settings_presentation.dart';

Widget buildClassicSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifySettingsContract(data);
  final content = data.content.buildDestination(
    context,
    ClientSection.settings,
  );
  return LayoutDestinationPresentationScope(
    settings: const ClassicMobileSettingsPresentation(),
    child: RestorationScope(
      restorationId: '$classicMobileRestorationPrefix.settings.content',
      child: const ClassicMobileComponentKit().card(
        context,
        key: const ValueKey<String>('classic-mobile-settings-card'),
        child: KeyedSubtree(
          key: const ValueKey<String>('classic-mobile-settings-content'),
          child: content,
        ),
      ),
    ),
  );
}

void _verifySettingsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.settings ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'classic_mobile_settings_destination_contract_invalid',
    );
  }
  data.state.read(LayoutStateChannels.settingsScroll);
  data.state.read(LayoutStateChannels.settingsSection);
}
