/// The appearance one published native mount plan projects.
///
/// This is the only shape a rendered appearance travels in across the client:
/// plain token values and identities, never a widget, a callback or a core
/// client object. The native resource lifecycle owns selection, generation
/// switching and fallback; this value reports what that owner published, so a
/// renderer applies it instead of deciding for itself.
library;

/// Why a kind stopped serving the resource a reader had selected.
enum PresentationPlanFallbackReason { disabled, uninstalled, replaced }

/// One recorded fallback, as the interface reports it.
final class PresentationPlanFallback {
  const PresentationPlanFallback({
    required this.resourceId,
    required this.packageId,
    required this.reason,
  });

  /// The resource that had been selected. The preference survives; what is
  /// served does not.
  final String resourceId;

  final String packageId;

  final PresentationPlanFallbackReason reason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationPlanFallback &&
          other.resourceId == resourceId &&
          other.packageId == packageId &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(resourceId, packageId, reason);

  @override
  String toString() =>
      'PresentationPlanFallback($resourceId, ${reason.name})';
}

/// The appearance the host renders right now, projected from the plan.
///
/// A `null` appearance on the owner means no plan is published yet and the
/// client renders its built-in appearance. A projected appearance is either a
/// selected theme resource's tokens or the declared default with its recorded
/// fallback, and both are complete: the renderer never merges the two.
final class PresentationPlanAppearance {
  PresentationPlanAppearance({
    required this.source,
    required this.systemId,
    Map<String, String> tokens = const <String, String>{},
    this.resourceId,
    this.packageGeneration,
    this.fallback,
  }) : tokens = Map<String, String>.unmodifiable(Map<String, String>.of(tokens));

  /// Whether a selected resource or the declared default is serving.
  final PlanAppearanceSource source;

  /// The declared default this appearance belongs to, as published.
  final String systemId;

  /// Token roles and values the theme applier reads.
  final Map<String, String> tokens;

  /// The selected resource, when one is selected.
  final String? resourceId;

  /// The package generation that serves it, when one serves it.
  final int? packageGeneration;

  /// The recorded fallback, when the declared default is serving because the
  /// selected resource was disabled, uninstalled or replaced.
  final PresentationPlanFallback? fallback;

  bool get isDefault => source == PlanAppearanceSource.declaredDefault;

  /// A stable reason for a surface that reports why the default is rendering.
  String? get fallbackReason => fallback?.reason.name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationPlanAppearance &&
          other.source == source &&
          other.systemId == systemId &&
          other.resourceId == resourceId &&
          other.packageGeneration == packageGeneration &&
          other.fallback == fallback &&
          _sameTokens(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(
    source,
    systemId,
    resourceId,
    packageGeneration,
    fallback,
    Object.hashAll(
      tokens.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  @override
  String toString() =>
      'PresentationPlanAppearance(${source.name}, ${tokens.length} tokens'
      '${fallback == null ? '' : ', ${fallback!.reason.name}'})';
}

/// Whether a projected appearance came from a selected resource or the
/// declared default.
enum PlanAppearanceSource { selectedResource, declaredDefault }

bool _sameTokens(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
