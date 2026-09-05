import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';

typedef FrameTimingSummarySink = void Function(FrameTimingSummary summary);

final class FrameTimingMetricSummary {
  const FrameTimingMetricSummary({
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

final class FrameTimingSummary {
  const FrameTimingSummary({
    required this.build,
    required this.raster,
    required this.total,
  });

  final FrameTimingMetricSummary build;
  final FrameTimingMetricSummary raster;
  final FrameTimingMetricSummary total;
}

FrameTimingMetricSummary summarizeFrameMicroseconds(Iterable<int> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) {
    throw ArgumentError.value(values, 'values', 'must contain a sample');
  }
  int rank(double percentile) =>
      sorted[(percentile * sorted.length).ceil() - 1];
  return FrameTimingMetricSummary(
    sampleCount: sorted.length,
    p50Microseconds: rank(.50),
    p95Microseconds: rank(.95),
    p99Microseconds: rank(.99),
  );
}

/// Opt-in bounded renderer telemetry. Disabled instances touch no binding.
final class FrameTimingTelemetry {
  FrameTimingTelemetry({
    required int sampleLimit,
    required FrameTimingSummarySink sink,
    bool enabled = false,
    WidgetsBinding? binding,
  }) : _sampleLimit = _requirePositiveSampleLimit(sampleLimit),
       _sink = sink,
       _binding = enabled ? (binding ?? WidgetsBinding.instance) : null,
       _enabled = enabled {
    if (_enabled) _binding!.addTimingsCallback(_onTimings);
  }

  final int _sampleLimit;
  final FrameTimingSummarySink _sink;
  final WidgetsBinding? _binding;
  final bool _enabled;
  final List<int> _buildMicroseconds = <int>[];
  final List<int> _rasterMicroseconds = <int>[];
  final List<int> _totalMicroseconds = <int>[];
  bool _finished = false;

  void _onTimings(List<FrameTiming> timings) {
    if (_finished) return;
    final remaining = _sampleLimit - _buildMicroseconds.length;
    for (final timing in timings.take(remaining)) {
      _buildMicroseconds.add(timing.buildDuration.inMicroseconds);
      _rasterMicroseconds.add(timing.rasterDuration.inMicroseconds);
      _totalMicroseconds.add(timing.totalSpan.inMicroseconds);
    }
    if (_buildMicroseconds.length < _sampleLimit) return;
    _finished = true;
    _binding!.removeTimingsCallback(_onTimings);
    _sink(
      FrameTimingSummary(
        build: summarizeFrameMicroseconds(_buildMicroseconds),
        raster: summarizeFrameMicroseconds(_rasterMicroseconds),
        total: summarizeFrameMicroseconds(_totalMicroseconds),
      ),
    );
  }

  void dispose() {
    if (_finished) return;
    _finished = true;
    if (_enabled) _binding!.removeTimingsCallback(_onTimings);
  }
}

int _requirePositiveSampleLimit(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'sampleLimit', 'must be positive');
  }
  return value;
}
