import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/components/desktop_desktop_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/destinations/desktop_desktop_destination_builders.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/preview/desktop_desktop_preview.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_desktop_shell.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';

/// The sole public handoff from the Desktop desktop renderer boundary.
final LayoutSurfaceBundle desktopDesktopBundle = LayoutSurfaceBundle(
  profile: BuiltInLayoutSpec.desktop,
  surface: LayoutRuntimeSurface.desktop,
  variants: <LayoutViewportClass, LayoutSurfaceVariant>{
    LayoutViewportClass.medium: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.medium,
      shellBuilder: buildDesktopDesktopMediumShell,
      destinationBuilders: desktopDesktopDestinationBuilders,
    ),
    LayoutViewportClass.expanded: LayoutSurfaceVariant(
      viewport: LayoutViewportClass.expanded,
      shellBuilder: buildDesktopDesktopExpandedShell,
      destinationBuilders: desktopDesktopDestinationBuilders,
    ),
  },
  previewBuilder: buildDesktopDesktopPreview,
  tokens: desktopDesktopTokens,
  components: desktopDesktopComponentKit,
  assetNamespace: 'layout-profiles/desktop/desktop',
  restorationNamespace: 'desktop.desktop',
  stateNamespaces: BuiltInLayoutSpec.desktopDesktopStateNamespaces,
);
