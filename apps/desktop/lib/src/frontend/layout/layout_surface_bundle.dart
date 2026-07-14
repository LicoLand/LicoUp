import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

abstract interface class LayoutDestinationContentPort {
  Widget buildDestination(BuildContext context, ClientSection destination);
}

typedef LayoutDestinationBuilder =
    Widget Function(BuildContext context, LayoutDestinationBuildContext data);
typedef LayoutShellBuilder =
    Widget Function(BuildContext context, LayoutShellBuildContext data);
typedef LayoutPreviewBuilder = Widget Function(BuildContext context);

final class LayoutDestinationBuildContext {
  const LayoutDestinationBuildContext({
    required this.environment,
    required this.destination,
    required this.content,
    required this.state,
  });

  final LayoutEnvironment environment;
  final ClientSection destination;
  final LayoutDestinationContentPort content;
  final LayoutScopedState state;
}

final class LayoutShellBuildContext {
  LayoutShellBuildContext({
    required this.environment,
    required this.activeDestination,
    required Iterable<ClientSection> availableDestinations,
    required this.destination,
    required this.onSelectDestination,
    required this.components,
    required this.tokens,
    required this.initialFocusTarget,
  }) : availableDestinations = UnmodifiableListView(
         List<ClientSection>.of(availableDestinations),
       );

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final List<ClientSection> availableDestinations;
  final Widget destination;
  final ValueChanged<ClientSection> onSelectDestination;
  final LayoutComponentKit components;
  final LayoutVisualTokens tokens;
  final String initialFocusTarget;
}

final class LayoutSurfaceVariant {
  factory LayoutSurfaceVariant({
    required LayoutViewportClass viewport,
    required LayoutShellBuilder shellBuilder,
    required Map<ClientSection, LayoutDestinationBuilder> destinationBuilders,
  }) {
    if (destinationBuilders.isEmpty) {
      throw const FormatException('layout_surface_destinations_missing');
    }
    return LayoutSurfaceVariant._(
      viewport: viewport,
      shellBuilder: shellBuilder,
      destinationBuilders: UnmodifiableMapView(
        Map<ClientSection, LayoutDestinationBuilder>.of(destinationBuilders),
      ),
    );
  }

  const LayoutSurfaceVariant._({
    required this.viewport,
    required this.shellBuilder,
    required this.destinationBuilders,
  });

  final LayoutViewportClass viewport;
  final LayoutShellBuilder shellBuilder;
  final Map<ClientSection, LayoutDestinationBuilder> destinationBuilders;
}

/// The only public artifact exported by a profile/surface renderer directory.
final class LayoutSurfaceBundle {
  factory LayoutSurfaceBundle({
    required LayoutProfileDescriptor profile,
    required LayoutRuntimeSurface surface,
    required Map<LayoutViewportClass, LayoutSurfaceVariant> variants,
    required LayoutPreviewBuilder previewBuilder,
    required LayoutVisualTokens tokens,
    required LayoutComponentKit components,
    required String assetNamespace,
    required String restorationNamespace,
    required Set<LayoutStateNamespace> stateNamespaces,
  }) {
    final requiredViewports = LayoutViewportPolicy.supportedFor(surface);
    if (!_sameSet(variants.keys.toSet(), requiredViewports)) {
      throw const FormatException('layout_surface_viewport_product_invalid');
    }
    for (final entry in variants.entries) {
      if (entry.key != entry.value.viewport) {
        throw const FormatException('layout_surface_viewport_key_mismatch');
      }
    }
    if (components.styleIdentity != profile.styleIdentity) {
      throw const FormatException('layout_surface_style_identity_mismatch');
    }
    if (!_assetNamespace.hasMatch(assetNamespace) ||
        assetNamespace !=
            'layout-profiles/${profile.id.value}/${surface.name}') {
      throw const FormatException('layout_surface_asset_namespace_invalid');
    }
    if (!_restorationNamespace.hasMatch(restorationNamespace) ||
        restorationNamespace != '${profile.id.value}.${surface.name}') {
      throw const FormatException(
        'layout_surface_restoration_namespace_invalid',
      );
    }
    if (stateNamespaces.isEmpty) {
      throw const FormatException('layout_surface_state_namespace_missing');
    }
    for (final namespace in stateNamespaces) {
      if (namespace.profileId != profile.id || namespace.surface != surface) {
        throw const FormatException('layout_surface_state_namespace_invalid');
      }
    }
    return LayoutSurfaceBundle._(
      profile: profile,
      surface: surface,
      variants: UnmodifiableMapView(
        Map<LayoutViewportClass, LayoutSurfaceVariant>.of(variants),
      ),
      previewBuilder: previewBuilder,
      tokens: tokens,
      components: components,
      assetNamespace: assetNamespace,
      restorationNamespace: restorationNamespace,
      stateNamespaces: UnmodifiableSetView(Set.of(stateNamespaces)),
    );
  }

  const LayoutSurfaceBundle._({
    required this.profile,
    required this.surface,
    required this.variants,
    required this.previewBuilder,
    required this.tokens,
    required this.components,
    required this.assetNamespace,
    required this.restorationNamespace,
    required this.stateNamespaces,
  });

  static final RegExp _assetNamespace = RegExp(
    r'^layout-profiles/[a-z]+(?:-[a-z]+)*/(?:desktop|mobile)$',
  );
  static final RegExp _restorationNamespace = RegExp(
    r'^[a-z]+(?:-[a-z]+)*\.(?:desktop|mobile)$',
  );

  final LayoutProfileDescriptor profile;
  final LayoutRuntimeSurface surface;
  final Map<LayoutViewportClass, LayoutSurfaceVariant> variants;
  final LayoutPreviewBuilder previewBuilder;
  final LayoutVisualTokens tokens;
  final LayoutComponentKit components;
  final String assetNamespace;
  final String restorationNamespace;
  final Set<LayoutStateNamespace> stateNamespaces;

  Iterable<LayoutVariantCoverage> get coverage => variants.entries.map(
    (entry) => LayoutVariantCoverage(
      key: LayoutVariantKey(
        profileId: profile.id,
        surface: surface,
        viewport: entry.key,
      ),
      destinations: entry.value.destinationBuilders.keys.toSet(),
    ),
  );

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);
}
