import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/components/dashboard_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/preview/dashboard_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// The sole public handoff from the Default desktop renderer boundary.
final LayoutSurfaceBundle dashboardDesktopBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.dashboard,
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDashboardDesktopMediumShell,
      destinationBuilders: dashboardDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildDashboardDesktopExpandedShell,
      destinationBuilders: dashboardDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildDashboardDesktopPreview,
  tokens: dashboardDesktopTokens,
  components: dashboardDesktopComponentKit,
  assetNamespace: 'layout-profiles/dashboard/desktop',
  restorationNamespace: 'dashboard.desktop',
  stateNamespaces: BuiltInLayoutSpec.dashboardDesktopStateNamespaces,
);
