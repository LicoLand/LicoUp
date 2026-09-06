import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/causal_frame_telemetry.dart';
import 'package:licoup/src/frontend/binding/causal_projection_source_registry.dart';

void main() {
  test(
    'keeps renderer cause isolated and closes all consumed traces per frame',
    () {
      var now = 0;
      var nextId = 0;
      final completed = <CausalTraceMeasurement>[];
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 8,
        sampleLimit: 8,
        clock: () => now,
        traceIdFactory: () => 'trace-${nextId++}',
        sink: completed.add,
      );

      final renderer = telemetry.beginRendererIntent();
      now = 10;
      telemetry.projectionEmitted(trace: renderer);
      now = 12;
      telemetry.flutterReceived(renderer);

      now = 20;
      final runtime = telemetry.projectionEmitted();
      now = 23;
      telemetry.flutterReceived(runtime);

      now = 30;
      telemetry.frameRendered(
        buildMicroseconds: 3,
        rasterMicroseconds: 5,
        totalFrameMicroseconds: 9,
      );

      expect(completed, hasLength(2));
      expect(completed.first.origin, CausalTraceOrigin.rendererIntent);
      expect(completed.first.intentOrRuntimeToProjectionMicroseconds, 10);
      expect(completed.first.projectionToFrameMicroseconds, 20);
      expect(completed.last.origin, CausalTraceOrigin.runtime);
      expect(completed.last.intentOrRuntimeToProjectionMicroseconds, 0);
      expect(completed.last.projectionToFrameMicroseconds, 10);
      expect(completed.map((value) => value.coalescedTraceCount), [2, 2]);
      expect(telemetry.pendingCount, 0);
    },
  );

  test(
    'unmatched traces stay bounded and summaries use nearest-rank percentiles',
    () {
      var now = 0;
      var nextId = 0;
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 2,
        sampleLimit: 3,
        clock: () => now,
        traceIdFactory: () => 'trace-${nextId++}',
      );

      telemetry.beginRendererIntent();
      telemetry.beginRendererIntent();
      telemetry.beginRendererIntent();
      expect(telemetry.pendingCount, 2);
      expect(telemetry.evictedCount, 1);
      expect(telemetry.summarize().unavailableCounts, {
        CausalTelemetryUnavailableReason.capacityEvicted: 1,
      });

      for (var sample = 1; sample <= 3; sample += 1) {
        now = sample * 10;
        final trace = telemetry.projectionEmitted();
        telemetry.flutterReceived(trace);
        now += sample;
        telemetry.frameRendered(
          buildMicroseconds: sample,
          rasterMicroseconds: sample * 2,
          totalFrameMicroseconds: sample * 3,
        );
      }

      final summary = telemetry.summarize();
      expect(summary.count, 3);
      expect(summary.build!.p50Microseconds, 2);
      expect(summary.build!.p95Microseconds, 3);
      expect(summary.build!.p99Microseconds, 3);
      expect(summary.totalFrame!.sampleCount, 3);
    },
  );

  test(
    'empty summary has an explicit stable reason and disposal is idempotent',
    () {
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 1,
        sampleLimit: 1,
        clock: () => 0,
        traceIdFactory: () => 'trace',
      );
      expect(
        telemetry.summarize().unavailableReason,
        CausalTelemetryUnavailableReason.noSamples,
      );
      telemetry.dispose();
      telemetry.dispose();
      expect(telemetry.pendingCount, 0);
    },
  );

  test('renderer receipt starts an uncaused runtime trace at projection', () {
    var now = 10;
    final completed = <CausalTraceMeasurement>[];
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 2,
      sampleLimit: 2,
      clock: () => now,
      traceIdFactory: () => 'runtime-projection',
      sink: completed.add,
    );

    telemetry.projectionReceived(null);
    now = 14;
    telemetry.frameRendered(
      buildMicroseconds: 1,
      rasterMicroseconds: 2,
      totalFrameMicroseconds: 3,
    );

    expect(completed, hasLength(1));
    expect(completed.single.origin, CausalTraceOrigin.runtime);
    expect(completed.single.intentOrRuntimeToProjectionMicroseconds, 0);
    expect(completed.single.projectionToFrameMicroseconds, 4);
  });

  test(
    'projection registry traces runtime updates before renderer delivery',
    () async {
      var now = 10;
      final completed = <CausalTraceMeasurement>[];
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 2,
        sampleLimit: 2,
        clock: () => now,
        traceIdFactory: () => 'runtime-registry',
        sink: completed.add,
      );
      final source = _MutableProjectionSource<int>(0);
      final registry = CausalProjectionSourceRegistry(telemetry);
      final traced = registry.wrap(source);
      final updates = <ProjectionUpdate<int>>[];
      final subscription = traced.changes.listen((update) {
        updates.add(update);
        telemetry.flutterReceived(update.trace!);
      });

      source.publish(1);

      expect(updates, hasLength(1));
      expect(updates.single.trace?.traceId, 'runtime-registry');
      now = 12;
      now = 15;
      telemetry.frameRendered(
        buildMicroseconds: 1,
        rasterMicroseconds: 2,
        totalFrameMicroseconds: 3,
      );

      expect(completed, hasLength(1));
      expect(completed.single.origin, CausalTraceOrigin.runtime);
      expect(completed.single.intentOrRuntimeToProjectionMicroseconds, 0);
      expect(completed.single.projectionToFrameMicroseconds, 5);

      await subscription.cancel();
      await registry.dispose();
      await source.close();
      telemetry.dispose();
    },
  );

  test(
    'projection registry releases updates with no renderer observer',
    () async {
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 2,
        sampleLimit: 2,
        clock: () => 0,
        traceIdFactory: () => 'unobserved-projection',
      );
      final source = _MutableProjectionSource<int>(0);
      final registry = CausalProjectionSourceRegistry(telemetry);
      registry.wrap(source);

      source.publish(1);

      expect(telemetry.pendingCount, 0);
      expect(telemetry.summarize().unavailableCounts, {
        CausalTelemetryUnavailableReason.projectionNotObserved: 1,
      });

      await registry.dispose();
      await source.close();
      telemetry.dispose();
    },
  );

  test(
    'projection registry releases runtime updates rejected by every selector',
    () async {
      final telemetry = CausalFrameTelemetry(
        pendingLimit: 2,
        sampleLimit: 2,
        clock: () => 0,
        traceIdFactory: () => 'unselected-runtime-projection',
      );
      final source = _MutableProjectionSource<int>(0);
      final registry = CausalProjectionSourceRegistry(telemetry);
      final traced = registry.wrap(source);
      final subscription = traced.changes.listen((_) {});

      source.publish(1);

      expect(telemetry.pendingCount, 0);
      expect(telemetry.summarize().unavailableCounts, {
        CausalTelemetryUnavailableReason.frameNotObserved: 1,
      });

      await subscription.cancel();
      await registry.dispose();
      await source.close();
      telemetry.dispose();
    },
  );

  test('projection registry retains a renderer intent trace', () async {
    var now = 0;
    final completed = <CausalTraceMeasurement>[];
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 2,
      sampleLimit: 2,
      clock: () => now,
      traceIdFactory: () => 'renderer-registry',
      sink: completed.add,
    );
    final source = _MutableProjectionSource<int>(0);
    final registry = CausalProjectionSourceRegistry(telemetry);
    final traced = registry.wrap(source);
    final updates = <ProjectionUpdate<int>>[];
    final subscription = traced.changes.listen(updates.add);
    final trace = telemetry.beginRendererIntent();

    now = 4;
    source.publish(1, trace: trace);

    expect(updates.single.trace, same(trace));
    now = 5;
    telemetry.flutterReceived(trace);
    now = 8;
    telemetry.frameRendered(
      buildMicroseconds: 1,
      rasterMicroseconds: 2,
      totalFrameMicroseconds: 3,
    );

    expect(completed.single.origin, CausalTraceOrigin.rendererIntent);
    expect(completed.single.intentOrRuntimeToProjectionMicroseconds, 4);
    expect(completed.single.totalToFrameMicroseconds, 8);

    await subscription.cancel();
    await registry.dispose();
    await source.close();
    telemetry.dispose();
  });

  test('a consumed projection closes only on its exact rendered frame', () {
    var now = 0;
    final completed = <CausalTraceMeasurement>[];
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 4,
      sampleLimit: 4,
      clock: () => now,
      traceIdFactory: () => 'exact-frame',
      sink: completed.add,
    );
    final trace = telemetry.projectionEmitted();
    now = 2;
    telemetry.flutterReceived(trace);
    now = 4;
    telemetry.projectionFrameConsumed(trace, frameBuildStartMicroseconds: 100);

    telemetry.acceptFrameTiming(_frameTiming(buildStart: 90));
    expect(completed, isEmpty);
    expect(telemetry.pendingCount, 1);

    telemetry.acceptFrameTiming(_frameTiming(buildStart: 100));
    expect(completed, hasLength(1));
    expect(completed.single.projectionToFrameMicroseconds, 4);
    expect(telemetry.pendingCount, 0);
  });

  test('a completed trace is never reopened by a late projection', () {
    var now = 0;
    final completed = <CausalTraceMeasurement>[];
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 2,
      sampleLimit: 2,
      clock: () => now,
      traceIdFactory: () => 'single-completion',
      sink: completed.add,
    );
    final trace = telemetry.beginRendererIntent();
    telemetry.projectionEmitted(trace: trace);
    telemetry.flutterReceived(trace);
    now = 2;
    telemetry.frameRendered(
      buildMicroseconds: 1,
      rasterMicroseconds: 1,
      totalFrameMicroseconds: 2,
    );

    now = 3;
    telemetry.projectionEmitted(trace: trace);
    telemetry.flutterReceived(trace);
    now = 4;
    telemetry.frameRendered(
      buildMicroseconds: 1,
      rasterMicroseconds: 1,
      totalFrameMicroseconds: 2,
    );

    expect(completed, hasLength(1));
    expect(telemetry.pendingCount, 0);
  });

  test('unmatched phases are released with explicit stable reasons', () {
    var nextId = 0;
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 4,
      sampleLimit: 4,
      clock: () => 0,
      traceIdFactory: () => 'trace-${nextId++}',
    );
    final noProjection = telemetry.beginRendererIntent();
    final noFrame = telemetry.projectionEmitted();
    telemetry.flutterReceived(noFrame);

    telemetry.discardTrace(
      noProjection,
      CausalTelemetryUnavailableReason.projectionNotObserved,
    );
    telemetry.discardTrace(
      noFrame,
      CausalTelemetryUnavailableReason.frameNotObserved,
    );

    expect(telemetry.pendingCount, 0);
    expect(telemetry.summarize().unavailableCounts, {
      CausalTelemetryUnavailableReason.projectionNotObserved: 1,
      CausalTelemetryUnavailableReason.frameNotObserved: 1,
    });
  });

  test('disposal records every still-pending trace by its reached phase', () {
    var nextId = 0;
    final telemetry = CausalFrameTelemetry(
      pendingLimit: 4,
      sampleLimit: 4,
      clock: () => 0,
      traceIdFactory: () => 'dispose-trace-${nextId++}',
    );
    telemetry.beginRendererIntent();
    final noFrame = telemetry.projectionEmitted();
    telemetry.flutterReceived(noFrame);

    telemetry.dispose();

    expect(telemetry.pendingCount, 0);
    expect(telemetry.summarize().unavailableCounts, {
      CausalTelemetryUnavailableReason.projectionNotObserved: 1,
      CausalTelemetryUnavailableReason.frameNotObserved: 1,
    });
  });

  test(
    'small streaming and long Conversation fixture tracks stay deterministic',
    () {
      final small = _runConversationTimeline(
        _smallConversationTimeline,
        sampleLimit: 8,
      );
      final streaming = _runConversationTimeline(
        _streamingConversationTimeline,
        sampleLimit: 8,
      );
      final long = _runConversationTimeline(
        _longConversationTimeline,
        sampleLimit: 4,
      );

      expect(_metricTuple(small.intentOrRuntimeToProjection!), [1, 1, 1, 1]);
      expect(_metricTuple(small.projectionToFrame!), [1, 3, 3, 3]);
      expect(_metricTuple(streaming.intentOrRuntimeToProjection!), [
        3,
        0,
        1,
        1,
      ]);
      expect(_metricTuple(streaming.projectionToFrame!), [3, 5, 7, 7]);
      expect(_metricTuple(streaming.totalToFrame!), [3, 5, 7, 7]);
      expect(_metricTuple(streaming.build!), [3, 2, 3, 3]);
      expect(_metricTuple(long.intentOrRuntimeToProjection!), [4, 0, 5, 5]);
      expect(_metricTuple(long.projectionToFrame!), [4, 9, 13, 13]);
      expect(_metricTuple(long.totalToFrame!), [4, 10, 16, 16]);
    },
  );
}

enum _ConversationTraceOrigin { rendererIntent, runtime }

final class _ConversationTimelineStep {
  const _ConversationTimelineStep({
    required this.origin,
    required this.projectionDelay,
    required this.frameDelay,
    required this.build,
    required this.raster,
    required this.totalFrame,
  });

  final _ConversationTraceOrigin origin;
  final int projectionDelay;
  final int frameDelay;
  final int build;
  final int raster;
  final int totalFrame;
}

const _smallConversationTimeline = <_ConversationTimelineStep>[
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.rendererIntent,
    projectionDelay: 1,
    frameDelay: 2,
    build: 1,
    raster: 2,
    totalFrame: 3,
  ),
];

const _streamingConversationTimeline = <_ConversationTimelineStep>[
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.rendererIntent,
    projectionDelay: 1,
    frameDelay: 2,
    build: 1,
    raster: 2,
    totalFrame: 3,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.runtime,
    projectionDelay: 0,
    frameDelay: 4,
    build: 2,
    raster: 3,
    totalFrame: 4,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.runtime,
    projectionDelay: 0,
    frameDelay: 6,
    build: 3,
    raster: 4,
    totalFrame: 5,
  ),
];

const _longConversationTimeline = <_ConversationTimelineStep>[
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.rendererIntent,
    projectionDelay: 1,
    frameDelay: 2,
    build: 1,
    raster: 2,
    totalFrame: 3,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.runtime,
    projectionDelay: 0,
    frameDelay: 4,
    build: 2,
    raster: 3,
    totalFrame: 4,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.rendererIntent,
    projectionDelay: 3,
    frameDelay: 6,
    build: 3,
    raster: 4,
    totalFrame: 5,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.runtime,
    projectionDelay: 0,
    frameDelay: 8,
    build: 4,
    raster: 5,
    totalFrame: 6,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.rendererIntent,
    projectionDelay: 5,
    frameDelay: 10,
    build: 5,
    raster: 6,
    totalFrame: 7,
  ),
  _ConversationTimelineStep(
    origin: _ConversationTraceOrigin.runtime,
    projectionDelay: 0,
    frameDelay: 12,
    build: 6,
    raster: 7,
    totalFrame: 8,
  ),
];

CausalTelemetrySummary _runConversationTimeline(
  List<_ConversationTimelineStep> timeline, {
  required int sampleLimit,
}) {
  var now = 0;
  var nextId = 0;
  final telemetry = CausalFrameTelemetry(
    pendingLimit: 8,
    sampleLimit: sampleLimit,
    clock: () => now,
    traceIdFactory: () => 'synthetic-${nextId++}',
  );
  for (final step in timeline) {
    TraceContext trace;
    if (step.origin == _ConversationTraceOrigin.rendererIntent) {
      trace = telemetry.beginRendererIntent();
      now += step.projectionDelay;
      telemetry.projectionEmitted(trace: trace);
    } else {
      now += step.projectionDelay;
      trace = telemetry.projectionEmitted();
    }
    now += 1;
    telemetry.flutterReceived(trace);
    now += step.frameDelay;
    telemetry.frameRendered(
      buildMicroseconds: step.build,
      rasterMicroseconds: step.raster,
      totalFrameMicroseconds: step.totalFrame,
    );
  }
  return telemetry.summarize();
}

final class _MutableProjectionSource<T> implements ProjectionSource<T> {
  _MutableProjectionSource(this._current);

  final StreamController<ProjectionUpdate<T>> _controller =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _controller.stream;

  void publish(T value, {TraceContext? trace}) {
    _current = value;
    _controller.add(ProjectionUpdate<T>(value, trace: trace));
  }

  Future<void> close() => _controller.close();
}

List<int> _metricTuple(CausalMetricSummary metric) => [
  metric.sampleCount,
  metric.p50Microseconds,
  metric.p95Microseconds,
  metric.p99Microseconds,
];

FrameTiming _frameTiming({required int buildStart}) => FrameTiming(
  vsyncStart: buildStart - 1,
  buildStart: buildStart,
  buildFinish: buildStart + 3,
  rasterStart: buildStart + 3,
  rasterFinish: buildStart + 8,
  rasterFinishWallTime: buildStart + 8,
);
