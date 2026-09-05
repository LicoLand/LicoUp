import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/destinations/messaging_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';

/// The sole immutable entry point for the Messaging mobile renderer.
final LayoutSurfaceBundle messagingMobileBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.messaging,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildMessagingMobileCompactShell,
      destinationBuilders: _messagingMobileDestinationBuilders,
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildMessagingMobileMediumShell,
      destinationBuilders: _messagingMobileDestinationBuilders,
    ),
  },
  previewBuilder: buildMessagingMobilePreview,
  tokens: messagingMobileVisualTokens,
  components: messagingMobileComponents,
  assetNamespace: 'layout-profiles/messaging/mobile',
  restorationNamespace: messagingMobileRestorationPrefix,
  stateNamespaces: BuiltInLayoutSpec.messagingMobileStateNamespaces,
);

final Map<ClientSection, LayoutDestinationBuilder>
_messagingMobileDestinationBuilders = {
  ClientSection.agents: buildMessagingMobileAgentsDestination,
  ClientSection.mobileRelay: buildMessagingMobilePairingDestination,
  ClientSection.settings: buildMessagingMobileSettingsDestination,
};
