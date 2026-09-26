/// Host-owned bindings for declarative interface contributions.
///
/// A contribution never reads a source, calls an application facade or stores a
/// secret. It names a `resourceRef` and an `actionRef`; the composition resolves
/// those names to host-owned objects here, and the mounted contribution only
/// sees prepared values and typed actions with a pinned originating scope.
///
/// Feature authors register bindings on an [ExtensionUiBindingRegistry] instead
/// of writing global providers, so the contribution host stays the single owner
/// of observation, preparation and withdrawal.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'extension_ui_contribution.dart';

/// The display-ready value one contribution resource provides.
///
/// The host decodes an extension's resource payload into this snapshot before a
/// primitive renders it. Every member is copied into an unmodifiable view at
/// construction, including the nested option and sample lists, so the caller
/// cannot change a value that was already admitted by mutating the collections
/// it passed in. The members are the bounded shapes the compiled primitives
/// understand; a primitive ignores members it does not draw, and nothing here
/// can carry code, a provider or a raw secret.
final class ExtensionUiResourceValue {
  ExtensionUiResourceValue({
    Map<String, String> formValues = const <String, String>{},
    Map<String, List<String>> fieldOptions = const <String, List<String>>{},
    Map<String, List<double>> series = const <String, List<double>>{},
  }) : formValues = Map<String, String>.unmodifiable(formValues),
       fieldOptions = Map<String, List<String>>.unmodifiable(
         fieldOptions.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       series = Map<String, List<double>>.unmodifiable(
         series.map(
           (key, value) => MapEntry(key, List<double>.unmodifiable(value)),
         ),
       );

  /// Current values of a settings form, keyed by field id.
  final Map<String, String> formValues;

  /// Allowed options of a `select` field, keyed by field id.
  final Map<String, List<String>> fieldOptions;

  /// Samples of a metric panel, keyed by the standardized metric name the
  /// contribution declared.
  final Map<String, List<double>> series;

  bool get isEmpty =>
      formValues.isEmpty && fieldOptions.isEmpty && series.isEmpty;

  @override
  String toString() =>
      'ExtensionUiResourceValue(${formValues.length} fields, '
      '${series.length} series)';
}

/// One resource a contribution may display.
///
/// The source belongs to the host: the runtime observes it once per container
/// and shares it between contributions that name the same `resourceRef`.
/// [prepare] derives the value a primitive displays from the admitted source
/// value; it runs through the runtime's preparation admission, so a result that
/// arrives after the contribution was withdrawn, or after a newer source
/// position was admitted, never installs.
final class ExtensionUiResourceBinding {
  const ExtensionUiResourceBinding({
    required this.resourceRef,
    required this.source,
    this.prepare,
  });

  final String resourceRef;
  final PresentationSource<ExtensionUiResourceValue> source;

  /// Pure preparation step, or null when the admitted value is already
  /// display-ready.
  final FutureOr<ExtensionUiResourceValue> Function(
    ExtensionUiResourceValue value,
  )?
  prepare;

  ResourceFieldGroup<ExtensionUiResourceValue> get fieldGroup =>
      source.fieldGroup;
}

/// One action invocation a contribution asked for.
///
/// [values] carries ordinary field values and [credentialRefs] carries only
/// opaque handles the host stored; a raw secret never appears here. Both maps
/// are copied into unmodifiable views, so a caller that keeps a reference to
/// the map it passed cannot change an invocation a host port is still
/// processing.
final class ExtensionUiActionInvocation {
  ExtensionUiActionInvocation({
    required this.actionRef,
    required this.contributionId,
    required this.kind,
    required this.origin,
    Map<String, String> values = const <String, String>{},
    Map<String, String> credentialRefs = const <String, String>{},
  }) : values = Map<String, String>.unmodifiable(values),
       credentialRefs = Map<String, String>.unmodifiable(credentialRefs);

  final String actionRef;
  final String contributionId;
  final ExtensionContributionKind kind;
  final ActionOrigin origin;
  final Map<String, String> values;
  final Map<String, String> credentialRefs;

  @override
  String toString() =>
      'ExtensionUiActionInvocation($actionRef, $contributionId)';
}

/// The host-owned authority of one action name.
///
/// A contribution names an action; the host decides what it does and under
/// which scope. Implementations belong to the composition, never to the
/// contribution package.
abstract interface class ExtensionUiActionPort {
  FutureOr<void> dispatch(ExtensionUiActionInvocation invocation);
}

/// One graph resource a `resource-view` contribution may display.
///
/// The host owns the source; the contribution only names it. Layout and status
/// preparation run through the runtime's own admission, so a view can never
/// read a runtime, a store or a controller.
final class ExtensionUiGraphResourceBinding {
  const ExtensionUiGraphResourceBinding({
    required this.resourceRef,
    required this.source,
  });

  final String resourceRef;
  final PresentationSource<GraphDocumentUpdate> source;
}

/// Resolves the names one contribution declared to host-owned bindings.
abstract interface class ExtensionUiBindingResolver {
  ExtensionUiResourceBinding? resourceFor(String resourceRef);

  ExtensionUiActionPort? actionFor(String actionRef);

  /// The graph resource behind a `resource-view` contribution, when the host
  /// registered one.
  ExtensionUiGraphResourceBinding? graphResourceFor(String resourceRef);
}

/// One secret the host control collected and wants taken into host custody.
///
/// The session pins [origin] and [actionRef] from the mounted contribution, so
/// the host port verifies a scope it already knows instead of trusting a name
/// the contribution supplied. The raw secret is part of the request and stays
/// between the host control and the host port; it is never returned to a
/// contribution.
final class ExtensionUiCredentialRequest {
  const ExtensionUiCredentialRequest({
    required this.origin,
    required this.contributionId,
    required this.fieldId,
    required this.actionRef,
    required this.secret,
  });

  final ActionOrigin origin;
  final String contributionId;
  final String fieldId;
  final String actionRef;
  final String secret;

  @override
  String toString() => 'ExtensionUiCredentialRequest($contributionId/$fieldId)';
}

/// Host custody for secrets collected by host controls.
///
/// There is no in-memory fallback: the display layer must not become a second
/// credential owner. The composition injects the real platform store; when no
/// port is injected, secret fields of that contribution are locally unavailable
/// and no action is dispatched with a placeholder handle. The host stores the
/// value and returns the handle only after custody succeeded.
abstract interface class ExtensionUiCredentialPort {
  FutureOr<String> storeCredential(ExtensionUiCredentialRequest request);
}

/// What the host credential port returned for one secret field.
sealed class ExtensionUiCredentialOutcome {
  const ExtensionUiCredentialOutcome();
}

/// The host stored the secret and issued this handle.
final class ExtensionUiCredentialStored extends ExtensionUiCredentialOutcome {
  const ExtensionUiCredentialStored(this.handle);

  final String handle;
}

/// No custody happened, so no action may be dispatched with this field.
///
/// `credential_unavailable`: the composition injected no credential port.
/// `credential_failed`: the injected port refused or failed.
/// `withdrawn`: the contribution was withdrawn while the host was storing.
final class ExtensionUiCredentialRefused extends ExtensionUiCredentialOutcome {
  const ExtensionUiCredentialRefused(this.reason);

  final String reason;
}

/// Mutable binding table a composition fills before mounting an epoch.
///
/// Re-registering the same `resourceRef` with a different source instance is
/// refused: the runtime keeps one observation per resource field group, so two
/// sources for one name could disagree about the admitted value.
final class ExtensionUiBindingRegistry implements ExtensionUiBindingResolver {
  final Map<String, ExtensionUiResourceBinding> _resources =
      <String, ExtensionUiResourceBinding>{};
  final Map<String, ExtensionUiActionPort> _actions =
      <String, ExtensionUiActionPort>{};
  final Map<String, ExtensionUiGraphResourceBinding> _graphResources =
      <String, ExtensionUiGraphResourceBinding>{};

  Iterable<String> get resourceRefs => _resources.keys;

  Iterable<String> get actionRefs => _actions.keys;

  Iterable<String> get graphResourceRefs => _graphResources.keys;

  void registerResource(ExtensionUiResourceBinding binding) {
    final existing = _resources[binding.resourceRef];
    if (existing != null && !identical(existing.source, binding.source)) {
      throw StateError(
        'resource ${binding.resourceRef} is already bound to another source',
      );
    }
    _resources[binding.resourceRef] = binding;
  }

  void registerAction(String actionRef, ExtensionUiActionPort port) {
    _actions[actionRef] = port;
  }

  void registerGraphResource(ExtensionUiGraphResourceBinding binding) {
    _graphResources[binding.resourceRef] = binding;
  }

  void unregisterResource(String resourceRef) {
    _resources.remove(resourceRef);
  }

  void unregisterGraphResource(String resourceRef) {
    _graphResources.remove(resourceRef);
  }

  void unregisterAction(String actionRef) {
    _actions.remove(actionRef);
  }

  @override
  ExtensionUiResourceBinding? resourceFor(String resourceRef) =>
      _resources[resourceRef];

  @override
  ExtensionUiActionPort? actionFor(String actionRef) => _actions[actionRef];

  @override
  ExtensionUiGraphResourceBinding? graphResourceFor(String resourceRef) =>
      _graphResources[resourceRef];

  void clear() {
    _resources.clear();
    _actions.clear();
    _graphResources.clear();
  }
}
