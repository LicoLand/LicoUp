import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/components/studio_desktop_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/destinations/studio_desktop_destination_builders.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/preview/studio_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_desktop_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/tokens/studio_desktop_tokens.dart';

/// The sole public handoff from the Studio desktop renderer boundary.
final LayoutSurfaceBundle studioDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.studio,
    labelKey: 'layout.profile.studio.label',
    descriptionKey: 'layout.profile.studio.description',
    styleIdentity: 'dense-docked-studio',
    isDefault: false,
    revision: 1,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildStudioDesktopMediumShell,
      destinationBuilders: studioDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildStudioDesktopExpandedShell,
      destinationBuilders: studioDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildStudioDesktopPreview,
  tokens: studioDesktopTokens,
  components: studioDesktopComponentKit,
  assetNamespace: 'layout-profiles/studio/desktop',
  restorationNamespace: 'studio.desktop',
  stateNamespaces: <LayoutStateNamespace>{
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.controlPanel,
      surfaceId: 'overview-grid',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      surfaceId: 'conversation-dock',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.monitoring,
      surfaceId: 'telemetry-range',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.mcpPlugins,
      surfaceId: 'extension-inspector',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.localRuntime,
      surfaceId: 'runtime-console',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.mobileRelay,
      surfaceId: 'relay-session',
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.studio,
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      surfaceId: 'settings-inspector',
    ),
  },
);
