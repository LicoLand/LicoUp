import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/components/workbench_desktop_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/control_panel_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/local_runtime_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/mcp_plugins_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/mobile_relay_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/monitoring_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/preview/workbench_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/tokens/workbench_desktop_tokens.dart';

/// The sole public artifact of the workbench desktop renderer.
final LayoutSurfaceBundle workbenchDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.workbench,
    labelKey: 'layout.profile.workbench.label',
    descriptionKey: 'layout.profile.workbench.description',
    styleIdentity: 'spacious-card-workbench',
    isDefault: true,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: {
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildWorkbenchDesktopMediumShell,
      destinationBuilders: _workbenchDesktopDestinationBuilders(),
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildWorkbenchDesktopExpandedShell,
      destinationBuilders: _workbenchDesktopDestinationBuilders(),
    ),
  },
  previewBuilder: buildWorkbenchDesktopPreview,
  tokens: workbenchDesktopTokens,
  components: const WorkbenchDesktopComponentKit(),
  assetNamespace: 'layout-profiles/workbench/desktop',
  restorationNamespace: 'workbench.desktop',
  stateNamespaces: {
    for (final destination in _workbenchDesktopDestinations)
      LayoutStateNamespace(
        profileId: LayoutProfileId.workbench,
        surface: LayoutRuntimeSurface.desktop,
        destination: destination,
        surfaceId: 'content-scroll',
      ),
  },
);

const Set<ClientSection> _workbenchDesktopDestinations = {
  ClientSection.controlPanel,
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.mcpPlugins,
  ClientSection.localRuntime,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

Map<ClientSection, LayoutDestinationBuilder>
_workbenchDesktopDestinationBuilders() => {
  ClientSection.controlPanel: workbenchDesktopControlPanelDestinationBuilder,
  ClientSection.agents: workbenchDesktopAgentsDestinationBuilder,
  ClientSection.monitoring: workbenchDesktopMonitoringDestinationBuilder,
  ClientSection.mcpPlugins: workbenchDesktopMcpPluginsDestinationBuilder,
  ClientSection.localRuntime: workbenchDesktopLocalRuntimeDestinationBuilder,
  ClientSection.mobileRelay: workbenchDesktopMobileRelayDestinationBuilder,
  ClientSection.settings: workbenchDesktopSettingsDestinationBuilder,
};
