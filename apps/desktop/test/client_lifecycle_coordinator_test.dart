import 'dart:async';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projection is an immutable snapshot of authoritative state', () async {
    final controller = ClientLifecycleCoordinator(onReport: (_) {});
    addTearDown(controller.dispose);

    final idle = controller.projection;
    expect(idle.phase, ClientLifecyclePhase.idle);
    expect(idle.initialized, isFalse);
    expect(idle.disposed, isFalse);

    await controller.initialize(sequentialSteps: const []);

    expect(idle.phase, ClientLifecyclePhase.idle);
    expect(controller.projection, isNot(same(idle)));
    expect(controller.projection.phase, ClientLifecyclePhase.ready);
    expect(controller.projection.initialized, isTrue);
    expect(controller.projection.disposed, isFalse);
  });

  test(
    'initialization is single-flight and preserves sequential order',
    () async {
      final calls = <String>[];
      final phases = <ClientLifecyclePhase>[];
      final gate = Completer<void>();
      final controller = ClientLifecycleCoordinator(onReport: (_) {});
      addTearDown(controller.dispose);
      controller.addListener(() => phases.add(controller.projection.phase));
      final steps = [
        ClientBootstrapStep(
          id: 'first',
          action: () async {
            calls.add('first');
            await gate.future;
          },
        ),
        ClientBootstrapStep(
          id: 'second',
          action: () async => calls.add('second'),
        ),
      ];

      final first = controller.initialize(sequentialSteps: steps);
      final second = controller.initialize(sequentialSteps: steps);
      expect(identical(first, second), isTrue);
      expect(calls, ['first']);

      gate.complete();
      await first;
      expect(calls, ['first', 'second']);
      expect(controller.projection.phase, ClientLifecyclePhase.ready);
      expect(phases, [
        ClientLifecyclePhase.initializing,
        ClientLifecyclePhase.ready,
      ]);
    },
  );

  test(
    'initialization after ready is idempotent and performs no work',
    () async {
      var calls = 0;
      final controller = ClientLifecycleCoordinator(onReport: (_) {});
      addTearDown(controller.dispose);

      await controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(id: 'first', action: () async => calls += 1),
        ],
      );
      final ready = controller.projection;

      await controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(
            id: 'must_not_run',
            action: () async => calls += 1,
          ),
        ],
      );

      expect(calls, 1);
      expect(controller.projection.phase, ClientLifecyclePhase.ready);
      expect(controller.projection.initialized, isTrue);
      expect(ready.phase, ClientLifecyclePhase.ready);
    },
  );

  test('background steps run concurrently and mobile can skip them', () async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    var started = 0;
    final controller = ClientLifecycleCoordinator(onReport: (_) {});
    addTearDown(controller.dispose);
    final future = controller.initialize(
      sequentialSteps: const [],
      backgroundSteps: [
        ClientBootstrapStep(
          id: 'first',
          action: () {
            started += 1;
            return firstGate.future;
          },
        ),
        ClientBootstrapStep(
          id: 'second',
          action: () {
            started += 1;
            return secondGate.future;
          },
        ),
      ],
    );
    await Future<void>.delayed(Duration.zero);
    expect(started, 2);
    firstGate.complete();
    secondGate.complete();
    await future;

    final mobile = ClientLifecycleCoordinator(onReport: (_) {});
    addTearDown(mobile.dispose);
    var mobileBackgroundCalls = 0;
    await mobile.initialize(
      sequentialSteps: const [],
      backgroundSteps: [
        ClientBootstrapStep(
          id: 'desktop_only',
          action: () async => mobileBackgroundCalls += 1,
        ),
      ],
      runBackgroundSteps: false,
    );
    expect(mobileBackgroundCalls, 0);
  });

  test(
    'failure reports bounded evidence and a later initialize retries',
    () async {
      final reports = <ClientLifecycleReport>[];
      final controller = ClientLifecycleCoordinator(onReport: reports.add);
      addTearDown(controller.dispose);
      var attempts = 0;

      await controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(
            id: 'private/path',
            action: () async {
              attempts += 1;
              throw StateError('private runtime detail');
            },
          ),
        ],
      );

      expect(controller.projection.phase, ClientLifecyclePhase.failed);
      expect(controller.projection.initialized, isFalse);
      expect(reports.single.code, 'client_initialize_failed');
      expect(reports.single.stepId, 'unknown_background_step');
      expect(controller.lastFailureStepId, 'unknown_background_step');
      expect(reports.toString(), isNot(contains('private runtime detail')));

      await controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(id: 'retry', action: () async => attempts += 1),
        ],
      );

      expect(attempts, 2);
      expect(controller.projection.phase, ClientLifecyclePhase.ready);
      expect(controller.projection.initialized, isTrue);
    },
  );

  test('finalization runs once after every background step settles', () async {
    final calls = <String>[];
    final controller = ClientLifecycleCoordinator(onReport: (_) {});
    addTearDown(controller.dispose);

    await controller.initialize(
      sequentialSteps: [
        ClientBootstrapStep(id: 'core', action: () async => calls.add('core')),
      ],
      backgroundSteps: [
        ClientBootstrapStep(
          id: 'background',
          action: () async => calls.add('background'),
        ),
      ],
      finalStep: ClientBootstrapStep(
        id: 'finalize',
        action: () async => calls.add('finalize'),
      ),
    );
    await controller.initialize(sequentialSteps: const []);

    expect(calls, ['core', 'background', 'finalize']);
  });

  test(
    'dispose during initialization rejects stale ready completion',
    () async {
      final gate = Completer<void>();
      var trailingCalls = 0;
      final controller = ClientLifecycleCoordinator(onReport: (_) {});
      final initializing = controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(id: 'pending', action: () => gate.future),
          ClientBootstrapStep(
            id: 'stale_trailing_step',
            action: () async => trailingCalls += 1,
          ),
        ],
      );
      expect(controller.projection.phase, ClientLifecyclePhase.initializing);

      controller.dispose();
      final disposed = controller.projection;
      expect(disposed.phase, ClientLifecyclePhase.disposed);
      expect(disposed.disposed, isTrue);

      gate.complete();
      await initializing;

      expect(trailingCalls, 0);
      expect(controller.projection.phase, ClientLifecyclePhase.disposed);
      expect(disposed.phase, ClientLifecyclePhase.disposed);
    },
  );

  test(
    'initialize after disposal reports a typed rejection and performs no work',
    () async {
      final reports = <ClientLifecycleReport>[];
      var calls = 0;
      final controller = ClientLifecycleCoordinator(onReport: reports.add);
      controller.dispose();

      await controller.initialize(
        sequentialSteps: [
          ClientBootstrapStep(
            id: 'must_not_run',
            action: () async => calls += 1,
          ),
        ],
      );

      expect(calls, 0);
      expect(controller.projection.phase, ClientLifecyclePhase.disposed);
      expect(
        reports,
        hasLength(1),
        reason: 'an illegal disposed-to-initializing transition is observable',
      );
      expect(reports.single.code, 'client_lifecycle_disposed');
      expect(reports.single.stepId, 'initialize');
    },
  );

  test(
    'illegal transition table rejects forbidden edges without mutation',
    () async {
      const forbiddenEdges = [
        (
          from: ClientLifecyclePhase.ready,
          to: ClientLifecyclePhase.initializing,
          stepId: 'ready_to_initializing',
        ),
        (
          from: ClientLifecyclePhase.ready,
          to: ClientLifecyclePhase.failed,
          stepId: 'ready_to_failed',
        ),
        (
          from: ClientLifecyclePhase.disposed,
          to: ClientLifecyclePhase.initializing,
          stepId: 'disposed_to_initializing',
        ),
        (
          from: ClientLifecyclePhase.disposed,
          to: ClientLifecyclePhase.ready,
          stepId: 'disposed_to_ready',
        ),
      ];

      for (final edge in forbiddenEdges) {
        final reports = <ClientLifecycleReport>[];
        final controller = ClientLifecycleCoordinator(onReport: reports.add);
        var notifications = 0;
        controller.addListener(() => notifications += 1);
        if (edge.from == ClientLifecyclePhase.ready) {
          await controller.initialize(sequentialSteps: const []);
        } else {
          controller.dispose();
        }
        expect(controller.projection.phase, edge.from);

        notifications = 0;
        final before = controller.projection;
        final rejection = controller.transitionForTesting(
          edge.to,
          stepId: edge.stepId,
        );

        expect(rejection, isA<ClientLifecycleReport>());
        expect(rejection.code, 'client_lifecycle_transition_invalid');
        expect(rejection.stepId, edge.stepId);
        expect(reports, hasLength(1));
        expect(reports.single.code, rejection.code);
        expect(reports.single.stepId, rejection.stepId);
        expect(controller.projection, same(before));
        expect(controller.projection.phase, edge.from);
        expect(notifications, 0);

        controller.dispose();
      }
    },
  );

  test(
    'repeated shutdown is idempotent and does not notify after disposal',
    () {
      final controller = ClientLifecycleCoordinator(onReport: (_) {});
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      controller.dispose();
      final afterFirst = controller.projection;
      final notificationsAfterFirst = notifications;
      expect(afterFirst.phase, ClientLifecyclePhase.disposed);

      expect(controller.dispose, returnsNormally);
      expect(controller.projection.phase, ClientLifecyclePhase.disposed);
      expect(controller.projection.disposed, isTrue);
      expect(notifications, notificationsAfterFirst);
    },
  );
}
