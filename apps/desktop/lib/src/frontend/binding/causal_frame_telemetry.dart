import 'dart:collection';
import 'dart:developer' show TimelineTask;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';

typedef TelemetryClock = int Function();
typedef TraceIdFactory = String Function();
typedef CausalTelemetrySink = void Function(CausalTraceMeasurement value);

const bool _causalFrameTelemetryEnabled = bool.fromEnvironment(
  'LICOUP_CAUSAL_FRAME_TELEMETRY',
);

/// Creates the bounded production collector only when explicitly enabled.
///
/// Trace identifiers and timings remain process-local and are never persisted
/// or attached to native/network requests.
CausalFrameTelemetry? createOptInCausalFrameTelemetry({
  bool enabled = _causalFrameTelemetryEnabled,
}) {
  if (!enabled) return null;
  final clock = Stopwatch()..start();
  var nextTrace = 0;
  return CausalFrameTelemetry(
    pendingLimit: 256,
    sampleLimit: 512,
    clock: () => clock.elapsedMicroseconds,
    traceIdFactory: () => 'presentation-${++nextTrace}',
    timelineEnabled: true,
  );
}

enum CausalTraceOrigin { rendererIntent, runtime }

enum CausalTelemetryUnavailableReason {
  noSamples,
  projectionNotObserved,
  frameNotObserved,
  capacityEvicted,
}

final class CausalTraceMeasurement {
  const CausalTraceMeasurement({
    required this.traceId,
    required this.origin,
    required this.intentOrRuntimeToProjectionMicroseconds,
    required this.projectionToFrameMicroseconds,
    required this.totalToFrameMicroseconds,
    required this.buildMicroseconds,
    required this.rasterMicroseconds,
    required this.totalFrameMicroseconds,
    required this.coalescedTraceCount,
  });

  final String traceId;
  final CausalTraceOrigin origin;
  final int intentOrRuntimeToProjectionMicroseconds;
  final int projectionToFrameMicroseconds;
  final int totalToFrameMicroseconds;
  final int buildMicroseconds;
  final int rasterMicroseconds;
  final int totalFrameMicroseconds;
  final int coalescedTraceCount;
}

final class CausalMetricSummary {
  const CausalMetricSummary({
    required this.sampleCount,
    required this.p50Microseconds,
    required this.p95Microseconds,
    required this.p99Microseconds,
  });

  final int sampleCount;
  final int p50Microseconds;
  final int p95Microseconds;
  final int p99Microseconds;
}

final class CausalTelemetrySummary {
  const CausalTelemetrySummary({
    required this.count,
    required this.intentOrRuntimeToProjection,
    required this.projectionToFrame,
    required this.totalToFrame,
    required this.build,
    required this.raster,
    required this.totalFrame,
    required this.unavailableCounts,
    this.unavailableReason,
  });

  final int count;
  final CausalMetricSummary? intentOrRuntimeToProjection;
  final CausalMetricSummary? projectionToFrame;
  final CausalMetricSummary? totalToFrame;
  final CausalMetricSummary? build;
  final CausalMetricSummary? raster;
  final CausalMetricSummary? totalFrame;
  final Map<CausalTelemetryUnavailableReason, int> unavailableCounts;
  final CausalTelemetryUnavailableReason? unavailableReason;
}

final class CausalFrameTelemetry implements ProjectionReceiptObserver {
  CausalFrameTelemetry({
    required int pendingLimit,
    required int sampleLimit,
    required TelemetryClock clock,
    required TraceIdFactory traceIdFactory,
    CausalTelemetrySink? sink,
    bool timelineEnabled = false,
  }) : _pendingLimit = _positive(pendingLimit, 'pendingLimit'),
       _sampleLimit = _positive(sampleLimit, 'sampleLimit'),
       _clock = clock,
       _traceIdFactory = traceIdFactory,
       _sink = sink,
       _timelineEnabled = timelineEnabled;

  final int _pendingLimit;
  final int _sampleLimit;
  final TelemetryClock _clock;
  final TraceIdFactory _traceIdFactory;
  final CausalTelemetrySink? _sink;
  final bool _timelineEnabled;
  final LinkedHashMap<String, _PendingTrace> _pending = LinkedHashMap();
  final LinkedHashMap<int, _ConsumedFrame> _consumedFrames = LinkedHashMap();
  final LinkedHashSet<String> _completedTraceIds = LinkedHashSet();
  final List<CausalTraceMeasurement> _samples = [];
  final Map<CausalTelemetryUnavailableReason, int> _unavailableCounts = {};
  int _evicted = 0;
  bool _disposed = false;
  WidgetsBinding? _frameBinding;

  int get pendingCount => _pending.length;
  int get completedCount => _samples.length;
  int get evictedCount => _evicted;

  TraceContext beginRendererIntent() {
    final trace = TraceContext(traceId: _traceIdFactory());
    _start(trace, CausalTraceOrigin.rendererIntent, _clock());
    return trace;
  }

  TraceContext projectionEmitted({TraceContext? trace}) {
    final now = _clock();
    final resolved = trace?.traceId?.isNotEmpty == true
        ? trace!
        : TraceContext(traceId: _traceIdFactory());
    final id = resolved.traceId!;
    if (_completedTraceIds.contains(id)) return resolved;
    final pending =
        _pending[id] ?? _start(resolved, CausalTraceOrigin.runtime, now);
    pending.projectionAt ??= now;
    pending.timeline?.instant('projection');
    return resolved;
  }

  void flutterReceived(TraceContext trace) {
    final id = trace.traceId;
    if (_disposed || id == null) return;
    final pending = _pending[id];
    if (pending == null || pending.projectionAt == null) return;
    pending.receivedAt ??= _clock();
    pending.timeline?.instant('flutter-receipt');
  }

  @override
  TraceContext projectionReceived(TraceContext? trace) {
    if (_disposed) throw StateError('causal_telemetry_disposed');
    final resolved = projectionEmitted(trace: trace);
    flutterReceived(resolved);
    return resolved;
  }

  @override
  void projectionFrameConsumed(
    TraceContext trace, {
    required int frameBuildStartMicroseconds,
  }) {
    if (_disposed) return;
    final id = trace.traceId;
    final pending = id == null ? null : _pending[id];
    if (pending == null || pending.receivedAt == null) return;
    final frame = _consumedFrames.putIfAbsent(
      frameBuildStartMicroseconds,
      () => _ConsumedFrame(frameAt: _clock()),
    );
    frame.traceIds.add(id!);
  }

  void attachFrameObservation(WidgetsBinding binding) {
    if (_disposed) throw StateError('causal_telemetry_disposed');
    if (identical(_frameBinding, binding)) return;
    if (_frameBinding != null) {
      throw StateError('causal_telemetry_frame_binding_already_attached');
    }
    _frameBinding = binding;
    binding.addTimingsCallback(_acceptFrameTimings);
  }

  void _acceptFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      acceptFrameTiming(timing);
    }
  }

  void frameRendered({
    required int buildMicroseconds,
    required int rasterMicroseconds,
    required int totalFrameMicroseconds,
  }) {
    if (_disposed) return;
    _completeFrame(
      traceIds: _pending.values
          .where((trace) => trace.receivedAt != null)
          .map((trace) => trace.id),
      frameAt: _clock(),
      buildMicroseconds: buildMicroseconds,
      rasterMicroseconds: rasterMicroseconds,
      totalFrameMicroseconds: totalFrameMicroseconds,
    );
  }

  void _completeFrame({
    required Iterable<String> traceIds,
    required int frameAt,
    required int buildMicroseconds,
    required int rasterMicroseconds,
    required int totalFrameMicroseconds,
  }) {
    final consumed = <_PendingTrace>[for (final id in traceIds) ?_pending[id]];
    final coalescedCount = consumed.length;
    for (final pending in consumed) {
      final projectionAt = pending.projectionAt!;
      final measurement = CausalTraceMeasurement(
        traceId: pending.id,
        origin: pending.origin,
        intentOrRuntimeToProjectionMicroseconds:
            projectionAt - pending.startedAt,
        projectionToFrameMicroseconds: frameAt - projectionAt,
        totalToFrameMicroseconds: frameAt - pending.startedAt,
        buildMicroseconds: buildMicroseconds,
        rasterMicroseconds: rasterMicroseconds,
        totalFrameMicroseconds: totalFrameMicroseconds,
        coalescedTraceCount: coalescedCount,
      );
      _pending.remove(pending.id);
      _removeConsumedTrace(pending.id);
      pending.timeline?.finish();
      if (_samples.length == _sampleLimit) {
        final removed = _samples.removeAt(0);
        _completedTraceIds.remove(removed.traceId);
      }
      _samples.add(measurement);
      _completedTraceIds.add(measurement.traceId);
      _sink?.call(measurement);
    }
  }

  void acceptFrameTiming(FrameTiming timing) {
    if (_disposed) return;
    final frame = _consumedFrames.remove(
      timing.timestampInMicroseconds(FramePhase.buildStart),
    );
    if (frame == null) return;
    _completeFrame(
      traceIds: frame.traceIds,
      frameAt: frame.frameAt,
      buildMicroseconds: timing.buildDuration.inMicroseconds,
      rasterMicroseconds: timing.rasterDuration.inMicroseconds,
      totalFrameMicroseconds: timing.totalSpan.inMicroseconds,
    );
  }

  /// Releases a trace whose projection or frame can no longer be observed.
  /// Callers choose the truthful phase-specific reason; no timer guesses it.
  void discardTrace(
    TraceContext trace,
    CausalTelemetryUnavailableReason reason,
  ) {
    if (_disposed || reason == CausalTelemetryUnavailableReason.noSamples) {
      return;
    }
    final id = trace.traceId;
    if (id == null) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    _removeConsumedTrace(id);
    pending.timeline?.finish();
    _recordUnavailable(reason);
  }

  /// Releases a delivered trace only when no Flutter observer accepted it.
  ///
  /// Synchronous projection streams call this after every listener has had a
  /// chance to select the update, so one listener accepting the projection
  /// keeps the trace alive for its rendered frame.
  void discardIfNotReceived(
    TraceContext trace,
    CausalTelemetryUnavailableReason reason,
  ) {
    if (_disposed) return;
    final id = trace.traceId;
    if (id == null || _pending[id]?.receivedAt != null) return;
    discardTrace(trace, reason);
  }

  CausalTelemetrySummary summarize() {
    if (_samples.isEmpty) {
      return CausalTelemetrySummary(
        count: 0,
        intentOrRuntimeToProjection: null,
        projectionToFrame: null,
        totalToFrame: null,
        build: null,
        raster: null,
        totalFrame: null,
        unavailableCounts: Map.unmodifiable(_unavailableCounts),
        unavailableReason:
            _unavailableCounts.keys.firstOrNull ??
            CausalTelemetryUnavailableReason.noSamples,
      );
    }
    return CausalTelemetrySummary(
      count: _samples.length,
      intentOrRuntimeToProjection: _summarize(
        _samples.map((value) => value.intentOrRuntimeToProjectionMicroseconds),
      ),
      projectionToFrame: _summarize(
        _samples.map((value) => value.projectionToFrameMicroseconds),
      ),
      totalToFrame: _summarize(
        _samples.map((value) => value.totalToFrameMicroseconds),
      ),
      build: _summarize(_samples.map((value) => value.buildMicroseconds)),
      raster: _summarize(_samples.map((value) => value.rasterMicroseconds)),
      totalFrame: _summarize(
        _samples.map((value) => value.totalFrameMicroseconds),
      ),
      unavailableCounts: Map.unmodifiable(_unavailableCounts),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _frameBinding?.removeTimingsCallback(_acceptFrameTimings);
    _frameBinding = null;
    for (final trace in _pending.values) {
      trace.timeline?.finish();
      _recordUnavailable(
        trace.projectionAt == null
            ? CausalTelemetryUnavailableReason.projectionNotObserved
            : CausalTelemetryUnavailableReason.frameNotObserved,
      );
    }
    _pending.clear();
    _consumedFrames.clear();
    _completedTraceIds.clear();
  }

  _PendingTrace _start(
    TraceContext context,
    CausalTraceOrigin origin,
    int startedAt,
  ) {
    if (_disposed) throw StateError('causal_telemetry_disposed');
    final id = context.traceId;
    if (id == null || id.isEmpty) throw ArgumentError.value(id, 'traceId');
    final existing = _pending[id];
    if (existing != null) return existing;
    if (_pending.length == _pendingLimit) {
      final evicted = _pending.remove(_pending.keys.first)!;
      _removeConsumedTrace(evicted.id);
      evicted.timeline?.finish();
      _evicted += 1;
      _recordUnavailable(CausalTelemetryUnavailableReason.capacityEvicted);
    }
    final timeline = _timelineEnabled ? TimelineTask() : null;
    timeline?.start(
      origin == CausalTraceOrigin.rendererIntent
          ? 'presentation.renderer-intent'
          : 'presentation.runtime',
    );
    final pending = _PendingTrace(
      id: id,
      origin: origin,
      startedAt: startedAt,
      timeline: timeline,
    );
    _pending[id] = pending;
    return pending;
  }

  void _removeConsumedTrace(String id) {
    final emptyFrames = <int>[];
    for (final entry in _consumedFrames.entries) {
      entry.value.traceIds.remove(id);
      if (entry.value.traceIds.isEmpty) emptyFrames.add(entry.key);
    }
    for (final frame in emptyFrames) {
      _consumedFrames.remove(frame);
    }
  }

  void _recordUnavailable(CausalTelemetryUnavailableReason reason) {
    _unavailableCounts.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }
}

final class _ConsumedFrame {
  _ConsumedFrame({required this.frameAt});

  final int frameAt;
  final Set<String> traceIds = <String>{};
}

final class _PendingTrace {
  _PendingTrace({
    required this.id,
    required this.origin,
    required this.startedAt,
    required this.timeline,
  });

  final String id;
  final CausalTraceOrigin origin;
  final int startedAt;
  final TimelineTask? timeline;
  int? projectionAt;
  int? receivedAt;
}

CausalMetricSummary _summarize(Iterable<int> values) {
  final sorted = values.toList()..sort();
  int percentile(double value) => sorted[(value * sorted.length).ceil() - 1];
  return CausalMetricSummary(
    sampleCount: sorted.length,
    p50Microseconds: percentile(.50),
    p95Microseconds: percentile(.95),
    p99Microseconds: percentile(.99),
  );
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be positive');
  return value;
}
