import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/destinations/dashboard_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';

final LayoutSurfaceBundle dashboardMobileBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.dashboard,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildDashboardMobileCompactShell,
      destinationBuilders: _dashboardMobileDestinationBuilders(),
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDashboardMobileMediumShell,
      destinationBuilders: _dashboardMobileDestinationBuilders(),
    ),
  },
  previewBuilder: buildDashboardMobilePreview,
  tokens: dashboardMobileTokens,
  components: const DashboardMobileComponentKit(),
  assetNamespace: 'layout-profiles/dashboard/mobile',
  restorationNamespace: dashboardMobileRestorationPrefix,
  stateNamespaces: BuiltInLayoutSpec.dashboardMobileStateNamespaces,
);

Map<ClientSection, LayoutDestinationBuilder>
_dashboardMobileDestinationBuilders() => {
  ClientSection.agents: buildDashboardAgentsDestination,
  ClientSection.mobileRelay: buildDashboardPairingDestination,
  ClientSection.settings: buildDashboardSettingsDestination,
};
