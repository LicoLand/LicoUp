import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_agents_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_feed_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_pairing_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/destinations/workbench_settings_destination.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_components.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

final LayoutSurfaceBundle workbenchMobileBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.workbench,
    labelKey: 'layout.profile.workbench.label',
    descriptionKey: 'layout.profile.workbench.description',
    styleIdentity: workbenchMobileStyleIdentity,
    isDefault: true,
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
    for (final destination in _workbenchMobileDestinations)
      LayoutStateNamespace(
        profileId: LayoutProfileId.workbench,
        surface: LayoutRuntimeSurface.mobile,
        destination: destination,
        surfaceId: 'content-scroll',
      ),
  },
);

const Set<ClientSection> _workbenchMobileDestinations = {
  ClientSection.agents,
  ClientSection.feed,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

Map<ClientSection, LayoutDestinationBuilder>
_workbenchMobileDestinationBuilders() => {
  ClientSection.agents: buildWorkbenchAgentsDestination,
  ClientSection.feed: buildWorkbenchFeedDestination,
  ClientSection.mobileRelay: buildWorkbenchPairingDestination,
  ClientSection.settings: buildWorkbenchSettingsDestination,
};
