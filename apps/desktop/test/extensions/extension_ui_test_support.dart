/// Synthetic fixtures for the declarative contribution host tests.
///
/// Everything here is local synthetic data: no real extension package, no
/// network, no credentials.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

/// One synthetic resource field group per stable key.
ResourceFieldGroup<ExtensionUiResourceValue> syntheticExtensionField(
  String stableKey,
) => ResourceFieldGroup<ExtensionUiResourceValue>(
  resource: ResourceKey(
    scope: const ResourceScope('extension-test'),
    stableKey: stableKey,
  ),
  name: 'value',
);

/// A source whose reads, closes and publications the test can observe.
///
/// It counts opens and closes, so a test can prove that withdrawing a
/// contribution released its subscription and that an unrelated consumer's
/// source was not read again.
final class SyntheticExtensionResourceSource
    implements PresentationSource<ExtensionUiResourceValue> {
  SyntheticExtensionResourceSource({
    required this.fieldGroup,
    ExtensionUiResourceValue? initial,
    String epoch = 'synthetic-epoch',
  }) : _value = initial ?? ExtensionUiResourceValue(),
       _epoch = SourceEpoch(epoch);

  @override
  final ResourceFieldGroup<ExtensionUiResourceValue> fieldGroup;

  final SourceEpoch _epoch;
  ExtensionUiResourceValue _value;
  SourceVersion _version = const SourceVersion(1);
  StreamController<SourceChange<ExtensionUiResourceValue>>? _changes;
  int openCount = 0;
  int closeCount = 0;

  ExtensionUiResourceValue get value => _value;

  SourcePosition get position =>
      SourcePosition(epoch: _epoch, version: _version);

  @override
  Future<SourceObservation<ExtensionUiResourceValue>> open() async {
    openCount += 1;
    final controller = StreamController<SourceChange<ExtensionUiResourceValue>>(
      sync: true,
    );
    controller.onCancel = () {
      closeCount += 1;
    };
    _changes = controller;
    return SourceObservation<ExtensionUiResourceValue>(
      initial: ResourceSnapshot<ExtensionUiResourceValue>(
        fieldGroup: fieldGroup,
        epoch: _epoch,
        version: _version,
        value: _value,
      ),
      changes: controller.stream,
    );
  }

  /// Publishes one newer value as a base-matched source change.
  void publish(ExtensionUiResourceValue value) {
    final controller = _changes;
    if (controller == null || controller.isClosed) return;
    final base = position;
    _value = value;
    _version = SourceVersion(base.version.value + 1);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        '${fieldGroup.resource.stableKey}-${_version.value}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    controller.add(
      SourceChange<ExtensionUiResourceValue>(
        snapshot: ResourceSnapshot<ExtensionUiResourceValue>(
          fieldGroup: fieldGroup,
          epoch: _epoch,
          version: _version,
          value: value,
          consistencyGroup: group,
        ),
        base: base,
        group: group,
      ),
    );
  }

  /// Fails the open stream, as an authority withdrawal does.
  void fail(Object error) {
    final controller = _changes;
    if (controller == null || controller.isClosed) return;
    controller.addError(error, StackTrace.current);
  }
}

/// Records every action a mounted contribution dispatched.
final class RecordingExtensionActions implements ExtensionUiActionPort {
  final List<ExtensionUiActionInvocation> invocations =
      <ExtensionUiActionInvocation>[];

  @override
  FutureOr<void> dispatch(ExtensionUiActionInvocation invocation) {
    invocations.add(invocation);
  }
}

/// Fixture-only credential custody.
///
/// This exists so tests can prove the host seam without a real keychain; it is
/// never the production path. The composition gets no fallback, so a test that
/// wants secret fields available must inject this explicitly.
final class FixtureExtensionCredentialPort
    implements ExtensionUiCredentialPort {
  final List<ExtensionUiCredentialRequest> requests =
      <ExtensionUiCredentialRequest>[];
  final Map<String, String> _values = <String, String>{};
  int _nextHandle = 0;

  /// When true, the next store throws as a refusing host port does.
  bool fail = false;

  /// When set, a store waits for it before answering, so a test can withdraw
  /// the epoch while custody is still pending.
  Completer<void>? gate;

  @override
  Future<String> storeCredential(ExtensionUiCredentialRequest request) async {
    requests.add(request);
    final pending = gate;
    if (pending != null) await pending.future;
    if (fail) {
      throw StateError('fixture credential port refused');
    }
    final handle = 'credential:fixture-${++_nextHandle}';
    _values[handle] = request.secret;
    return handle;
  }

  /// Whether this fixture, and only this fixture, holds a value for [handle].
  bool holds(String handle) => _values.containsKey(handle);

  /// The secret the fixture holds for [handle], for assertions only.
  String? secretFor(String handle) => _values[handle];
}

/// One committed epoch document with the given contributions.
Map<String, Object?> extensionEpochDocument({
  required int registryEpoch,
  Set<String> servedProfiles = const <String>{'declarative-ui'},
  required List<Map<String, Object?>> contributions,
}) => <String, Object?>{
  'registryEpoch': registryEpoch,
  'servedProfiles': servedProfiles.toList(growable: false),
  'contributions': contributions,
};

/// One contribution entry as the catalog binds it.
Map<String, Object?> extensionContributionJson({
  required String id,
  required String kind,
  String title = 'Synthetic contribution',
  String? requiredProfile,
  String? resourceRef,
  String? actionRef,
  List<Map<String, Object?>> fields = const <Map<String, Object?>>[],
  List<Map<String, Object?>> series = const <Map<String, Object?>>[],
  String instanceId = 'instance-1',
  int generation = 1,
  String? packageId,
}) => <String, Object?>{
  ...extensionDeclarationJson(
    id: id,
    kind: kind,
    title: title,
    requiredProfile: requiredProfile,
    resourceRef: resourceRef,
    actionRef: actionRef,
    fields: fields,
    series: series,
  ),
  'instanceId': instanceId,
  'packageId': ?packageId,
  'generation': generation,
};

/// One bare contribution declaration, without the catalog binding facts.
Map<String, Object?> extensionDeclarationJson({
  required String id,
  required String kind,
  String title = 'Synthetic contribution',
  String? requiredProfile,
  String? resourceRef,
  String? actionRef,
  List<Map<String, Object?>> fields = const <Map<String, Object?>>[],
  List<Map<String, Object?>> series = const <Map<String, Object?>>[],
}) => <String, Object?>{
  'schema': 'licoup.ui-contribution.v1',
  'id': id,
  'kind': kind,
  'title': title,
  'requiredProfile': ?requiredProfile,
  'resourceRef': ?resourceRef,
  'actionRef': ?actionRef,
  if (fields.isNotEmpty) 'fields': fields,
  if (series.isNotEmpty) 'series': series,
};

/// One form field declaration.
Map<String, Object?> extensionFieldJson({
  required String id,
  required String label,
  required String type,
  bool required = false,
  String? value,
}) => <String, Object?>{
  'id': id,
  'label': label,
  'type': type,
  'required': required,
  'value': ?value,
};

/// One metric series declaration.
Map<String, Object?> extensionSeriesJson({
  required String metric,
  required String label,
  required String unit,
}) => <String, Object?>{'metric': metric, 'label': label, 'unit': unit};

/// Builds the mount registry over one runtime and binding table.
ExtensionUiMountRegistry syntheticExtensionRegistry({
  required PresentationRuntime runtime,
  required ExtensionUiBindingResolver bindings,
  ExtensionUiCredentialPort? credentialPort,
  Set<DeclarativePrimitive> availablePrimitives =
      ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
}) => ExtensionUiMountRegistry(
  runtime: runtime,
  bindings: bindings,
  credentialPort: credentialPort,
  availablePrimitives: availablePrimitives,
);
