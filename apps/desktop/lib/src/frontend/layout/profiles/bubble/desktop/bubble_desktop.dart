import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/components/bubble_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/destinations/bubble_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/preview/bubble_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/shell/bubble_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/tokens/bubble_desktop_tokens.dart';

/// The sole public handoff from the Bubble desktop renderer boundary.
final LayoutSurfaceBundle bubbleDesktopBundle = LayoutSurfaceBundle(
  profile: LayoutProfileDescriptor(
    id: LayoutProfileId.parse('bubble'),
    label: LayoutProfileCopy(english: 'Bubble', chinese: 'Bubble'),
    description: LayoutProfileCopy(
      english:
          'Bubble layout: floating capsule rail navigation with inverted Agents chrome.',
      chinese: 'Bubble 布局：左侧浮动胶囊轨道导航与智能体反转卡片。',
    ),
    styleIdentity: 'dense-docked-bubble',
    isDefault: false,
    revision: 1,
  ),
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildBubbleDesktopMediumShell,
      destinationBuilders: bubbleDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildBubbleDesktopExpandedShell,
      destinationBuilders: bubbleDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildBubbleDesktopPreview,
  tokens: bubbleDesktopTokens,
  components: bubbleDesktopComponentKit,
  assetNamespace: 'layout-profiles/bubble/desktop',
  restorationNamespace: 'bubble.desktop',
  stateNamespaces: <LayoutStateNamespace>{
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('bubble'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsHistory,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('bubble'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      channel: LayoutStateChannels.agentsSidebar,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('bubble'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsScroll,
    ),
    LayoutStateNamespace(
      profileId: LayoutProfileId.parse('bubble'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.settings,
      channel: LayoutStateChannels.settingsSection,
    ),
  },
);
