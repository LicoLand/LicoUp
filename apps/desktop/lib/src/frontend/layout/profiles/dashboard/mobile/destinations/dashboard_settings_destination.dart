import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_mobile_settings_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';

Widget buildDashboardSettingsDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  _verifySettingsContract(data);
  return LayoutDestinationPresentationScope(
    settings: const DashboardMobileSettingsPresentation(),
    child: Builder(
      builder: (context) {
        final content = data.content.buildDestination(
          context,
          ClientSection.settings,
        );
        return RestorationScope(
          restorationId: '$dashboardMobileRestorationPrefix.settings.content',
          child: const DashboardMobileComponentKit().card(
            context,
            key: const ValueKey<String>('dashboard-mobile-settings-card'),
            child: KeyedSubtree(
              key: const ValueKey<String>('dashboard-mobile-settings-content'),
              child: content,
            ),
          ),
        );
      },
    ),
  );
}

void _verifySettingsContract(LayoutDestinationBuildContext data) {
  if (data.destination != ClientSection.settings ||
      data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.state.surface != LayoutRuntimeSurface.mobile) {
    throw const FormatException(
      'dashboard_mobile_settings_destination_contract_invalid',
    );
  }
  data.state.read(LayoutStateChannels.settingsScroll);
  data.state.read(LayoutStateChannels.settingsSection);
}
