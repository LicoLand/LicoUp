import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/state/application_signal.dart';

final class _Owner extends ApplicationStateOwner {
  void mutate({ApplicationCause? cause}) => publishChange(cause);
}

void main() {
  test('zero-subscriber publication is a no-op for delivery', () {
    final owner = _Owner();
    expect(() => owner.mutate(), returnsNormally);
    owner.dispose();
  });

  test('publishes synchronously in subscriber order with optional cause', () {
    final owner = _Owner();
    final events = <String>[];
    final first = owner.changes.listen(
      (change) => events.add('first:${change.cause?.traceId ?? '-'}'),
    );
    final second = owner.changes.listen(
      (change) => events.add('second:${change.cause?.traceId ?? '-'}'),
    );

    owner.mutate(cause: const ApplicationCause(traceId: 'trace-a'));
    expect(events, ['first:trace-a', 'second:trace-a']);

    first.cancel();
    owner.mutate();
    expect(events, ['first:trace-a', 'second:trace-a', 'second:-']);
    second.cancel();
  });

  test(
    'cancellation and repeated disposal suppress later publication',
    () async {
      final owner = _Owner();
      var count = 0;
      var closes = 0;
      final subscription = owner.changes.listen(
        (_) => count += 1,
        onDone: () => closes += 1,
      );
      owner.mutate();
      owner.dispose();
      owner.dispose();
      owner.mutate();
      await Future<void>.delayed(Duration.zero);
      expect(count, 1);
      expect(closes, 1);
      expect(owner.applicationStateDisposed, isTrue);
      await subscription.cancel();
    },
  );
}
