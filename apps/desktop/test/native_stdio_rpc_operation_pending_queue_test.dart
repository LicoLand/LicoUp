import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

void main() {
  group('RpcOperationPendingQueue basic operations', () {
    test('enqueues and drains foreground items in FIFO order', () {
      final queue = RpcOperationPendingQueue<String>();
      queue.add('item-1');
      queue.add('item-2');
      queue.add('item-3');

      expect(queue.length, 3);
      expect(queue.foregroundCount, 3);
      expect(queue.backgroundCount, 0);

      expect(queue.takeNext(), 'item-1');
      expect(queue.takeNext(), 'item-2');
      expect(queue.takeNext(), 'item-3');
      expect(queue.isEmpty, isTrue);
    });

    test(
      'enqueues and drains background items in FIFO order when no foreground items exist',
      () {
        final queue = RpcOperationPendingQueue<String>();
        final bgToken = RpcPriorityToken(background: true);

        queue.add('bg-1', priority: bgToken);
        queue.add('bg-2', priority: bgToken);

        expect(queue.foregroundCount, 0);
        expect(queue.backgroundCount, 2);

        expect(queue.takeNext(), 'bg-1');
        expect(queue.takeNext(), 'bg-2');
        expect(queue.isEmpty, isTrue);
      },
    );

    test('O(1) cancellation unlinks entry and prevents execution', () {
      final queue = RpcOperationPendingQueue<String>();
      var cancelledCalled = false;

      final handle1 = queue.add('op-1', byteSize: 100);
      final handle2 = queue.add(
        'op-2',
        byteSize: 200,
        onCancelled: () => cancelledCalled = true,
      );
      final handle3 = queue.add('op-3', byteSize: 300);

      expect(queue.length, 3);
      expect(queue.totalPayloadBytes, 600);

      expect(handle2.isPending, isTrue);
      expect(handle2.isCancelled, isFalse);

      // Cancel handle2 in O(1)
      expect(handle2.cancel(), isTrue);
      expect(handle2.isPending, isFalse);
      expect(handle2.isCancelled, isTrue);
      expect(cancelledCalled, isTrue);

      // Repeated cancel returns false
      expect(handle2.cancel(), isFalse);

      // Queue state updated
      expect(queue.length, 2);
      expect(queue.totalPayloadBytes, 400);

      // Drain queue: op-2 is never yielded
      expect(queue.takeNext(), 'op-1');
      expect(queue.takeNext(), 'op-3');
      expect(queue.isEmpty, isTrue);

      // After take, handle1 is no longer pending and cannot be cancelled
      expect(handle1.isPending, isFalse);
      expect(handle1.cancel(), isFalse);
      expect(handle3.isPending, isFalse);
    });

    test('O(1) reprioritize moves entry between foreground and background', () {
      final queue = RpcOperationPendingQueue<String>();

      final handle = queue.add('item', byteSize: 50);
      expect(queue.foregroundCount, 1);
      expect(queue.backgroundCount, 0);

      // Move to background
      handle.reprioritize(background: true);
      expect(queue.foregroundCount, 0);
      expect(queue.backgroundCount, 1);
      expect(handle.isBackground, isTrue);

      // Move back to foreground
      handle.reprioritize(background: false);
      expect(queue.foregroundCount, 1);
      expect(queue.backgroundCount, 0);
      expect(handle.isBackground, isFalse);

      expect(queue.takeNext(), 'item');
    });
  });

  group('Dynamic token notification (O(k) for k handles)', () {
    test('flipping token.background notifies all k bound handles', () {
      final queue = RpcOperationPendingQueue<String>();
      final token = RpcPriorityToken(background: true);

      // Enqueue k items sharing the same background token
      final k = 5;
      final handles = List.generate(k, (i) {
        return queue.add('task-$i', priority: token);
      });

      expect(queue.backgroundCount, k);
      expect(queue.foregroundCount, 0);

      // Also enqueue an ordinary foreground task
      queue.add('fg-task');
      expect(queue.foregroundCount, 1);

      // Flip the token to foreground: all k handles are notified and boosted
      token.background = false;

      expect(queue.backgroundCount, 0);
      expect(queue.foregroundCount, k + 1);
      for (final handle in handles) {
        expect(handle.isBackground, isFalse);
      }

      // Tasks enqueued earlier with token precede fg-task
      for (var i = 0; i < k; i++) {
        expect(queue.takeNext(), 'task-$i');
      }
      expect(queue.takeNext(), 'fg-task');
    });

    test('demoting token.background moves handles to background FIFO', () {
      final queue = RpcOperationPendingQueue<String>();
      final token = RpcPriorityToken(background: false);

      final h1 = queue.add('t1', priority: token);
      final h2 = queue.add('t2', priority: token);
      queue.add('regular-fg');

      expect(queue.foregroundCount, 3);
      expect(queue.backgroundCount, 0);

      // Demote to background
      token.background = true;

      expect(queue.foregroundCount, 1);
      expect(queue.backgroundCount, 2);
      expect(h1.isBackground, isTrue);
      expect(h2.isBackground, isTrue);

      // regular-fg runs before the demoted background tasks
      expect(queue.takeNext(), 'regular-fg');
      expect(queue.takeNext(), 't1');
      expect(queue.takeNext(), 't2');
    });

    test('listeners are cleaned up when entry is drained or cancelled', () {
      final queue = RpcOperationPendingQueue<String>();
      final token = RpcPriorityToken(background: true);

      final h1 = queue.add('op-1', priority: token);
      final h2 = queue.add('op-2', priority: token);

      // Drain h1
      expect(queue.takeNext(), 'op-1');
      expect(h1.isPending, isFalse);

      // Cancel h2
      expect(h2.cancel(), isTrue);
      expect(h2.isCancelled, isTrue);

      // Mutating token afterwards should have zero effect on queue state
      token.background = false;
      expect(queue.isEmpty, isTrue);
      expect(queue.foregroundCount, 0);
      expect(queue.backgroundCount, 0);
      expect(h1.isBackground, isTrue);
      expect(h2.isBackground, isTrue);
    });
  });

  group('Bounded batching and starvation prevention', () {
    test(
      'continuous foreground arrivals rotate to background after batch limit',
      () {
        // Create queue with foregroundBatchLimit = 3
        final queue = RpcOperationPendingQueue<String>(foregroundBatchLimit: 3);
        final bgToken = RpcPriorityToken(background: true);

        // Add 2 background operations
        queue.add('bg-1', priority: bgToken);
        queue.add('bg-2', priority: bgToken);

        // Add 8 foreground operations
        for (var i = 0; i < 8; i++) {
          queue.add('fg-$i');
        }

        final drained = <String>[];
        while (queue.isNotEmpty) {
          drained.add(queue.takeNext());
        }

        // Expected pattern: 3 foreground, 1 background, 3 foreground, 1 background, remaining foreground
        expect(drained, [
          'fg-0',
          'fg-1',
          'fg-2',
          'bg-1', // Rotated after 3 consecutive foregrounds
          'fg-3',
          'fg-4',
          'fg-5',
          'bg-2', // Rotated after 3 consecutive foregrounds
          'fg-6',
          'fg-7',
        ]);
      },
    );

    test('foreground runs unconstrained when background is empty', () {
      final queue = RpcOperationPendingQueue<String>(foregroundBatchLimit: 2);

      for (var i = 0; i < 6; i++) {
        queue.add('fg-$i');
      }

      final drained = <String>[];
      while (queue.isNotEmpty) {
        drained.add(queue.takeNext());
      }

      expect(drained, ['fg-0', 'fg-1', 'fg-2', 'fg-3', 'fg-4', 'fg-5']);
    });
  });

  group('Backpressure and payload byte bounds', () {
    test(
      'tracks total payload bytes and flags backpressure when bound is reached',
      () {
        const maxBytes = 16 * 1024 * 1024; // 16 MiB bound
        final queue = RpcOperationPendingQueue<String>(
          maxPendingBytes: maxBytes,
        );

        expect(queue.hasBackpressure, isFalse);

        // Add 10 MiB payload
        queue.add('op-1', byteSize: 10 * 1024 * 1024);
        expect(queue.totalPayloadBytes, 10 * 1024 * 1024);
        expect(queue.hasBackpressure, isFalse);

        // Add another 7 MiB payload -> 17 MiB > 16 MiB bound
        final h2 = queue.add('op-2', byteSize: 7 * 1024 * 1024);
        expect(queue.totalPayloadBytes, 17 * 1024 * 1024);
        expect(queue.hasBackpressure, isTrue);

        // Taking op-1 (10 MiB) reduces total to 7 MiB, clearing backpressure
        final taken = queue.takeNext();
        expect(taken, 'op-1');
        expect(queue.totalPayloadBytes, 7 * 1024 * 1024);
        expect(queue.hasBackpressure, isFalse);

        // Cancel h2 reduces total to 0
        h2.cancel();
        expect(queue.totalPayloadBytes, 0);
        expect(queue.isEmpty, isTrue);
      },
    );

    test('maxPendingCount bounds entry count and triggers backpressure', () {
      final queue = RpcOperationPendingQueue<String>(maxPendingCount: 2);

      queue.add('item-1');
      expect(queue.hasBackpressure, isFalse);

      final h2 = queue.add('item-2');
      expect(queue.hasBackpressure, isTrue);

      h2.cancel();
      expect(queue.hasBackpressure, isFalse);
    });

    test('enforces parameter assertions on construction and enqueue', () {
      expect(
        () => RpcOperationPendingQueue<String>(foregroundBatchLimit: 0),
        throwsA(isA<AssertionError>()),
      );
      final queue = RpcOperationPendingQueue<String>();
      expect(
        () => queue.add('bad', byteSize: -1),
        throwsA(isA<AssertionError>()),
      );
      final fifo = RpcFifoQueue<String>();
      expect(
        () => fifo.add('bad', byteSize: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('RpcFifoQueue (standard ListQueue implementation)', () {
    test('provides FIFO ordering with byte tracking and backpressure', () {
      final queue = RpcFifoQueue<String>(maxPendingBytes: 1000);

      queue.add('first', byteSize: 400);
      queue.add('second', byteSize: 700);

      expect(queue.length, 2);
      expect(queue.totalPayloadBytes, 1100);
      expect(queue.hasBackpressure, isTrue);

      expect(queue.takeNext(), 'first');
      expect(queue.totalPayloadBytes, 700);
      expect(queue.hasBackpressure, isFalse);

      expect(queue.takeNext(), 'second');
      expect(queue.isEmpty, isTrue);
      expect(queue.totalPayloadBytes, 0);
    });
  });
}
