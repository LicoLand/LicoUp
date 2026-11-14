/// The host component registry: the one place a native mount plan becomes
/// rendered interface.
///
/// The registry owns two things a contribution can never supply itself:
///
/// * the [DeclarativePrimitive] set this shell build compiled, and
/// * the action names this shell build registered.
///
/// A plan is mounted as one committed revision. Every contribution is decided
/// against the registered set, and a contribution naming a primitive or action
/// this build does not provide is refused on its own with a stable reason; the
/// rest of the revision mounts. Nothing here accepts a widget, a builder, a
/// callback or a host object, so no arbitrary construction crosses the
/// boundary in either direction.
///
/// When a resource kind falls back, the registry projects the host's own
/// declared default for that kind instead of the withdrawn resource's values.
/// The fallback is deterministic: the same bindings and the same declared
/// default always produce the same projection, and the recorded reason is
/// carried, never inferred.
library;

import 'package:flutter/foundation.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'extension_ui_mount_plan.dart';

/// Why one contribution did not mount.
///
/// These are stable values, not messages: a host reports the code and the field
/// that decided it, and the interface shows its own bounded unavailable state.
/// A refusal is local to the contribution it names; it never blocks the
/// revision and never changes another contribution's resource.
enum ExtensionMountRefusal {
  /// The plan does not publish this contribution's primitive.
  primitiveUndeclared('primitive_undeclared'),

  /// The plan publishes the primitive, but this host build compiled no
  /// renderer for it.
  primitiveUnavailable('primitive_unavailable'),

  /// The contribution names an action the plan does not publish.
  actionUndeclared('action_undeclared'),

  /// The plan publishes the action, but this host build registered no handler
  /// for it.
  actionUnavailable('action_unavailable'),

  /// A resource view names a pure-data format this build compiles no renderer
  /// for.
  resourceFormatUnavailable('resource_format_unavailable'),

  /// The plan binds no resource of the kind the contribution reads.
  resourceUnbound('resource_unbound'),

  /// Two contributions in one revision share an identity.
  contributionDuplicate('contribution_duplicate');

  const ExtensionMountRefusal(this.code);

  /// The stable code a host reports and a test asserts on.
  final String code;

  @override
  String toString() => code;
}

/// The registry's decision about one contribution.
final class ExtensionMountDecision {
  const ExtensionMountDecision._({
    required this.contribution,
    required this.refusal,
    required this.field,
  });

  final NativeMountContribution contribution;

  /// `null` when the contribution mounts through its registered primitive.
  final ExtensionMountRefusal? refusal;

  /// The declaration member the refusal decided, when one is known.
  final String? field;

  bool get isMounted => refusal == null;

  @override
  String toString() => isMounted
      ? 'ExtensionMountDecision(${contribution.id}, mounted)'
      : 'ExtensionMountDecision(${contribution.id}, ${refusal!.code}, $field)';
}

/// Whether a resolved appearance came from a selected resource or the host's
/// own declared default.
enum ResolvedAppearanceSource { selectedResource, declaredDefault }

/// The appearance this host renders right now.
///
/// [tokens] are the plain strings the host's own theme applier reads; a
/// contributed theme supplies them, and the declared default supplies the
/// host's own when nothing is selected. [fallback] is set only when a selected
/// resource was withdrawn, so the interface can report the reason while
/// rendering the default.
final class ResolvedHostAppearance {
  ResolvedHostAppearance({
    required this.source,
    required this.system,
    Map<String, String> tokens = const <String, String>{},
    this.resourceId,
    this.packageGeneration,
    this.fallback,
  }) : tokens = Map<String, String>.unmodifiable(tokens);

  final ResolvedAppearanceSource source;

  /// The declared default this appearance belongs to.
  final MountedSystemDefault system;

  /// Token roles and values the host theme applier reads.
  final Map<String, String> tokens;

  /// The selected resource, when one is selected.
  final String? resourceId;

  /// The package generation that serves it, when one serves it.
  final int? packageGeneration;

  /// The recorded fallback, when the declared default is serving because the
  /// selected resource was disabled, uninstalled or replaced.
  final ResourceFallback? fallback;

  bool get isDefault => source == ResolvedAppearanceSource.declaredDefault;

  /// A stable reason for a surface that reports why the default is rendering.
  String? get fallbackReason => fallback?.reason.name;

  @override
  String toString() =>
      'ResolvedHostAppearance(${source.name}, ${system.name}, '
      '${tokens.length} tokens${fallback == null ? '' : ', ${fallback!.reason.name}'})';
}

/// One mounted revision of the native mount plan.
///
/// The value is immutable and answers every question a renderer asks: which
/// contributions mounted, why the others did not, which appearance to render,
/// and which regions the mounted contributions occupy. A renderer reads this
/// instead of the plan, so no renderer interprets a native document.
final class HostMountRevision {
  HostMountRevision({
    required this.planRevision,
    required Iterable<ExtensionMountDecision> decisions,
    required Iterable<MountedContribution> mounted,
    required this.appearance,
  }) : decisions = List<ExtensionMountDecision>.unmodifiable(decisions),
       mounted = List<MountedContribution>.unmodifiable(mounted);

  final int planRevision;

  /// Every decision of this revision, mounted and refused alike.
  final List<ExtensionMountDecision> decisions;

  /// The mounted contributions, in plan order.
  final List<MountedContribution> mounted;

  final ResolvedHostAppearance appearance;

  /// The refusals of this revision, each with its stable code.
  Iterable<ExtensionMountDecision> get refusals =>
      decisions.where((decision) => !decision.isMounted);

  /// The mounted contributions occupying one region, in plan order.
  List<MountedContribution> region(String regionId) =>
      List<MountedContribution>.unmodifiable(
        mounted.where((entry) => entry.regions.contains(regionId)),
      );

  @override
  String toString() =>
      'HostMountRevision($planRevision, ${mounted.length} mounted, '
      '${decisions.length - mounted.length} refused)';
}

/// The host's compiled primitive set, action set and appearance defaults.
///
/// The shell builds one of these from what it actually compiled and registered.
/// It is the authority the registry decides against: a plan cannot add a
/// primitive, and a contribution cannot register an action.
final class HostPrimitiveRegistry {
  HostPrimitiveRegistry({
    required Iterable<DeclarativePrimitive> primitives,
    Iterable<String> actions = const <String>[],
    Map<String, String> appearanceDefaults = const <String, String>{},
    Iterable<String> appearanceTokenRoles = const <String>[],
    Iterable<String> resourceViewFormats = const <String>[],
  }) : primitives = Set<DeclarativePrimitive>.unmodifiable(
         Set<DeclarativePrimitive>.of(primitives),
       ),
       actions = Set<String>.unmodifiable(Set<String>.of(actions)),
       appearanceDefaults = Map<String, String>.unmodifiable(
         Map<String, String>.of(appearanceDefaults),
       ),
       appearanceTokenRoles = Set<String>.unmodifiable(
         Set<String>.of(appearanceTokenRoles),
       ),
       resourceViewFormats = Set<String>.unmodifiable(
         Set<String>.of(resourceViewFormats),
       );

  /// The primitives this shell build compiled a renderer for.
  final Set<DeclarativePrimitive> primitives;

  /// The action names this shell build registered a handler for.
  final Set<String> actions;

  /// The host's own appearance tokens, rendered when a theme kind falls back.
  ///
  /// These are the client's system appearance, not a bundled fallback package:
  /// withdrawing an appearance package returns the user to the platform's own
  /// rendering.
  final Map<String, String> appearanceDefaults;

  /// Token roles a contributed theme may set.
  ///
  /// A theme that sets a role outside this set is ignored for that role rather
  /// than failing the whole contribution, because a newer package may publish
  /// roles this build does not render yet. A role this build does render can
  /// never be set to a value from outside the document's plain strings.
  final Set<String> appearanceTokenRoles;

  /// Resource-view data formats this shell build compiled a renderer for.
  final Set<String> resourceViewFormats;

  /// Whether this build provides one primitve.
  bool providesPrimitive(DeclarativePrimitive primitive) =>
      primitives.contains(primitive);

  /// Whether this build registered one action.
  bool registersAction(String actionRef) => actions.contains(actionRef);

  @override
  String toString() =>
      'HostPrimitiveRegistry(${primitives.length} primitives, '
      '${actions.length} actions)';
}

/// Mounts native resource mount plans and projects them for rendering.
///
/// The registry is a [ChangeNotifier]: mounting or withdrawing a revision
/// notifies once. It holds no subscription, no timer and no per-theme
/// controller, and it never reads a resource: the native lifecycle owns
/// selection, generation switching and fallback, and hands the result here as
/// data.
final class ExtensionHostRegistry extends ChangeNotifier {
  ExtensionHostRegistry({required this.host});

  final HostPrimitiveRegistry host;

  NativeMountPlan? _plan;
  HostMountRevision? _revision;

  /// The plan revision currently mounted, or `null` before the first mount.
  NativeMountPlan? get plan => _plan;

  /// The mounted revision, or `null` before the first mount.
  HostMountRevision? get revision => _revision;

  /// Whether a revision is currently mounted.
  bool get isMounted => _revision != null;

  /// Mounts one published plan, replacing the previous revision as a whole.
  ///
  /// Re-delivering the revision that is already mounted is a no-op: a revision
  /// is published once, so re-reading it must not tear the interface down. A
  /// malformed document throws [NativeMountPlanFormatException] before anything
  /// changes, so a rejected plan never half-applies.
  HostMountRevision mount(NativeMountPlan plan) {
    if (_revision != null && plan.revision == _revision!.planRevision) {
      return _revision!;
    }
    final revision = _project(plan);
    _plan = plan;
    _revision = revision;
    notifyListeners();
    return revision;
  }

  /// Withdraws the mounted revision: the host renders its own appearance and
  /// nothing is contributed.
  void withdraw() {
    if (_revision == null) return;
    _plan = null;
    _revision = null;
    notifyListeners();
  }

  HostMountRevision _project(NativeMountPlan plan) {
    final decisions = <ExtensionMountDecision>[];
    final mounted = <MountedContribution>[];
    final seen = <String>{};

    for (final contribution in plan.contributions) {
      final refusal = _refuse(plan, contribution, seen);
      if (refusal != null) {
        decisions.add(refusal);
        continue;
      }
      seen.add(contribution.id);
      decisions.add(
        ExtensionMountDecision._(
          contribution: contribution,
          refusal: null,
          field: null,
        ),
      );
      mounted.add(
        MountedContribution(
          id: contribution.id,
          primitive: contribution.primitive,
          resourceId: contribution.resourceId,
          resourceFormat: contribution.resourceFormat,
          actionRef: contribution.actionRef,
          regions: contribution.regions,
          inputs: contribution.inputs,
        ),
      );
    }

    return HostMountRevision(
      planRevision: plan.revision,
      decisions: decisions,
      mounted: mounted,
      appearance: _appearance(plan),
    );
  }

  ExtensionMountDecision? _refuse(
    NativeMountPlan plan,
    NativeMountContribution contribution,
    Set<String> seen,
  ) {
    ExtensionMountDecision refuse(
      ExtensionMountRefusal refusal,
      String field,
    ) => ExtensionMountDecision._(
      contribution: contribution,
      refusal: refusal,
      field: field,
    );

    if (seen.contains(contribution.id)) {
      return refuse(ExtensionMountRefusal.contributionDuplicate, 'id');
    }
    // The plan is the package's own declaration: a primitive or action it does
    // not publish is refused before host registration is consulted, so the two
    // refusal reasons stay distinguishable.
    if (!plan.hostPrimitives.contains(contribution.primitive)) {
      return refuse(ExtensionMountRefusal.primitiveUndeclared, 'primitive');
    }
    final actionRef = contribution.actionRef;
    if (actionRef != null) {
      if (!plan.hostActions.contains(actionRef)) {
        return refuse(ExtensionMountRefusal.actionUndeclared, 'actionRef');
      }
      if (!host.registersAction(actionRef)) {
        return refuse(ExtensionMountRefusal.actionUnavailable, 'actionRef');
      }
    }
    // A resource view is refused for its format before its primitive: the
    // format decides whether this build has a renderer for the data at all,
    // while the primitive only names how it would be framed.
    final format = contribution.resourceFormat;
    if (format != null && !host.resourceViewFormats.contains(format)) {
      return refuse(
        ExtensionMountRefusal.resourceFormatUnavailable,
        'resourceFormat',
      );
    }
    if (!host.providesPrimitive(contribution.primitive)) {
      return refuse(ExtensionMountRefusal.primitiveUnavailable, 'primitive');
    }
    return null;
  }

  ResolvedHostAppearance _appearance(NativeMountPlan plan) {
    final binding = plan.bindingFor(MountedResourceKind.theme);
    final fallback = plan.fallbackFor(MountedResourceKind.theme);
    if (binding case SelectedResourceBinding(
      :final resourceId,
      :final packageGeneration,
    )) {
      // A selected resource's tokens are read over the host's own appearance:
      // a theme that publishes a subset of the roles changes those roles and
      // leaves the rest of the platform rendering in place. The document reader
      // already refused a binding that both serves a resource and fell back.
      return ResolvedHostAppearance(
        source: ResolvedAppearanceSource.selectedResource,
        system: mountedSystemDefaults[MountedResourceKind.theme]!,
        resourceId: resourceId,
        packageGeneration: packageGeneration,
        tokens: <String, String>{
          ...host.appearanceDefaults,
          for (final entry in plan.themeTokens.entries)
            if (host.appearanceTokenRoles.contains(entry.key))
              entry.key: entry.value,
        },
      );
    }
    // The declared default: the withdrawn resource's values are gone, and the
    // recorded reason is carried rather than inferred.
    return ResolvedHostAppearance(
      source: ResolvedAppearanceSource.declaredDefault,
      system: mountedSystemDefaults[MountedResourceKind.theme]!,
      tokens: host.appearanceDefaults,
      fallback: fallback,
    );
  }
}
