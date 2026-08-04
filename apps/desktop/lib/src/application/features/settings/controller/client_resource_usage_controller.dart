import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/platform/client_resource_usage_probe.dart';

const int clientResourceUsageMaxSamples = 180;
const Duration clientResourceUsageSamplingInterval = Duration(seconds: 5);

/// Creates a controller backed by the current platform's process probe.
ClientResourceUsageController createClientResourceUsageController() {
  return ClientResourceUsageController(probe: createClientResourceUsageProbe());
}

/// One sampled point. Delta fields are the deltas from the previous sample;
/// the first sample carries zero deltas and a zero interval.
final class ClientResourceUsageSample {
  const ClientResourceUsageSample({
    required this.at,
    required this.rssBytes,
    required this.deltaReadBytes,
    required this.deltaWriteBytes,
    required this.interval,
  });

  final DateTime at;
  final int rssBytes;
  final int deltaReadBytes;
  final int deltaWriteBytes;
  final Duration interval;
}

/// Samples process-level resource usage while a diagnostic surface is open.
///
/// All history stays in memory; nothing is written to disk.
final class ClientResourceUsageController extends ChangeNotifier {
  ClientResourceUsageController({
    required ClientResourceUsageProbe? probe,
    DateTime Function()? now,
  }) : _probe = probe,
       _now = now ?? DateTime.now;

  final ClientResourceUsageProbe? _probe;
  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _lastAt;
  int _lastReadBytes = 0;
  int _lastWriteBytes = 0;
  int _sessionReadBytes = 0;
  int _sessionWriteBytes = 0;
  final List<ClientResourceUsageSample> _samples = [];
  bool _disposed = false;

  bool get supported => _probe != null;

  bool get isSampling => _timer != null;

  List<ClientResourceUsageSample> get samples => List.unmodifiable(_samples);

  int get sessionReadBytes => _sessionReadBytes;

  int get sessionWriteBytes => _sessionWriteBytes;

  void start({
    Duration interval = clientResourceUsageSamplingInterval,
  }) {
    if (_disposed || _probe == null || _timer != null) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reads the probe once and appends a sample when the delta is meaningful.
  void refresh() {
    final probe = _probe;
    if (_disposed || probe == null) {
      return;
    }
    final at = _now();
    ResourceProbeReading reading;
    try {
      reading = probe.read();
    } catch (_) {
      return;
    }
    final previousAt = _lastAt;
    _lastAt = at;
    if (previousAt == null) {
      _lastReadBytes = reading.diskReadBytes;
      _lastWriteBytes = reading.diskWriteBytes;
      return;
    }
    var interval = at.difference(previousAt);
    if (interval.isNegative) {
      interval = Duration.zero;
    }
    final deltaRead = _nonNegativeDelta(
      reading.diskReadBytes,
      _lastReadBytes,
    );
    final deltaWrite = _nonNegativeDelta(
      reading.diskWriteBytes,
      _lastWriteBytes,
    );
    _lastReadBytes = reading.diskReadBytes;
    _lastWriteBytes = reading.diskWriteBytes;
    _sessionReadBytes += deltaRead;
    _sessionWriteBytes += deltaWrite;
    _samples.add(
      ClientResourceUsageSample(
        at: at,
        rssBytes: reading.rssBytes,
        deltaReadBytes: deltaRead,
        deltaWriteBytes: deltaWrite,
        interval: interval,
      ),
    );
    if (_samples.length > clientResourceUsageMaxSamples) {
      _samples.removeRange(0, _samples.length - clientResourceUsageMaxSamples);
    }
    notifyListeners();
  }

  int _nonNegativeDelta(int current, int previous) {
    final delta = current - previous;
    return delta > 0 ? delta : 0;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
