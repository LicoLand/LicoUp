import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';

void main() {
  testWidgets('projection builder selects slices and swaps sources', (
    tester,
  ) async {
    final first = _ProjectionSource(const _Projection(1, 'a'));
    final second = _ProjectionSource(const _Projection(3, 'b'));
    final telemetry = _ProjectionObserver();
    var source = first;
    late StateSetter rebuild;
    var builds = 0;

    await tester.pumpWidget(
      ProjectionTelemetryScope(
        observer: telemetry,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ProjectionBuilder<_Projection, int>(
                source: source,
                select: (projection) => projection.selected,
                builder: (context, selected) {
                  builds += 1;
                  return Text('$selected');
                },
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('1'), findsOneWidget);

    first.publish(const _Projection(1, 'unrelated'));
    await tester.pump();
    expect(builds, 1);

    first.publish(
      const _Projection(2, 'changed'),
      trace: const TraceContext(traceId: 'trace-selected'),
    );
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    expect(telemetry.traces, ['trace-selected']);
    expect(telemetry.consumedTraces, ['trace-selected']);

    rebuild(() => source = second);
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(first.hasListener, isFalse);

    await tester.pumpWidget(const SizedBox());
    expect(second.hasListener, isFalse);
    await first.dispose();
    await second.dispose();
  });

  testWidgets('effect listener delivers non-replayed effects once', (
    tester,
  ) async {
    final source = _EffectSource();
    final received = <String>[];
    await tester.pumpWidget(
      EffectListener<String>(
        source: source,
        onEffect: received.add,
        child: const SizedBox(),
      ),
    );

    source.emit('one');
    expect(received, <String>['one']);
    await tester.pumpWidget(const SizedBox());
    source.emit('two');
    expect(received, <String>['one']);
    await source.dispose();
  });
}

final class _Projection {
  const _Projection(this.selected, this.unrelated);

  final int selected;
  final String unrelated;
}

final class _ProjectionSource implements ProjectionSource<_Projection> {
  _ProjectionSource(this._current);

  final StreamController<ProjectionUpdate<_Projection>> _controller =
      StreamController<ProjectionUpdate<_Projection>>.broadcast(sync: true);
  _Projection _current;
  bool get hasListener => _controller.hasListener;

  @override
  _Projection get current => _current;

  @override
  Stream<ProjectionUpdate<_Projection>> get changes => _controller.stream;

  void publish(_Projection value, {TraceContext? trace}) {
    _current = value;
    _controller.add(ProjectionUpdate(value, trace: trace));
  }

  Future<void> dispose() => _controller.close();
}

final class _ProjectionObserver implements ProjectionReceiptObserver {
  final List<String?> traces = [];
  final List<String?> consumedTraces = [];

  @override
  TraceContext projectionReceived(TraceContext? trace) {
    final resolved = trace ?? const TraceContext(traceId: 'runtime-trace');
    traces.add(resolved.traceId);
    return resolved;
  }

  @override
  void projectionFrameConsumed(
    TraceContext trace, {
    required int frameBuildStartMicroseconds,
  }) {
    consumedTraces.add(trace.traceId);
  }
}

final class _EffectSource implements EffectSource<String> {
  final StreamController<String> _controller =
      StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get effects => _controller.stream;

  void emit(String effect) => _controller.add(effect);

  Future<void> dispose() => _controller.close();
}
