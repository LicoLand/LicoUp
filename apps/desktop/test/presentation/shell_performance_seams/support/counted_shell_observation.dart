import 'dart:collection';
import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/presentation_observation.dart';

/// A counted [PresentationObservation] owner a fixture installs through the
/// real composition.
///
/// This owner counts the phases of the presentation plane instead of timing
/// them, so a deterministic widget check can assert how much work one ordinary
/// interaction caused. It is deliberately not a production owner: it retains
/// no timing history and writes nowhere, and the shell never sees it unless a
/// fixture installs it.
final class CountedShellObservation implements PresentationObservation {
  CountedShellObservation({this.pendingLimit = 256});

  /// Most traces kept pending, mirroring a bounded owner.
  final int pendingLimit;

  /// Traces begun by a renderer intent.
  int rendererIntents = 0;

  /// Projections emitted into the traced boundary.
  int projectionEmissions = 0;

  /// Projections a rendering widget accepted and rebuilt for.
  int acceptedProjections = 0;

  /// Accepted projections a pumped frame consumed.
  int frameConsumedProjections = 0;

  /// One frame stamp per projection a pumped frame consumed.
  ///
  /// Recorded as a list rather than a set: the virtual widget clock may report
  /// the same stamp for several frames, so a measurement window slices the list
  /// and counts the distinct stamps inside the window.
  final List<int> frameConsumptionStamps = <int>[];

  /// Phase facts the owner could not observe, by reason.
  final Map<CausalTelemetryUnavailableReason, int> unavailableCounts =
      <CausalTelemetryUnavailableReason, int>{};

  /// Frame phase samples the binding reported.
  ///
  /// A virtual-clock widget run reports none, so a counted fixture never turns
  /// this into a frame-duration claim.
  int frameSamples = 0;

  final LinkedHashSet<String> _pending = LinkedHashSet<String>();
  final Set<String> _received = <String>{};
  WidgetsBinding? _frameBinding;
  var _nextTrace = 0;
  var _disposed = false;

  bool get disposed => _disposed;

  /// Whether this owner is the installed frame-phase observer of a binding.
  bool get frameObservationAttached => _frameBinding != null;

  int get pendingTraceCount => _pending.length;

  @override
  TraceContext beginRendererIntent() {
    rendererIntents += 1;
    return _begin();
  }

  @override
  TraceContext projectionEmitted({TraceContext? trace}) {
    projectionEmissions += 1;
    final resolved = trace?.traceId?.isNotEmpty == true ? trace! : _begin();
    _pending.add(resolved.traceId!);
    return resolved;
  }

  @override
  void flutterReceived(TraceContext trace) {
    final id = trace.traceId;
    if (id == null) return;
    _received.add(id);
  }

  @override
  TraceContext projectionReceived(TraceContext? trace) {
    acceptedProjections += 1;
    final resolved = projectionEmitted(trace: trace);
    flutterReceived(resolved);
    return resolved;
  }

  @override
  void projectionFrameConsumed(
    TraceContext trace, {
    required int frameBuildStartMicroseconds,
  }) {
    final id = trace.traceId;
    if (id == null || !_received.contains(id)) return;
    frameConsumedProjections += 1;
    frameConsumptionStamps.add(frameBuildStartMicroseconds);
  }

  @override
  void discardTrace(
    TraceContext trace,
    CausalTelemetryUnavailableReason reason,
  ) {
    final id = trace.traceId;
    if (id == null || !_pending.contains(id)) return;
    _pending.remove(id);
    _received.remove(id);
    _recordUnavailable(reason);
  }

  @override
  void discardIfNotReceived(
    TraceContext trace,
    CausalTelemetryUnavailableReason reason,
  ) {
    final id = trace.traceId;
    if (id == null || _received.contains(id)) return;
    discardTrace(trace, reason);
  }

  @override
  void attachFrameObservation(WidgetsBinding binding) {
    if (_disposed || identical(_frameBinding, binding)) return;
    _frameBinding = binding;
    binding.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _frameBinding?.removeTimingsCallback(_onTimings);
    _frameBinding = null;
    _pending.clear();
    _received.clear();
  }

  TraceContext _begin() {
    final id = 'counted-${_nextTrace++}';
    if (_pending.length >= pendingLimit) {
      _pending.remove(_pending.first);
      _recordUnavailable(CausalTelemetryUnavailableReason.capacityEvicted);
    }
    _pending.add(id);
    return TraceContext(traceId: id);
  }

  void _onTimings(List<FrameTiming> timings) {
    frameSamples += timings.length;
  }

  void _recordUnavailable(CausalTelemetryUnavailableReason reason) {
    unavailableCounts.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }
}
