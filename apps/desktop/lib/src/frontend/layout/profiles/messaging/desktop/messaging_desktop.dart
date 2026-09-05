import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/components/messaging_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/destinations/messaging_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/preview/messaging_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// The sole public handoff from the Default desktop renderer boundary.
final LayoutSurfaceBundle messagingDesktopBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.messaging,
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildMessagingDesktopMediumShell,
      destinationBuilders: messagingDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildMessagingDesktopExpandedShell,
      destinationBuilders: messagingDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildMessagingDesktopPreview,
  tokens: messagingDesktopTokens,
  components: messagingDesktopComponentKit,
  assetNamespace: 'layout-profiles/messaging/desktop',
  restorationNamespace: 'messaging.desktop',
  stateNamespaces: BuiltInLayoutSpec.messagingDesktopStateNamespaces,
);
