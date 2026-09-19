import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_queue.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'foreground operations overtake pending background operations',
    () async {
      final queue = StdioRpcOperationQueue();
      final gate = Completer<void>();
      final order = <String>[];

      final inFlight = queue.serialize(() async {
        order.add('first');
        await gate.future;
      });
      final background = queue.serialize(() async {
        order.add('background');
      }, priority: RpcPriorityToken(background: true));
      final foreground = queue.serialize(() async {
        order.add('foreground');
      });

      gate.complete();
      await Future.wait([inFlight, background, foreground]);

      expect(order, ['first', 'foreground', 'background']);
    },
  );

  test('same priority operations keep FIFO order', () async {
    final queue = StdioRpcOperationQueue();
    final gate = Completer<void>();
    final order = <String>[];

    final inFlight = queue.serialize(() => gate.future);
    final first = queue.serialize(() async {
      order.add('first-background');
    }, priority: RpcPriorityToken(background: true));
    final second = queue.serialize(() async {
      order.add('second-background');
    }, priority: RpcPriorityToken(background: true));
    final third = queue.serialize(() async {
      order.add('third-foreground');
    });
    final fourth = queue.serialize(() async {
      order.add('fourth-foreground');
    });

    gate.complete();
    await Future.wait([inFlight, first, second, third, fourth]);

    expect(order, [
      'third-foreground',
      'fourth-foreground',
      'first-background',
      'second-background',
    ]);
  });

  test('flipping a token boosts its pending background operation', () async {
    final queue = StdioRpcOperationQueue();
    final gate = Completer<void>();
    final order = <String>[];

    final inFlight = queue.serialize(() => gate.future);
    final boostToken = RpcPriorityToken(background: true);
    final boosted = queue.serialize(() async {
      order.add('boosted');
    }, priority: boostToken);
    final foreground = queue.serialize(() async {
      order.add('foreground');
    });

    boostToken.background = false;
    gate.complete();
    await Future.wait([inFlight, boosted, foreground]);

    expect(order, ['boosted', 'foreground']);
  });

  test(
    'operation failures reach the caller without breaking the queue',
    () async {
      final queue = StdioRpcOperationQueue();
      final order = <String>[];

      final failing = queue.serialize<String>(() async {
        throw StateError('boom');
      });
      final after = queue.serialize(() async {
        order.add('after');
      });

      await expectLater(failing, throwsStateError);
      await after;
      expect(order, ['after']);
    },
  );

  test(
    'close rejects new work, drains pending, and swallows shutdown errors',
    () async {
      final queue = StdioRpcOperationQueue();
      final gate = Completer<void>();
      final order = <String>[];

      final pending = queue.serialize(() async {
        order.add('pending');
        await gate.future;
      });
      final closed = queue.close(() async {
        order.add('shutdown');
        throw StateError('shutdown boom');
      });

      await expectLater(
        queue.serialize(() async {}),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'service_disposed',
          ),
        ),
      );

      gate.complete();
      await Future.wait([pending, closed]);
      expect(order, ['pending', 'shutdown']);
      expect(identical(queue.close(() async {}), closed), isTrue);
    },
  );

  test(
    'detach releases the observer without waiting for active work',
    () async {
      final queue = StdioRpcOperationQueue();
      final gate = Completer<void>();
      final active = queue.serialize(() => gate.future);
      var detached = false;

      await queue.detach(() async {
        detached = true;
      });

      expect(detached, isTrue);
      expect(gate.isCompleted, isFalse);
      await expectLater(
        queue.serialize(() async {}),
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'service_disposed',
          ),
        ),
      );

      gate.complete();
      await active;
    },
  );

  test(
    'cancelling a pending operation via handle completes with cancelled and skips execution',
    () async {
      final queue = StdioRpcOperationQueue();
      final gate = Completer<void>();
      final executed = <String>[];

      final inFlight = queue.serialize(() async {
        executed.add('in-flight');
        await gate.future;
      });

      RpcPendingEntryHandle<RpcOp<void>>? cancellableHandle;
      final cancelledOp = queue.serialize(() async {
        executed.add('should-not-run');
      }, onEnqueued: (handle) => cancellableHandle = handle);

      final afterOp = queue.serialize(() async {
        executed.add('after');
      });

      expect(cancellableHandle, isNotNull);
      expect(cancellableHandle!.isPending, isTrue);
      expect(cancellableHandle!.cancel(), isTrue);
      expect(cancellableHandle!.isCancelled, isTrue);
      expect(cancellableHandle!.cancel(), isFalse); // Second cancel is no-op

      await expectLater(
        cancelledOp,
        throwsA(
          isA<LicoClientRpcException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );

      gate.complete();
      await Future.wait([inFlight, afterOp]);

      expect(executed, ['in-flight', 'after']);
    },
  );

  test(
    'continuous foreground operations yield to background after bounded batch limit',
    () async {
      final queue = StdioRpcOperationQueue();
      final gate = Completer<void>();
      final executionOrder = <String>[];

      // Hold the queue while we enqueue batch of foreground and one background
      final inFlight = queue.serialize(() => gate.future);

      // Queue one background operation
      final bgOp = queue.serialize(() async {
        executionOrder.add('bg');
      }, priority: RpcPriorityToken(background: true));

      // Queue 10 foreground operations (batch limit is 8)
      final fgOps = List.generate(10, (i) {
        return queue.serialize(() async {
          executionOrder.add('fg-$i');
        });
      });

      gate.complete();
      await Future.wait([inFlight, bgOp, ...fgOps]);

      // After 8 foreground operations, bounded batch rotation must execute 'bg'
      // before the remaining foreground operations.
      expect(executionOrder.sublist(0, 8), [
        'fg-0',
        'fg-1',
        'fg-2',
        'fg-3',
        'fg-4',
        'fg-5',
        'fg-6',
        'fg-7',
      ]);
      expect(executionOrder[8], 'bg');
      expect(executionOrder.sublist(9), ['fg-8', 'fg-9']);
    },
  );

  test('queue tracks pending payload bytes and count', () async {
    final queue = StdioRpcOperationQueue();
    final gate = Completer<void>();

    expect(queue.pendingCount, 0);
    expect(queue.pendingPayloadBytes, 0);

    final inFlight = queue.serialize(() => gate.future, byteSize: 512);
    expect(queue.pendingCount, 0); // Already running, not pending

    RpcPendingEntryHandle<RpcOp<void>>? handle;
    final pending = queue.serialize(
      () async => 'ok',
      byteSize: 2048,
      onEnqueued: (h) => handle = h,
    );

    expect(queue.pendingCount, 1);
    expect(queue.pendingPayloadBytes, 2048);
    expect(handle?.byteSize, 2048);
    expect(handle?.isPending, isTrue);

    gate.complete();
    await inFlight;
    await pending;

    expect(queue.pendingCount, 0);
    expect(queue.pendingPayloadBytes, 0);
  });
}
