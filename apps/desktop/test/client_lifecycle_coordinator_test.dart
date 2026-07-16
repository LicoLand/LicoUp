import 'dart:async';

import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'initialization is single-flight and preserves sequential order',
    () async {
      final calls = <String>[];
      final gate = Completer<void>();
      final controller = ClientLifecycleCoordinator(onReport: (_) {});
      addTearDown(controller.dispose);
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
      expect(controller.phase, ClientLifecyclePhase.ready);
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

  test('failures report stable evidence without raw exception text', () async {
    final reports = <ClientLifecycleReport>[];
    final controller = ClientLifecycleCoordinator(onReport: reports.add);
    addTearDown(controller.dispose);

    await controller.initialize(
      sequentialSteps: [
        ClientBootstrapStep(
          id: 'private/path',
          action: () async => throw StateError('private runtime detail'),
        ),
      ],
    );

    expect(controller.phase, ClientLifecyclePhase.failed);
    expect(reports.single.code, 'client_initialize_failed');
    expect(reports.single.stepId, 'sequential_bootstrap');
    expect(reports.toString(), isNot(contains('private runtime detail')));
  });

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
}
