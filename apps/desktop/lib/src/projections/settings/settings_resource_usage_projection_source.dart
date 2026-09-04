import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class SettingsResourceUsageProjectionSource
    implements ProjectionSource<SettingsResourceUsageProjection> {
  SettingsResourceUsageProjectionSource({
    required ClientResourceUsageController client,
    required AgentResourceUsageController agents,
  }) : _client = client,
       _agents = agents,
       _current = _read(client, agents) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      _client.changes.listen(_onChange),
      _agents.changes.listen(_onChange),
    ];
  }

  final ClientResourceUsageController _client;
  final AgentResourceUsageController _agents;
  final StreamController<ProjectionUpdate<SettingsResourceUsageProjection>>
  _changes =
      StreamController<
        ProjectionUpdate<SettingsResourceUsageProjection>
      >.broadcast(sync: true);
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  SettingsResourceUsageProjection _current;
  bool _disposed = false;

  @override
  SettingsResourceUsageProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SettingsResourceUsageProjection>> get changes =>
      _changes.stream;

  void start() {
    if (_disposed) return;
    _client.start();
    _agents.start();
  }

  void stop() {
    _client.stop();
    _agents.stop();
  }

  void _onChange(ApplicationChange change) {
    if (_disposed) return;
    final next = _read(_client, _agents);
    if (next == _current) return;
    _current = next;
    _changes.add(
      ProjectionUpdate(
        next,
        trace: change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    _client.dispose();
    _agents.dispose();
    await closeBroadcastController(_changes);
  }

  static SettingsResourceUsageProjection _read(
    ClientResourceUsageController client,
    AgentResourceUsageController agents,
  ) => SettingsResourceUsageProjection(
    supported: client.supported,
    clientRssBytes: client.samples.isEmpty ? 0 : client.samples.last.rssBytes,
    totalMemoryBytes: client.totalMemoryBytes,
    agentRssBytes: {
      for (final entry in agents.latestByAgent.entries)
        entry.key: entry.value.rssBytes,
    },
  );
}
