import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/contracts/presentation/presentation_plan_appearance.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// The appearance token roles this desktop build renders.
///
/// A resource may publish other roles; they stay unread here rather than
/// reaching a widget that does not render them. The set is the client's own
/// compiled surface, not something a package declares.
const Set<String> desktopAppearanceTokenRoles = {
  'bg-inset',
  'bg-base',
  'bg-surface',
  'bg-subtle',
  'bg-raised',
  'border-subtle',
  'border-strong',
  'text-primary',
  'text-secondary',
  'text-muted',
  'text-disabled',
  'brand',
  'brand-strong',
  'brand-subtle',
  'brand-border',
  'text-on-brand',
  'accent',
  'accent-strong',
  'accent-surface',
  'accent-border',
  'text-on-accent',
  'success',
  'warning',
  'danger',
  'hover-overlay',
  'pressed-overlay',
  'selected-surface',
  'brand-glow',
  'accent-glow',
  'skeleton-base',
  'skeleton-highlight',
  'font-family',
  'icon-style',
  'motion-scale',
  'surface-opacity',
  'component-finish',
  'composer-activity-effect',
};

/// The declarative primitives this desktop build compiled a renderer for.
///
/// It mirrors `presentation_flutter`, which owns the compiled widgets: a
/// contribution naming a primitive outside this set is refused with a stable
/// reason rather than drawn as a neighbouring primitive.
const Set<DeclarativePrimitive> desktopCompiledPrimitives = {
  DeclarativePrimitive.text,
  DeclarativePrimitive.progress,
  DeclarativePrimitive.table,
  DeclarativePrimitive.form,
  DeclarativePrimitive.command,
  DeclarativePrimitive.action,
};

/// The bounded pure-data format this build compiles a renderer for.
const String desktopGraphResourceViewFormat = 'licoup.ui.graph-resource.v1';

/// A published plan this client mounted, with what it renders.
final class MountedPresentationPlan {
  const MountedPresentationPlan({
    required this.revision,
    required this.appearance,
  });

  /// The committed revision, with every mounted and refused contribution.
  final HostMountRevision revision;

  /// The appearance that revision resolved.
  final PresentationPlanAppearance appearance;
}

/// Reads the native resource mount plan this client renders from.
///
/// The native resource lifecycle owns selection, generation switching and
/// fallback; it publishes the plan as data. This service only carries that
/// document to the host registry, so an absent or unreadable plan degrades to
/// the built-in appearance instead of failing client startup.
final class PresentationMountPlanService {
  const PresentationMountPlanService();

  /// The plan's location inside the client-managed data root.
  static const String planFileName = 'presentation/mount-plan.json';

  /// Mounts the published plan, or returns `null` while none is published.
  ///
  /// `null` is a real state, not an error: the client then renders its own
  /// built-in appearance with nothing contributed.
  Future<MountedPresentationPlan?> mountPublishedPlan(
    PortableDataRoot portableData, {
    Set<DeclarativePrimitive> compiledPrimitives = desktopCompiledPrimitives,
    Iterable<String> registeredActions = const <String>[],
    Map<String, String> appearanceDefaults = const <String, String>{},
  }) async {
    final plan = await readPublishedPlan(portableData);
    if (plan == null) return null;
    final registry = ExtensionHostRegistry(
      host: HostPrimitiveRegistry(
        primitives: compiledPrimitives,
        actions: registeredActions,
        appearanceDefaults: appearanceDefaults,
        appearanceTokenRoles: desktopAppearanceTokenRoles,
        resourceViewFormats: const {desktopGraphResourceViewFormat},
      ),
    );
    try {
      final revision = registry.mount(plan);
      return MountedPresentationPlan(
        revision: revision,
        appearance: projectedAppearance(revision.appearance),
      );
    } finally {
      registry.dispose();
    }
  }

  /// The published document, or `null` when this host has none to render.
  ///
  /// A document this build cannot own — an unknown generation, an unknown
  /// member, an unfinished binding — is refused whole and reported as absent: a
  /// partially understood plan never reaches rendering.
  Future<NativeMountPlan?> readPublishedPlan(
    PortableDataRoot portableData,
  ) async {
    final root = await portableData.clientDirectory();
    final file = File(p.join(root.path, planFileName));
    if (!await file.exists()) return null;
    final String source;
    try {
      source = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    try {
      return NativeMountPlan.fromDecoded(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on NativeMountPlanFormatException {
      return null;
    }
  }
}

/// Projects a registry appearance into the client's own contract value.
PresentationPlanAppearance projectedAppearance(
  ResolvedHostAppearance appearance,
) => PresentationPlanAppearance(
  source: appearance.isDefault
      ? PlanAppearanceSource.declaredDefault
      : PlanAppearanceSource.selectedResource,
  systemId: appearance.system.name,
  tokens: appearance.tokens,
  resourceId: appearance.resourceId,
  packageGeneration: appearance.packageGeneration,
  fallback: switch (appearance.fallback) {
    null => null,
    ResourceFallback(:final resourceId, :final packageId, :final reason) =>
      PresentationPlanFallback(
        resourceId: resourceId,
        packageId: packageId,
        reason: switch (reason) {
          ResourceFallbackReason.disabled =>
            PresentationPlanFallbackReason.disabled,
          ResourceFallbackReason.uninstalled =>
            PresentationPlanFallbackReason.uninstalled,
          ResourceFallbackReason.replaced =>
            PresentationPlanFallbackReason.replaced,
        },
      ),
  },
);
