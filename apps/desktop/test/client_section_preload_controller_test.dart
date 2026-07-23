import 'dart:async';

import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_client/src/application/features/navigation/controller/client_section_preload_controller.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/platform/native_client/native_rpc_priority.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs tasks sequentially with the current section first', () async {
    final events = <String>[];
    Future<void> task(String id) async {
      events.add('$id:start');
      await Future<void>.delayed(Duration.zero);
      events.add('$id:end');
    }

    final controller = ClientSectionPreloadController(
      currentSection: () => ClientSection.monitoring,
      interTaskDelay: Duration.zero,
      tasks: {
        ClientSection.agents: () => task('agents'),
        ClientSection.monitoring: () => task('monitoring'),
        ClientSection.skillHub: () => task('skillHub'),
      },
      onReport: (_) {},
    );
    addTearDown(controller.dispose);

    controller.start();
    await Future.wait([
      controller.awaitSection(ClientSection.agents),
      controller.awaitSection(ClientSection.monitoring),
      controller.awaitSection(ClientSection.skillHub),
    ]);

    expect(events, [
      'monitoring:start',
      'monitoring:end',
      'agents:start',
      'agents:end',
      'skillHub:start',
      'skillHub:end',
    ]);
  });

  test('background tasks carry a background priority token', () async {
    final seen = <bool>[];
    final controller = ClientSectionPreloadController(
      currentSection: () => ClientSection.agents,
      interTaskDelay: Duration.zero,
      tasks: {
        ClientSection.agents: () async {
          seen.add(currentRpcPriorityToken()?.background ?? false);
        },
      },
      onReport: (_) {},
    );
    addTearDown(controller.dispose);

    controller.start();
    await controller.awaitSection(ClientSection.agents);

    expect(seen, [true]);
  });

  test(
    'prioritizeSection runs a pending task immediately in foreground',
    () async {
      final firstTaskGate = Completer<void>();
      final boostedRan = Completer<bool>();
      final controller = ClientSectionPreloadController(
        currentSection: () => ClientSection.agents,
        interTaskDelay: Duration.zero,
        tasks: {
          ClientSection.agents: () => firstTaskGate.future,
          ClientSection.skillHub: () async {
            boostedRan.complete(currentRpcPriorityToken()?.background ?? true);
          },
        },
        onReport: (_) {},
      );
      addTearDown(controller.dispose);

      controller.start();
      controller.prioritizeSection(ClientSection.skillHub);

      expect(await boostedRan.future, isFalse);

      firstTaskGate.complete();
      await controller.awaitSection(ClientSection.agents);
    },
  );

  test('prioritizeSection boosts an in-flight background task', () async {
    final taskEntered = Completer<RpcPriorityToken>();
    final releaseTask = Completer<void>();
    final controller = ClientSectionPreloadController(
      currentSection: () => ClientSection.agents,
      interTaskDelay: Duration.zero,
      tasks: {
        ClientSection.agents: () async {
          taskEntered.complete(currentRpcPriorityToken());
          await releaseTask.future;
        },
      },
      onReport: (_) {},
    );
    addTearDown(controller.dispose);

    controller.start();
    final token = await taskEntered.future;
    expect(token.background, isTrue);

    controller.prioritizeSection(ClientSection.agents);
    expect(token.background, isFalse);

    releaseTask.complete();
    await controller.awaitSection(ClientSection.agents);
  });

  test(
    'failures report a stable step id and do not stop later tasks',
    () async {
      final reports = <ClientLifecycleReport>[];
      final laterRan = Completer<void>();
      final controller = ClientSectionPreloadController(
        currentSection: () => ClientSection.agents,
        interTaskDelay: Duration.zero,
        tasks: {
          ClientSection.agents: () async => throw StateError('boom'),
          ClientSection.monitoring: () async => laterRan.complete(),
        },
        onReport: reports.add,
      );
      addTearDown(controller.dispose);

      controller.start();
      await controller.awaitSection(ClientSection.agents);
      await controller.awaitSection(ClientSection.monitoring);
      await laterRan.future;

      expect(reports, hasLength(1));
      expect(reports.single.code, 'client_section_preload_failed');
      expect(reports.single.stepId, 'agents');
    },
  );

  test('dispose stops tasks that have not started yet', () async {
    final firstTaskGate = Completer<void>();
    var laterRan = false;
    final controller = ClientSectionPreloadController(
      currentSection: () => ClientSection.agents,
      interTaskDelay: Duration.zero,
      tasks: {
        ClientSection.agents: () => firstTaskGate.future,
        ClientSection.monitoring: () async {
          laterRan = true;
        },
      },
      onReport: (_) {},
    );

    controller.start();
    controller.dispose();
    firstTaskGate.complete();
    await controller.awaitSection(ClientSection.agents);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(laterRan, isFalse);
  });

  test(
    'start is single-flight and prioritize is a no-op before start',
    () async {
      var runs = 0;
      final controller = ClientSectionPreloadController(
        currentSection: () => ClientSection.agents,
        interTaskDelay: Duration.zero,
        tasks: {
          ClientSection.agents: () async {
            runs += 1;
          },
        },
        onReport: (_) {},
      );
      addTearDown(controller.dispose);

      controller.prioritizeSection(ClientSection.agents);
      expect(runs, 0);

      controller.start();
      controller.start();
      await controller.awaitSection(ClientSection.agents);

      expect(runs, 1);
    },
  );
}
