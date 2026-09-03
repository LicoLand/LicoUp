import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

final class _Projection implements ProjectionSource<int> {
  @override
  int current = 7;

  @override
  Stream<int> get changes => const Stream<int>.empty();
}

final class _Effects implements EffectSource<String> {
  @override
  Stream<String> get effects => Stream<String>.fromIterable(<String>['shown']);
}

final class _Intents implements IntentSink<String> {
  final sent = <String>[];

  @override
  void send(String intent) => sent.add(intent);
}

void main() {
  test('contract exposes only directional renderer primitives', () async {
    final projection = _Projection();
    final effects = _Effects();
    final intents = _Intents();

    expect(projection.current, 7);
    expect(await projection.changes.toList(), isEmpty);
    expect(await effects.effects.toList(), <String>['shown']);
    intents.send('select');
    expect(intents.sent, <String>['select']);
  });

  test('trace context has minimal value equality', () {
    expect(const TraceContext(), const TraceContext());
    expect(
      const TraceContext(traceId: 'trace-a'),
      const TraceContext(traceId: 'trace-a'),
    );
    expect(
      const TraceContext(traceId: 'trace-a'),
      isNot(const TraceContext(traceId: 'trace-b')),
    );
  });
}
