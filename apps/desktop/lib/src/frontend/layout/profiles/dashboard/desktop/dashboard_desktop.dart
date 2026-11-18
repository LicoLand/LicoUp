import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/components/dashboard_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/destinations/dashboard_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/preview/dashboard_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_card_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_plain_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

/// Dashboard's desktop shell for the effective style: the plain rail
/// layout for `plain`, the floating card card layout for
/// `card`.
Widget _dashboardDesktopShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => dashboardPlainStyleActive(data.style)
    ? buildDashboardPlainShell(context, data)
    : buildDashboardCardShell(context, data);

/// The sole public handoff from the Default desktop renderer boundary.
final LayoutSurfaceBundle dashboardDesktopBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.dashboard,
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: _dashboardDesktopShell,
      destinationBuilders: dashboardDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: _dashboardDesktopShell,
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
