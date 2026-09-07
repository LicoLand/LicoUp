import 'dart:async';
import 'dart:io';

import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

export 'package:licoup/src/contracts/client_memory_diagnostics.dart'
    show ClientMemoryDiagnosticObservation;

const Duration clientMemoryDiagnosticSamplingInterval = Duration(seconds: 15);
const int clientMemoryDiagnosticRssStepBytes = 32 * 1024 * 1024;

/// Samples process RSS while a conversation is open and persists counts.
///
/// Sampling starts on the first open-conversation observation and stops when
/// the surface closes. It does not run at cold start.
final class ClientMemoryDiagnosticJournal {
  ClientMemoryDiagnosticJournal({
    required ClientMemoryDiagnosticSink sink,
    ClientResourceUsageProbe? probe,
    DateTime Function()? now,
    int Function()? maxRssBytes,
    Duration interval = clientMemoryDiagnosticSamplingInterval,
  }) : _sink = sink,
       _probe = probe ?? createClientResourceUsageProbe(),
       _now = now ?? DateTime.now,
       _maxRssBytes = maxRssBytes ?? _currentMaxRss,
       _interval = interval;

  final ClientMemoryDiagnosticSink _sink;
  final ClientResourceUsageProbe? _probe;
  final DateTime Function() _now;
  final int Function() _maxRssBytes;
  final Duration _interval;

  Timer? _timer;
  ClientMemoryDiagnosticObservation? _latest;
  int _lastWrittenRssBytes = 0;
  bool _disposed = false;

  bool get isSampling => _timer != null;

  void observe(ClientMemoryDiagnosticObservation observation) {
    if (_disposed) return;
    _latest = observation;
    switch (observation.event) {
      case ClientMemoryDiagnosticEvent.conversationOpened:
      case ClientMemoryDiagnosticEvent.liveTurnOpened:
      case ClientMemoryDiagnosticEvent.liveTurnClosed:
        _write(observation);
        _ensureTimer();
      case ClientMemoryDiagnosticEvent.conversationClosed:
        _write(observation);
        _stopTimer();
      case ClientMemoryDiagnosticEvent.sample:
        _ensureTimer();
        _writeIfRssStepped(observation);
    }
  }

  void dispose() {
    _disposed = true;
    _stopTimer();
  }

  void _ensureTimer() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(_interval, (_) => _sample());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _sample() {
    final latest = _latest;
    if (_disposed || latest == null) {
      _stopTimer();
      return;
    }
    if (latest.event == ClientMemoryDiagnosticEvent.conversationClosed) {
      _stopTimer();
      return;
    }
    _write(
      ClientMemoryDiagnosticObservation(
        event: ClientMemoryDiagnosticEvent.sample,
        surface: latest.surface,
        eventCount: latest.eventCount,
        loadedEventCount: latest.loadedEventCount,
        liveTurnCount: latest.liveTurnCount,
        livePartCount: latest.livePartCount,
        liveMessageCount: latest.liveMessageCount,
        cachedConversationCount: latest.cachedConversationCount,
      ),
    );
  }

  void _writeIfRssStepped(ClientMemoryDiagnosticObservation observation) {
    final rss = _rssBytes();
    if (_lastWrittenRssBytes == 0) {
      _write(observation);
      return;
    }
    final delta = rss - _lastWrittenRssBytes;
    if (delta >= clientMemoryDiagnosticRssStepBytes ||
        delta <= -clientMemoryDiagnosticRssStepBytes) {
      _write(observation);
    }
  }

  void _write(ClientMemoryDiagnosticObservation observation) {
    final rss = _rssBytes();
    _lastWrittenRssBytes = rss;
    unawaited(
      _sink.record(
        ClientMemoryDiagnosticRecord(
          event: observation.event,
          createdAt: _now().toUtc(),
          surface: observation.surface,
          rssBytes: rss,
          maxRssBytes: _maxRssBytes(),
          eventCount: observation.eventCount,
          loadedEventCount: observation.loadedEventCount,
          liveTurnCount: observation.liveTurnCount,
          livePartCount: observation.livePartCount,
          liveMessageCount: observation.liveMessageCount,
          cachedConversationCount: observation.cachedConversationCount,
        ),
      ),
    );
  }

  int _rssBytes() {
    final probe = _probe;
    if (probe == null) return 0;
    try {
      return probe.read().rssBytes;
    } catch (_) {
      return 0;
    }
  }
}

int _currentMaxRss() {
  try {
    return ProcessInfo.maxRss;
  } catch (_) {
    return 0;
  }
}
