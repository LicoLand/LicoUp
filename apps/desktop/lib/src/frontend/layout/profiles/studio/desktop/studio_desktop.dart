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
    id: LayoutProfileId.parse('studio'),
    label: LayoutProfileCopy(english: 'Native', chinese: 'Native'),
    description: LayoutProfileCopy(
      english:
          'Native layout (default): Safari-style left navigation card framing traffic lights and page switching.',
      chinese: 'Native 布局（默认）：Safari 式左侧导航卡片，框住红绿灯与页面切换。',
    ),
    styleIdentity: 'dense-docked-studio',
    isDefault: true,
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
      profileId: LayoutProfileId.parse('studio'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('studio'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('studio'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsDestination,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('studio'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('studio'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);
