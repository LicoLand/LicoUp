import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_agents_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_pairing_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/destinations/desktop_settings_destination.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_components.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/mobile/desktop_mobile_tokens.dart';

final LayoutSurfaceBundle desktopMobileBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.desktop,
  surface: LayoutRuntimeSurface.mobile,
  variants: {
    LayoutViewportClass.compact: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.compact,
      shellBuilder: buildDesktopMobileCompactShell,
      destinationBuilders: _desktopMobileDestinationBuilders(),
    ),
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDesktopMobileMediumShell,
      destinationBuilders: _desktopMobileDestinationBuilders(),
    ),
  },
  previewBuilder: buildDesktopMobilePreview,
  tokens: desktopMobileTokens,
  components: const DesktopMobileComponentKit(),
  assetNamespace: 'layout-profiles/desktop/mobile',
  restorationNamespace: desktopMobileRestorationPrefix,
  stateNamespaces: BuiltInLayoutSpec.desktopMobileStateNamespaces,
);

Map<ClientSection, LayoutDestinationBuilder>
_desktopMobileDestinationBuilders() => {
  ClientSection.agents: buildDesktopAgentsDestination,
  ClientSection.mobileRelay: buildDesktopPairingDestination,
  ClientSection.settings: buildDesktopSettingsDestination,
};
