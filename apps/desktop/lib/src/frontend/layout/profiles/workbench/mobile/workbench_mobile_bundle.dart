import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_pairing_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

final LayoutSurfaceBundle workbenchMobileBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('workbench'),
    label: LayoutProfileCopy(english: 'Lico Arc', chinese: 'Lico Arc'),
    description: LayoutProfileCopy(
      english:
          'Lico Arc standard layout (fallback): the cross-platform product shell used when Native is not the platform default.',
      chinese: 'Lico Arc 标准布局（缺省）：跨平台产品壳，在无原生系统风格时作为 Native 的回退。',
    ),
    styleIdentity: workbenchMobileStyleIdentity,
    isDefault: false,
  ),
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildWorkbenchMobileCompactShell,
      destinationBuilders: _workbenchMobileDestinationBuilders(),
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildWorkbenchMobileMediumShell,
      destinationBuilders: _workbenchMobileDestinationBuilders(),
    ),
  },
  previewBuilder: buildWorkbenchMobilePreview,
  tokens: workbenchMobileTokens,
  components: const WorkbenchMobileComponentKit(),
  assetNamespace: 'layout-profiles/workbench/mobile',
  restorationNamespace: workbenchMobileRestorationPrefix,
  stateNamespaces: {
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.mobile,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);

Map<ClientSection, LayoutDestinationBuilder>
_workbenchMobileDestinationBuilders() => {
  ClientSection.agents: buildWorkbenchAgentsDestination,
  ClientSection.mobileRelay: buildWorkbenchPairingDestination,
  ClientSection.settings: buildWorkbenchSettingsDestination,
};
