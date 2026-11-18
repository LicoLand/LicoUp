import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

void main() {
  test(
    'feature entry runs the requested lane first at foreground priority',
    () async {
      final events = <String>[];
      final backgrounds = <String, List<bool>>{};
      final reports = <ClientLifecycleReport>[];
      final controller = _hookController(
        reports,
        _featureTasks(events, backgrounds),
      );
      addTearDown(controller.dispose);

      controller.requestEntry(ClientSection.skillHub);
      await controller.awaitEntry(ClientSection.skillHub);

      expect(events, [
        'skillHub.start',
        'agentHub.start',
        'pluginManagement.start',
      ]);
      expect(backgrounds['skillHub'], [false]);
      expect(backgrounds['agentHub'], [true]);
      expect(backgrounds['pluginManagement'], [true]);
      expect(reports, isEmpty);
    },
  );

  test('same-cycle movement promotes without a second feature load', () async {
    final events = <String>[];
    final backgrounds = <String, List<bool>>{};
    final reports = <ClientLifecycleReport>[];
    final gates = <String, Completer<void>>{
      for (final section in _featureSections) section.name: Completer<void>(),
    };
    final tasks = _featureTasks(events, backgrounds, gates: gates);
    final controller = _hookController(reports, tasks);
    addTearDown(controller.dispose);

    controller.requestEntry(ClientSection.agentHub);
    await Future<void>.delayed(Duration.zero);
    expect(events, [
      'agentHub.start',
      'skillHub.start',
      'pluginManagement.start',
    ]);
    expect(backgrounds['agentHub'], [false]);
    expect(backgrounds['skillHub'], [true]);
    expect(backgrounds['pluginManagement'], [true]);

    // Reselecting and moving inside the active feature slice only promotes.
    controller.requestEntry(ClientSection.agentHub);
    controller.requestEntry(ClientSection.skillHub);
    controller.requestEntry(ClientSection.pluginManagement);
    await Future<void>.delayed(Duration.zero);

    expect(events.where((event) => event.endsWith('.start')).length, 3);
    for (final gate in gates.values) {
      gate.complete();
    }
    await Future.wait([
      for (final section in _featureSections) controller.awaitEntry(section),
    ]);

    expect(events.where((event) => event.endsWith('.start')).length, 3);
    expect(reports, isEmpty);
  });

  test(
    'leaving the feature slice closes the cycle and re-entry reruns all lanes',
    () async {
      final events = <String>[];
      final reports = <ClientLifecycleReport>[];
      final controller = _hookController(
        reports,
        _featureTasks(events, <String, List<bool>>{}),
      );
      addTearDown(controller.dispose);

      controller.requestEntry(ClientSection.skillHub);
      await controller.awaitEntry(ClientSection.skillHub);
      controller.requestEntry(ClientSection.settings);
      controller.requestEntry(ClientSection.skillHub);
      await controller.awaitEntry(ClientSection.skillHub);

      expect(events.where((event) => event == 'skillHub.start'), hasLength(2));
      expect(events.where((event) => event == 'agentHub.start'), hasLength(2));
      expect(
        events.where((event) => event == 'pluginManagement.start'),
        hasLength(2),
      );
    },
  );

  test(
    'conversation re-entry coalesces to one newest-trailing cycle',
    () async {
      final gate = Completer<void>();
      var agentsCalls = 0;
      final reports = <ClientLifecycleReport>[];
      final controller = ClientInterfaceEntryHookController(
        tasks: {
          ClientSection.agents: ClientInterfaceEntryHookTask(
            section: ClientSection.agents,
            action: () async {
              agentsCalls += 1;
              await gate.future;
            },
          ),
        },
        onReport: reports.add,
      );
      addTearDown(controller.dispose);

      controller.requestEntry(ClientSection.agents);
      await Future<void>.delayed(Duration.zero);
      expect(agentsCalls, 1);

      // Re-entry while the first flight is still active remembers only the
      // newest requested cycle and runs it once after settlement.
      controller.requestEntry(ClientSection.agents);
      controller.requestEntry(ClientSection.agents);
      gate.complete();
      await controller.awaitEntry(ClientSection.agents);

      expect(agentsCalls, 2);

      controller.requestEntry(ClientSection.agents);
      await controller.awaitEntry(ClientSection.agents);
      expect(agentsCalls, 3);
      expect(reports, isEmpty);
    },
  );

  test(
    'foreground promotion flips the background token while in flight',
    () async {
      final events = <String>[];
      final backgrounds = <String, List<bool>>{};
      final gates = <String, Completer<void>>{
        for (final section in _featureSections) section.name: Completer<void>(),
      };
      final reports = <ClientLifecycleReport>[];
      final controller = _hookController(
        reports,
        _featureTasks(events, backgrounds, gates: gates, recordAfterGate: true),
      );
      addTearDown(controller.dispose);

      controller.requestEntry(ClientSection.pluginManagement);
      await Future<void>.delayed(Duration.zero);
      expect(backgrounds['pluginManagement'], [false]);

      controller.requestEntry(ClientSection.skillHub);
      await Future<void>.delayed(Duration.zero);
      expect(backgrounds['skillHub'], [true]);

      for (final gate in gates.values) {
        gate.complete();
      }
      await Future.wait([
        for (final section in _featureSections) controller.awaitEntry(section),
      ]);

      expect(backgrounds['skillHub'], [true, false]);
      expect(events.where((event) => event.endsWith('.start')).length, 3);
    },
  );

  test('sibling failure is isolated and reported with a stable id', () async {
    final events = <String>[];
    final reports = <ClientLifecycleReport>[];
    final controller = ClientInterfaceEntryHookController(
      tasks: {
        ClientSection.agentHub: ClientInterfaceEntryHookTask(
          section: ClientSection.agentHub,
          action: () async => events.add('agentHub.start'),
        ),
        ClientSection.skillHub: ClientInterfaceEntryHookTask(
          section: ClientSection.skillHub,
          action: () async => throw StateError('synthetic'),
        ),
        ClientSection.pluginManagement: ClientInterfaceEntryHookTask(
          section: ClientSection.pluginManagement,
          action: () async => events.add('pluginManagement.start'),
        ),
      },
      onReport: reports.add,
    );
    addTearDown(controller.dispose);

    controller.requestEntry(ClientSection.skillHub);
    await controller.awaitEntry(ClientSection.skillHub);
    await controller.awaitEntry(ClientSection.agentHub);
    await controller.awaitEntry(ClientSection.pluginManagement);

    expect(events, containsAll(['agentHub.start', 'pluginManagement.start']));
    expect(reports, hasLength(1));
    expect(reports.single.code, 'client_interface_entry_hook_failed');
    expect(reports.single.stepId, 'feature.skillHub');

    // Leaving the slice closes the cycle; a later re-entry still schedules a
    // fresh run for every lane.
    controller.requestEntry(ClientSection.settings);
    controller.requestEntry(ClientSection.pluginManagement);
    await controller.awaitEntry(ClientSection.pluginManagement);
    expect(
      events.where((event) => event == 'pluginManagement.start'),
      hasLength(2),
    );
  });

  test(
    'awaitEntry returns immediately for unknown and non-group sections',
    () async {
      final reports = <ClientLifecycleReport>[];
      final controller = _hookController(
        reports,
        _featureTasks(<String>[], <String, List<bool>>{}),
      );
      addTearDown(controller.dispose);

      await controller.awaitEntry(ClientSection.settings);
      await controller.awaitEntry(ClientSection.monitoring);
      expect(reports, isEmpty);
    },
  );

  test('disposal settles flights and rejects new work', () async {
    final gate = Completer<void>();
    var agentsCalls = 0;
    final reports = <ClientLifecycleReport>[];
    final controller = ClientInterfaceEntryHookController(
      tasks: {
        ClientSection.agents: ClientInterfaceEntryHookTask(
          section: ClientSection.agents,
          action: () async {
            agentsCalls += 1;
            await gate.future;
          },
        ),
      },
      onReport: reports.add,
    );

    controller.requestEntry(ClientSection.agents);
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    gate.complete();
    await controller.awaitEntry(ClientSection.agents);

    controller.requestEntry(ClientSection.agents);
    await Future<void>.delayed(Duration.zero);
    expect(agentsCalls, 1);
    expect(reports, isEmpty);
  });
}

const _featureSections = [
  ClientSection.agentHub,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
];

ClientInterfaceEntryHookController _hookController(
  List<ClientLifecycleReport> reports,
  Map<ClientSection, ClientInterfaceEntryHookTask> tasks,
) {
  return ClientInterfaceEntryHookController(
    tasks: tasks,
    onReport: reports.add,
  );
}

Map<ClientSection, ClientInterfaceEntryHookTask> _featureTasks(
  List<String> events,
  Map<String, List<bool>> backgrounds, {
  Map<String, Completer<void>>? gates,
  bool recordAfterGate = false,
}) {
  Future<void> Function() task(String name) => () async {
    final token = currentRpcPriorityToken();
    final observed = backgrounds.putIfAbsent(name, () => []);
    observed.add(token?.background ?? true);
    events.add('$name.start');
    final gate = gates?[name];
    if (gate != null) {
      await gate.future;
      if (recordAfterGate) {
        observed.add(currentRpcPriorityToken()?.background ?? true);
      }
    }
  };

  return {
    ClientSection.agentHub: ClientInterfaceEntryHookTask(
      section: ClientSection.agentHub,
      action: task('agentHub'),
    ),
    ClientSection.skillHub: ClientInterfaceEntryHookTask(
      section: ClientSection.skillHub,
      action: task('skillHub'),
    ),
    ClientSection.pluginManagement: ClientInterfaceEntryHookTask(
      section: ClientSection.pluginManagement,
      action: task('pluginManagement'),
    ),
  };
}
