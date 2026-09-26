/// The runtime mount of declarative interface contributions.
///
/// One committed registry epoch is the mount unit: [ExtensionUiMountRegistry.mount]
/// withdraws the previous epoch as a whole and mounts the new one as a whole, so
/// no reader ever sees half of an update. Every mounted contribution owns one
/// [ExtensionUiContributionSession] that observes its resource through the
/// presentation runtime, prepares through the same admission as every other
/// prepared value, and releases its subscription and prepared values when the
/// epoch is withdrawn.
///
/// A contribution that cannot mount — invalid declaration, unserved profile,
/// unpublished profile, missing primitive — blocks only itself; the decision
/// keeps the reason.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import '../graph/graph_resource_view.dart';
import 'extension_ui_binding.dart';
import 'extension_ui_contribution.dart';

/// One contribution as the catalog binds it: the declaration plus the instance
/// and generation that declared it.
///
/// The three facts stay separate: a package version can produce several
/// instances, one instance runs one generation, and the document's registry
/// epoch is the committed catalog these were read from. This is binding data
/// for interface lifetime only; instance lifecycle, admission and routing stay
/// with their native owner.
final class ExtensionUiCatalogContribution {
  const ExtensionUiCatalogContribution({
    required this.contribution,
    required this.instanceId,
    required this.generation,
    this.packageId,
  });

  final ExtensionUiContribution contribution;
  final String instanceId;
  final int generation;
  final String? packageId;

  static ExtensionUiCatalogContribution fromJson(Map<String, Object?> json) {
    final contribution = ExtensionUiContribution.fromJson(
      Map<String, Object?>.of(json)
        ..remove('instanceId')
        ..remove('generation')
        ..remove('packageId'),
    );
    final instanceId = json['instanceId'];
    if (instanceId is! String || instanceId.isEmpty) {
      throw FormatException('instanceId must be a non-empty string', json, 0);
    }
    final generation = json['generation'];
    if (generation is! int || generation < 1) {
      throw FormatException('generation must be a positive integer', json, 0);
    }
    final packageId = json['packageId'];
    if (packageId != null && (packageId is! String || packageId.isEmpty)) {
      throw FormatException('packageId must be a non-empty string', json, 0);
    }
    return ExtensionUiCatalogContribution(
      contribution: contribution,
      instanceId: instanceId,
      generation: generation,
      packageId: packageId as String?,
    );
  }

  @override
  String toString() =>
      'ExtensionUiCatalogContribution(${contribution.id}@$instanceId/$generation)';
}

/// One committed registry epoch, as the interface host reads it.
///
/// The document carries only what the interface needs: the epoch number, the
/// profiles this host serves at that epoch, and the contributions with their
/// instance binding. It is not a copy of the native instance ledger.
final class ExtensionUiRegistrySnapshot {
  ExtensionUiRegistrySnapshot({
    required this.registryEpoch,
    required Set<String> servedProfiles,
    required List<ExtensionUiCatalogContribution> contributions,
  }) : servedProfiles = Set<String>.unmodifiable(servedProfiles),
       contributions = List<ExtensionUiCatalogContribution>.unmodifiable(
         contributions,
       );

  /// The epoch before anything has been committed. No contribution can carry it.
  static final ExtensionUiRegistrySnapshot empty = ExtensionUiRegistrySnapshot(
    registryEpoch: 0,
    servedProfiles: const <String>{},
    contributions: const <ExtensionUiCatalogContribution>[],
  );

  final int registryEpoch;

  /// Profile ids this host serves at this epoch. A contribution whose
  /// `requiredProfile` is published but not served here stays out of the mount.
  final Set<String> servedProfiles;

  final List<ExtensionUiCatalogContribution> contributions;

  /// Decodes one committed epoch document.
  ///
  /// Unknown document keys are refused, so a producer cannot smuggle a second
  /// meaning past the interface contract.
  static ExtensionUiRegistrySnapshot fromJson(Map<String, Object?> json) {
    for (final key in json.keys) {
      if (!const {
        'registryEpoch',
        'servedProfiles',
        'contributions',
      }.contains(key)) {
        throw FormatException('unknown epoch document field: $key', json, 0);
      }
    }
    final epoch = json['registryEpoch'];
    if (epoch is! int || epoch < 1) {
      throw FormatException(
        'registryEpoch must be a positive integer',
        json,
        0,
      );
    }
    final profilesJson = json['servedProfiles'];
    final profiles = <String>{};
    if (profilesJson != null) {
      if (profilesJson is! List) {
        throw FormatException('servedProfiles must be a list', json, 0);
      }
      for (final profile in profilesJson) {
        if (profile is! String || profile.isEmpty) {
          throw FormatException(
            'servedProfiles entries must be non-empty strings',
            json,
            0,
          );
        }
        profiles.add(profile);
      }
    }
    final contributionsJson = json['contributions'];
    if (contributionsJson == null || contributionsJson is! List) {
      throw FormatException('contributions must be a list', json, 0);
    }
    final contributions = <ExtensionUiCatalogContribution>[];
    for (final entry in contributionsJson) {
      if (entry is! Map) {
        throw FormatException('contribution entries must be objects', json, 0);
      }
      contributions.add(
        ExtensionUiCatalogContribution.fromJson(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      );
    }
    return ExtensionUiRegistrySnapshot(
      registryEpoch: epoch,
      servedProfiles: profiles,
      contributions: contributions,
    );
  }

  @override
  String toString() =>
      'ExtensionUiRegistrySnapshot(epoch $registryEpoch, '
      '${contributions.length} contributions)';
}

/// Stable interface lifetime identity of one mounted contribution.
///
/// A contribution is the same mounted thing only within one epoch, instance and
/// generation; a newer generation is a different interface, so a result or a
/// widget keyed by the old identity cannot carry over.
final class ExtensionUiMountIdentity {
  const ExtensionUiMountIdentity({
    required this.registryEpoch,
    required this.instanceId,
    required this.generation,
    required this.contributionId,
  });

  final int registryEpoch;
  final String instanceId;
  final int generation;
  final String contributionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExtensionUiMountIdentity &&
          other.registryEpoch == registryEpoch &&
          other.instanceId == instanceId &&
          other.generation == generation &&
          other.contributionId == contributionId;

  @override
  int get hashCode =>
      Object.hash(registryEpoch, instanceId, generation, contributionId);

  @override
  String toString() => '$contributionId@$instanceId/$generation#$registryEpoch';
}

/// One mounted contribution and everything that must be released with it.
///
/// The session observes the bound resource, prepares display values through the
/// runtime's admission, and exposes only a prepared value and typed actions.
/// Withdrawal revokes the session first, so a preparation that is still running
/// cannot install afterwards and is counted in [refusedLatePreparations].
final class ExtensionUiContributionSession {
  ExtensionUiContributionSession._({
    required this.identity,
    required this.contribution,
    required PresentationRuntime runtime,
    required ExtensionUiResourceBinding? binding,
    required ExtensionUiGraphResourceBinding? graphBinding,
    required ExtensionUiActionPort? action,
    required ExtensionUiCredentialPort? credentialPort,
  }) : _runtime = runtime,
       _binding = binding,
       _graphBinding = graphBinding,
       _action = action,
       _credentialPort = credentialPort {
    if (binding == null &&
        graphBinding == null &&
        contribution.resourceRef != null) {
      _localUnavailable = 'binding_unavailable';
    }
  }

  final ExtensionUiMountIdentity identity;
  final ExtensionUiContribution contribution;

  final PresentationRuntime _runtime;
  final ExtensionUiResourceBinding? _binding;
  final ExtensionUiGraphResourceBinding? _graphBinding;
  final ExtensionUiActionPort? _action;
  final ExtensionUiCredentialPort? _credentialPort;
  final ValueNotifier<ExtensionUiResourceValue?> _displayed =
      ValueNotifier<ExtensionUiResourceValue?>(null);

  ResourceObservationSubscription<ExtensionUiResourceValue>? _observation;
  PreparedDisplay<ExtensionUiResourceValue>? _display;
  GraphPreparationController? _graph;
  String? _localUnavailable;
  int _refusedLatePreparations = 0;
  bool _active = true;

  /// Action keys whose native receipt has not arrived yet.
  final ValueNotifier<Set<String>> pendingGraphActions =
      ValueNotifier<Set<String>>(const <String>{});

  /// The prepared value a primitive displays, or null while loading, revoked or
  /// unavailable.
  ValueListenable<ExtensionUiResourceValue?> get displayed => _displayed;

  /// The resource this contribution binds to, when the composition resolved it.
  ResourceKey? get resource => _binding?.source.fieldGroup.resource;

  /// True while this contribution may still install prepared values.
  bool get isActive => _active;

  /// A host-local reason this contribution cannot show data, or null.
  ///
  /// `binding_unavailable`: the composition did not bind `resourceRef`.
  /// `source_unavailable`: the source failed or its authority was withdrawn;
  /// whatever was displayed is already gone.
  /// `preparation_unavailable`: the runtime refused or failed the preparation
  /// step; a later source revision can retry.
  String? get localUnavailableReason => _localUnavailable;

  /// True when the host owns an action for this contribution's `actionRef`.
  bool get hasAction => _action != null;

  /// True when the composition injected a host credential port.
  ///
  /// Without one, this contribution's secret fields are locally unavailable and
  /// no action is dispatched with a placeholder handle; contributions that use
  /// no secret are unaffected.
  bool get canStoreCredentials => _credentialPort != null;

  /// The scope this contribution's actions and credentials are pinned to.
  ///
  /// The host built it from the mounted identity, so a port verifies a scope it
  /// already knows instead of a name the contribution supplied.
  ActionOrigin get pinnedOrigin => ActionOrigin(
    scope: ResourceScope('extension:${contribution.id}'),
    resource: resource,
  );

  /// Prepared results that arrived after this contribution stopped being able
  /// to install them.
  int get refusedLatePreparations => _refusedLatePreparations;

  /// Whether the session currently holds an open source subscription.
  bool get isObserving => _observation != null || _graph != null;

  /// The prepared graph of this contribution, when it is a graph resource view.
  GraphPreparationController? get graph => _graph;

  void _start() {
    final graphBinding = _graphBinding;
    if (graphBinding != null) {
      // A graph resource view mounts through the runtime's own preparation
      // pipeline: the controller observes the host source and installs prepared
      // values, so the renderer never reads a source directly.
      final controller = GraphPreparationController(
        runtime: _runtime,
        source: graphBinding.source,
      );
      _graph = controller;
      controller.start();
      return;
    }
    final binding = _binding;
    if (binding == null) return;
    try {
      final observation = _runtime.observe(binding.source);
      _observation = observation;
      observation.stream.listen(
        _onSnapshot,
        onError: (Object error, StackTrace stack) => _onSourceError(),
      );
    } on Object {
      _localUnavailable = 'binding_unavailable';
    }
  }

  void _onSnapshot(ResourceSnapshot<ExtensionUiResourceValue> snapshot) {
    if (!_active) return;
    final binding = _binding;
    if (binding == null) return;
    unawaited(_prepareAndOffer(_ensureDisplay(), binding, snapshot));
  }

  PreparedDisplay<ExtensionUiResourceValue> _ensureDisplay() {
    final existing = _display;
    if (existing != null) return existing;
    final display = PreparedDisplay<ExtensionUiResourceValue>(
      preparation: _runtime.preparation,
    );
    display.onInstalled(_onInstalled);
    display.onWithdrawn(_onWithdrawn);
    _display = display;
    return display;
  }

  Future<void> _prepareAndOffer(
    PreparedDisplay<ExtensionUiResourceValue> display,
    ExtensionUiResourceBinding binding,
    ResourceSnapshot<ExtensionUiResourceValue> snapshot,
  ) async {
    // The request generation is the source position's own version: one source
    // revision is one display request, so a session that mounts after a
    // withdrawal shares the identity of the request it is replacing and can
    // supersede it instead of being refused by the previous session's counter.
    final generation = RequestGeneration(snapshot.position.version.value);
    try {
      final outcome = await display.prepareAndOffer(
        snapshot: snapshot,
        generation: generation,
        operation: () =>
            binding.prepare?.call(snapshot.value) ?? snapshot.value,
      );
      if (outcome == GroupInstallOutcome.rejected) {
        // An older position, a replaced source incarnation, or a withdrawn
        // contribution: the value stays a pure result and installs nowhere.
        _refusedLatePreparations += 1;
      }
    } on Object {
      if (!_active) return;
      _displayed.value = null;
      _localUnavailable = 'preparation_unavailable';
    }
  }

  void _onInstalled(
    Map<
      ResourceFieldGroup<ExtensionUiResourceValue>,
      PreparedResource<ExtensionUiResourceValue>
    >
    installed,
  ) {
    if (!_active) return;
    final field = _binding?.source.fieldGroup;
    if (field == null) return;
    final value = installed[field]?.value;
    if (value == null) return;
    _localUnavailable = null;
    _displayed.value = value;
  }

  void _onWithdrawn(
    Set<ResourceFieldGroup<ExtensionUiResourceValue>> withdrawn,
  ) {
    if (!_active) return;
    _displayed.value = null;
  }

  void _onSourceError() {
    if (!_active) return;
    // Authority loss or a source failure clears the frame at once and releases
    // the staged group: nothing that was prepared before it may install later.
    _displayed.value = null;
    _localUnavailable = 'source_unavailable';
    _display?.dispose();
    _display = null;
  }

  /// Dispatches the contribution's action with ordinary values and credential
  /// handles only.
  FutureOr<void> dispatch({
    Map<String, String> values = const <String, String>{},
    Map<String, String> credentialRefs = const <String, String>{},
  }) {
    final action = _action;
    final actionRef = contribution.actionRef;
    if (!_active || action == null || actionRef == null) {
      return Future<void>.value();
    }
    return action.dispatch(
      ExtensionUiActionInvocation(
        actionRef: actionRef,
        contributionId: contribution.id,
        kind: contribution.kind,
        origin: pinnedOrigin,
        values: values,
        credentialRefs: credentialRefs,
      ),
    );
  }

  /// Takes one secret into host custody and returns only the outcome.
  ///
  /// The session awaits the host port: a handle exists only after the host
  /// confirmed custody, so an action can never be dispatched with a placeholder.
  /// A port failure is reported as a refusal instead of pretending success, and
  /// a withdrawal that lands while the host is storing turns into
  /// [ExtensionUiCredentialRefused] so the caller drops the pending action.
  Future<ExtensionUiCredentialOutcome> storeCredential({
    required String fieldId,
    required String secret,
  }) async {
    final port = _credentialPort;
    final actionRef = contribution.actionRef;
    if (!_active || port == null || actionRef == null) {
      return const ExtensionUiCredentialRefused('credential_unavailable');
    }
    final String handle;
    try {
      handle = await port.storeCredential(
        ExtensionUiCredentialRequest(
          origin: pinnedOrigin,
          contributionId: contribution.id,
          fieldId: fieldId,
          actionRef: actionRef,
          secret: secret,
        ),
      );
    } on Object {
      return const ExtensionUiCredentialRefused('credential_failed');
    }
    if (!_active) {
      // The epoch was withdrawn while the host was storing. The handle is not
      // dispatched, so no stale action follows the withdrawal.
      return const ExtensionUiCredentialRefused('withdrawn');
    }
    if (handle.isEmpty) {
      return const ExtensionUiCredentialRefused('credential_failed');
    }
    return ExtensionUiCredentialStored(handle);
  }

  /// Dispatches one action the graph renderer asked for.
  ///
  /// The action stays pending until the host reports its native receipt: the
  /// waiting state is kept here, next to the port, so the renderer cannot show
  /// an outcome the native owner has not confirmed.
  Future<void> dispatchGraphAction(GraphActionRequest request) async {
    final action = _action;
    if (!_active || action == null) return;
    final key = request.key;
    pendingGraphActions.value = <String>{...pendingGraphActions.value, key};
    try {
      await Future<void>.sync(
        () => action.dispatch(
          ExtensionUiActionInvocation(
            actionRef: request.actionRef,
            contributionId: contribution.id,
            kind: contribution.kind,
            origin: pinnedOrigin,
            values: <String, String>{
              ...request.values,
              // The admitted plan revision the user saw. A request that cannot
              // cite one is refused by the port instead of being applied to an
              // unknown plan.
              'revision':
                  '${_graph?.current?.document.planRevision ?? 0}',
              if (request.nodeId != null) 'nodeId': request.nodeId!,
              if (request.gateId != null) 'gateId': request.gateId!,
            },
          ),
        ),
      );
    } finally {
      if (pendingGraphActions.value.contains(key)) {
        pendingGraphActions.value = <String>{...pendingGraphActions.value}
          ..remove(key);
      }
    }
  }

  void _withdraw() {
    if (!_active) return;
    _active = false;
    final graph = _graph;
    _graph = null;
    if (graph != null) {
      // Withdrawal hides the graph at once: the controller drops its installed
      // values and detaches from the source before this returns.
      graph.dispose();
    }
    final observation = _observation;
    _observation = null;
    if (observation != null) {
      unawaited(observation.close());
    }
    _display?.dispose();
    _display = null;
    _displayed.value = null;
    // The notifier itself is released with the session; it is not disposed here
    // because the element tree may still detach its listener in this frame.
  }

  @override
  String toString() => 'ExtensionUiContributionSession($identity)';
}

/// Mounts and withdraws declarative interface contributions by registry epoch.
///
/// The registry is a [Listenable]: mounting or withdrawing an epoch notifies
/// once, while a data update inside a mounted contribution only reaches that
/// contribution's own primitive through its session.
final class ExtensionUiMountRegistry extends ChangeNotifier {
  ExtensionUiMountRegistry({
    required PresentationRuntime runtime,
    required ExtensionUiBindingResolver bindings,
    ExtensionUiCredentialPort? credentialPort,
    Set<DeclarativePrimitive> availablePrimitives =
        defaultExtensionUiPrimitives,
    Set<String> availableResourceFormats = extensionUiResourceViewFormats,
  }) : _runtime = runtime,
       _bindings = bindings,
       _credentialPort = credentialPort,
       _availablePrimitives = Set<DeclarativePrimitive>.unmodifiable(
         availablePrimitives,
       ),
       _availableResourceFormats = Set<String>.unmodifiable(
         availableResourceFormats,
       );

  /// The primitives the compiled shell provides by default.
  ///
  /// A resource view is not listed here: it mounts through the renderer
  /// registered for its declared resource format.
  static const Set<DeclarativePrimitive> defaultExtensionUiPrimitives =
      <DeclarativePrimitive>{
        DeclarativePrimitive.form,
        DeclarativePrimitive.chart,
        DeclarativePrimitive.command,
      };

  final PresentationRuntime _runtime;
  final ExtensionUiBindingResolver _bindings;
  final ExtensionUiCredentialPort? _credentialPort;
  final Set<DeclarativePrimitive> _availablePrimitives;
  final Set<String> _availableResourceFormats;

  ExtensionUiRegistrySnapshot _snapshot = ExtensionUiRegistrySnapshot.empty;
  List<ExtensionUiMountDecision> _decisions =
      const <ExtensionUiMountDecision>[];
  List<ExtensionUiContributionSession> _sessions =
      const <ExtensionUiContributionSession>[];
  bool _hasSnapshot = false;
  bool _disposed = false;

  /// The committed epoch currently mounted, or [ExtensionUiRegistrySnapshot.empty].
  ExtensionUiRegistrySnapshot get snapshot => _snapshot;

  int get registryEpoch => _snapshot.registryEpoch;

  /// Every decision of the mounted epoch, blocked contributions included.
  List<ExtensionUiMountDecision> get decisions => _decisions;

  /// The mounted contributions, in catalog order.
  List<ExtensionUiContributionSession> get mounted => _sessions;

  Set<DeclarativePrimitive> get availablePrimitives => _availablePrimitives;

  /// Resource-view formats this shell build compiles a renderer for.
  Set<String> get availableResourceFormats => _availableResourceFormats;

  /// Mounts one committed epoch, withdrawing the previous one as a whole.
  ///
  /// Mounting the epoch that is already mounted is a no-op: an epoch is
  /// committed once, so re-delivering it must not tear the interface down.
  void mount(ExtensionUiRegistrySnapshot snapshot) {
    if (_disposed) return;
    if (_hasSnapshot && snapshot.registryEpoch == _snapshot.registryEpoch) {
      return;
    }
    _withdrawSessions();
    _snapshot = snapshot;
    _hasSnapshot = true;
    _decisions = planExtensionUiMount(
      snapshot.contributions.map((entry) => entry.contribution),
      servedProfiles: snapshot.servedProfiles,
      availablePrimitives: _availablePrimitives,
      availableResourceFormats: _availableResourceFormats,
    );
    final sessions = <ExtensionUiContributionSession>[];
    for (var index = 0; index < snapshot.contributions.length; index++) {
      final decision = _decisions[index];
      if (!decision.isMounted) continue;
      final entry = snapshot.contributions[index];
      final session = ExtensionUiContributionSession._(
        identity: ExtensionUiMountIdentity(
          registryEpoch: snapshot.registryEpoch,
          instanceId: entry.instanceId,
          generation: entry.generation,
          contributionId: entry.contribution.id,
        ),
        contribution: entry.contribution,
        runtime: _runtime,
        binding: _bindings.resourceFor(entry.contribution.resourceRef ?? ''),
        graphBinding:
            entry.contribution.kind == ExtensionContributionKind.resourceView
            ? _bindings.graphResourceFor(entry.contribution.resourceRef ?? '')
            : null,
        action: _bindings.actionFor(entry.contribution.actionRef ?? ''),
        credentialPort: _credentialPort,
      );
      session._start();
      sessions.add(session);
    }
    _sessions = List<ExtensionUiContributionSession>.unmodifiable(sessions);
    notifyListeners();
  }

  /// Withdraws the mounted epoch: every subscription and prepared value of
  /// every mounted contribution is released, and late results cannot install.
  void withdraw() {
    if (_disposed) return;
    final hadEpoch = _hasSnapshot;
    final hadSessions = _sessions.isNotEmpty;
    _withdrawSessions();
    _snapshot = ExtensionUiRegistrySnapshot.empty;
    _hasSnapshot = false;
    _decisions = const <ExtensionUiMountDecision>[];
    if (hadEpoch || hadSessions) notifyListeners();
  }

  void _withdrawSessions() {
    final sessions = _sessions;
    _sessions = const <ExtensionUiContributionSession>[];
    for (final session in sessions) {
      session._withdraw();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _withdrawSessions();
    super.dispose();
  }
}
