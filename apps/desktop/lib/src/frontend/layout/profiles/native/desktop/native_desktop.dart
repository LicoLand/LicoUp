import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/components/native_desktop_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/native_desktop_destination_builders.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/preview/native_desktop_preview.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_desktop_shell.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/tokens/native_desktop_tokens.dart';

/// The sole public handoff from the Native desktop renderer boundary.
final LayoutSurfaceBundle nativeDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('native'),
    label: LayoutProfileCopy(english: 'Native', chinese: 'Native'),
    description: LayoutProfileCopy(
      english:
          'Native layout (default): an icon rail and top band on the window background, a flush conversation list one step above, and the destination detail as the lightest top layer.',
      chinese: 'Native 布局（默认）：图标导航轨与顶栏落在窗口背景上，对话列表平铺为第二层，内容详情是最浅的第三层。',
    ),
    styleIdentity: 'glassy-rail-native',
    isDefault: true,
    revision: 3,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildNativeDesktopMediumShell,
      destinationBuilders: nativeDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildNativeDesktopExpandedShell,
      destinationBuilders: nativeDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildNativeDesktopPreview,
  tokens: nativeDesktopTokens,
  components: nativeDesktopComponentKit,
  assetNamespace: 'layout-profiles/native/desktop',
  restorationNamespace: 'native.desktop',
  stateNamespaces: <LayoutStateNamespace>{
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('native'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('native'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('native'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('native'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);
