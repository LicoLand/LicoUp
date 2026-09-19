import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_inputs.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/projections/plugin_management/plugin_management_presentation_sources.dart';
import 'package:licoup/src/projections/plugin_management/plugin_management_projection_producer.dart';

void main() {
  test(
    'catalog lifecycle declarations decide installable and uninstallable',
    () async {
      final rig = _RegionRig();
      addTearDown(rig.dispose);
      rig.runner.catalog = _catalog([
        _adapter(
          agentId: 'antigravity',
          managementKind: 'managed-bridge',
          actions: const ['install'],
          plugins: [_plugin(id: 'acp-bridge')],
        ),
      ]);
      await rig.open();
      await rig.plugins.refresh();

      final declaring = rig.catalogValue.plugins.single;
      expect(declaring.installable, isTrue);
      expect(declaring.uninstallable, isFalse);
      expect(declaring.plugins.single.installable, isFalse);
      expect(declaring.plugins.single.uninstallable, isFalse);

      final published = rig.catalogChanges.length;
      rig.runner.catalog = _catalog([
        _adapter(
          agentId: 'antigravity',
          plugins: [
            _plugin(id: 'acp-bridge', actions: const ['uninstall']),
          ],
        ),
      ]);
      await rig.plugins.refresh();

      final undeclared = rig.catalogValue.plugins.single;
      expect(undeclared.installable, isFalse);
      expect(undeclared.uninstallable, isTrue);
      expect(undeclared.plugins.single.installable, isFalse);
      expect(undeclared.plugins.single.uninstallable, isTrue);

      expect(rig.catalogChanges.length, greaterThan(published));
      expect(rig.collaborationChanges, isEmpty);
    },
  );

  test('native capability evidence reaches the catalog region', () async {
    final rig = _RegionRig();
    addTearDown(rig.dispose);
    rig.runner.catalog = _catalog([
      _adapter(
        agentId: 'kimi-code',
        managementKind: 'bundled-acp',
        capabilities: [
          {
            'kind': 'cli',
            'detected': true,
            'running': true,
            'pid': 67099,
            'processName': 'kimi',
          },
          {
            'kind': 'web-server',
            'detected': true,
            'running': true,
            'pid': 58627,
            'processName': 'kimi',
            'port': 58627,
          },
        ],
      ),
    ]);
    await rig.open();
    await rig.plugins.refresh();

    final capabilities = rig.catalogValue.plugins.single.capabilities;
    expect(capabilities.map((capability) => capability.id), [
      'cli',
      'web-server',
    ]);
    final cli = capabilities.first;
    expect(cli.detected, isTrue);
    expect(cli.running, isTrue);
    expect(cli.pid, 67099);
    expect(cli.processName, 'kimi');
    expect(cli.port, isNull);
    final webServer = capabilities.last;
    expect(webServer.detected, isTrue);
    expect(webServer.running, isTrue);
    expect(webServer.pid, 58627);
    expect(webServer.processName, 'kimi');
    expect(webServer.port, 58627);

    final published = rig.catalogChanges.length;
    rig.runner.catalog = _catalog([
      _adapter(
        agentId: 'kimi-code',
        managementKind: 'bundled-acp',
        capabilities: [
          {
            'kind': 'cli',
            'detected': true,
            'running': true,
            'pid': 67099,
            'processName': 'kimi',
          },
          {
            'kind': 'web-server',
            'detected': true,
            'running': true,
            'pid': 59000,
            'processName': 'kimi',
            'port': 59000,
          },
        ],
      ),
    ]);
    await rig.plugins.refresh();

    final updated = rig.catalogValue.plugins.single.capabilities.last;
    expect(updated.pid, 59000);
    expect(updated.processName, 'kimi');
    expect(updated.port, 59000);
    expect(rig.catalogChanges.length, greaterThan(published));
    expect(rig.collaborationChanges, isEmpty);
  });

  test(
    'regions keep isolated snapshots, ordered versions, and release the producer',
    () async {
      final rig = _RegionRig(countUpstream: true);
      addTearDown(rig.dispose);
      rig.runner.catalog = _catalog([
        _adapter(
          agentId: 'antigravity',
          managementKind: 'managed-bridge',
          actions: const ['install'],
          capabilities: [
            {'kind': 'cli', 'detected': true, 'running': false},
          ],
        ),
      ]);
      await rig.open();

      expect(rig.counter.listens, 2);
      expect(rig.counter.cancels, 0);

      await rig.plugins.refresh();
      expect(rig.catalogChanges, isNotEmpty);
      expect(rig.collaborationChanges, isEmpty);
      _expectOrderedChain(rig.catalogInitial, rig.catalogChanges);

      // A collaboration-only publish reaches the collaboration region and
      // leaves the installed catalog snapshot untouched.
      final catalogCount = rig.catalogChanges.length;
      final catalogPosition = rig.catalogChanges.last.position;
      await rig.collaboration.loadStatus();
      expect(rig.collaborationChanges, isNotEmpty);
      expect(rig.catalogChanges, hasLength(catalogCount));
      expect(rig.catalogChanges.last.position, catalogPosition);
      _expectOrderedChain(rig.catalogInitial, rig.catalogChanges);

      final lastVersion = catalogPosition.version.value;
      await rig.cancelObservations();
      expect(rig.counter.cancels, 2);

      await rig.open();
      expect(rig.counter.listens, 4);
      expect(rig.catalogInitial.version.value, greaterThan(lastVersion));

      rig.runner.catalog = _catalog([
        _adapter(
          agentId: 'antigravity',
          managementKind: 'managed-bridge',
          actions: const ['uninstall'],
        ),
      ]);
      await rig.plugins.refresh();
      expect(rig.catalogChanges, isNotEmpty);
      _expectOrderedChain(rig.catalogInitial, rig.catalogChanges);
    },
  );
}

void _expectOrderedChain(
  ResourceSnapshot<PluginCatalogInputs> initial,
  List<SourceChange<PluginCatalogInputs>> changes,
) {
  var base = initial.position;
  var version = initial.version.value;
  for (final change in changes) {
    expect(change.base, base);
    expect(change.position.epoch, initial.epoch);
    expect(change.position.version.value, greaterThan(version));
    expect(change.group.changed, hasLength(1));
    expect(
      change.group.changed.single,
      ChangedFieldGroup.of(pluginCatalogFieldGroup),
    );
    expect(change.snapshot.consistencyGroup, change.group);
    base = change.position;
    version = change.position.version.value;
  }
}

final class _RegionRig {
  _RegionRig({bool countUpstream = false}) {
    plugins = AdapterPluginController(runner: runner, onStatus: (_) {});
    collaboration = OptionalCollaborationController(gateway: _StatusGateway());
    producer = PluginManagementProjectionProducer(
      plugins: plugins,
      collaboration: collaboration,
    );
    final ProjectionSource<PluginManagementProjection> upstream;
    if (countUpstream) {
      counter = _CountingProjectionSource(producer);
      upstream = counter;
    } else {
      upstream = producer;
    }
    catalogSource = pluginCatalogPresentationSource(upstream);
    collaborationSource = pluginCollaborationPresentationSource(upstream);
  }

  final _CatalogRunner runner = _CatalogRunner();
  late final AdapterPluginController plugins;
  late final OptionalCollaborationController collaboration;
  late final PluginManagementProjectionProducer producer;
  late final _CountingProjectionSource counter;
  late final PluginManagementRegionPresentationSource<PluginCatalogInputs>
  catalogSource;
  late final PluginManagementRegionPresentationSource<PluginCollaborationInputs>
  collaborationSource;
  final List<SourceChange<PluginCatalogInputs>> catalogChanges =
      <SourceChange<PluginCatalogInputs>>[];
  final List<SourceChange<PluginCollaborationInputs>> collaborationChanges =
      <SourceChange<PluginCollaborationInputs>>[];
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  late ResourceSnapshot<PluginCatalogInputs> catalogInitial;

  PluginCatalogInputs get catalogValue => catalogChanges.isEmpty
      ? catalogInitial.value
      : catalogChanges.last.snapshot.value;

  Future<void> open() async {
    final catalogObservation = await catalogSource.open();
    final collaborationObservation = await collaborationSource.open();
    catalogInitial = catalogObservation.initial;
    catalogChanges.clear();
    collaborationChanges.clear();
    _subscriptions
      ..add(catalogObservation.changes.listen(catalogChanges.add))
      ..add(collaborationObservation.changes.listen(collaborationChanges.add));
  }

  Future<void> cancelObservations() async {
    for (final subscription in List<StreamSubscription<Object?>>.of(
      _subscriptions,
    )) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> dispose() async {
    await cancelObservations();
    await catalogSource.dispose();
    await collaborationSource.dispose();
    await producer.dispose();
    collaboration.dispose();
    plugins.dispose();
  }
}

/// Counts upstream subscribe/cancel without adding a scheduling hop of its own.
final class _CountingProjectionSource
    implements ProjectionSource<PluginManagementProjection> {
  _CountingProjectionSource(this._inner);

  final ProjectionSource<PluginManagementProjection> _inner;
  int listens = 0;
  int cancels = 0;

  @override
  PluginManagementProjection get current => _inner.current;

  @override
  Stream<ProjectionUpdate<PluginManagementProjection>> get changes =>
      _CountingStream(_inner.changes, this);

  void _recordListen() => listens += 1;

  void _recordCancel() => cancels += 1;
}

final class _CountingStream<T> extends Stream<T> {
  _CountingStream(this._inner, this._owner);

  final Stream<T> _inner;
  final _CountingProjectionSource _owner;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _owner._recordListen();
    return _CountingSubscription<T>(
      _inner.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _owner,
    );
  }
}

final class _CountingSubscription<T> implements StreamSubscription<T> {
  _CountingSubscription(this._inner, this._owner);

  final StreamSubscription<T> _inner;
  final _CountingProjectionSource _owner;
  bool _cancelled = false;

  @override
  Future<void> cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _owner._recordCancel();
    }
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}

final class _CatalogRunner implements AgentCommandRunner {
  Map<String, dynamic> catalog = _catalog(const []);

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => catalog;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

final class _StatusGateway implements OptionalCollaborationGateway {
  @override
  Future<OptionalCollaborationRuntimeState> status() async =>
      const OptionalCollaborationRuntimeState.disabled();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('synthetic_gateway_call');
}

Map<String, dynamic> _catalog(List<Map<String, dynamic>> adapters) => {
  'ok': true,
  'schemaVersion': adapterPluginCatalogSchema,
  'adapters': adapters,
};

Map<String, dynamic> _adapter({
  required String agentId,
  String managementKind = 'native',
  List<String> actions = const [],
  List<Map<String, dynamic>> capabilities = const [],
  List<Map<String, dynamic>> plugins = const [],
  String installationState = 'not-installed',
}) => {
  'agentId': agentId,
  'label': agentId,
  'driverId': '$agentId-driver',
  'runtimeProtocol': '$agentId-protocol',
  'laneFamily': managementKind == 'bundled-acp' ? 'acp' : 'cli',
  'managementKind': managementKind,
  'installationState': installationState,
  'readiness': 'ready',
  'lifecycleActions': actions,
  'nativeCapabilities': capabilities,
  'adapterPlugins': plugins,
};

Map<String, dynamic> _plugin({
  required String id,
  List<String> actions = const [],
  String installationState = 'not-installed',
}) => {
  'id': id,
  'label': id,
  'detail': '',
  'installationState': installationState,
  'lifecycleActions': actions,
};
