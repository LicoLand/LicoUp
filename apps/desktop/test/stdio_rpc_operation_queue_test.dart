import 'dart:async';

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

  test('conversation stream occupies the queue until it closes', () async {
    final queue = StdioRpcOperationQueue();
    final order = <String>[];

    final stream = queue.serializeStream<String>(
      operation: () => Stream.fromIterable(const ['a', 'b']),
      timeout: const Duration(seconds: 5),
      onTimeout: () async {},
    );
    final after = queue.serialize(() async {
      order.add('after');
    });

    final events = await stream.toList();
    await after;

    expect(events, ['a', 'b']);
    expect(order, ['after']);
  });
}
