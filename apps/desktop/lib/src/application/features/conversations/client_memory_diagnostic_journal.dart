import 'dart:async';
import 'dart:io';

import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';

const int clientMemoryDiagnosticRssStepBytes = 32 * 1024 * 1024;

/// Persists RSS and live-turn counts while a conversation is open.
///
/// Writes on open, close, live-turn edges, and when RSS steps by 32 MiB.
/// It does not start a periodic timer, so widget tests can dispose the
/// tree without a leftover sampler.
final class ClientMemoryDiagnosticJournal {
  ClientMemoryDiagnosticJournal({
    required ClientMemoryDiagnosticSink sink,
    ClientResourceUsageProbe? probe,
    DateTime Function()? now,
    int Function()? maxRssBytes,
  }) : _sink = sink,
       _probe = probe ?? createClientResourceUsageProbe(),
       _now = now ?? DateTime.now,
       _maxRssBytes = maxRssBytes ?? _currentMaxRss;

  final ClientMemoryDiagnosticSink _sink;
  final ClientResourceUsageProbe? _probe;
  final DateTime Function() _now;
  final int Function() _maxRssBytes;

  ClientMemoryDiagnosticObservation? _latest;
  int _lastWrittenRssBytes = 0;
  bool _disposed = false;

  bool get isSampling =>
      _latest != null &&
      _latest!.event != ClientMemoryDiagnosticEvent.conversationClosed;

  void observe(ClientMemoryDiagnosticObservation observation) {
    if (_disposed) return;
    _latest = observation;
    switch (observation.event) {
      case ClientMemoryDiagnosticEvent.conversationOpened:
      case ClientMemoryDiagnosticEvent.liveTurnOpened:
      case ClientMemoryDiagnosticEvent.liveTurnClosed:
      case ClientMemoryDiagnosticEvent.conversationClosed:
        _write(observation);
      case ClientMemoryDiagnosticEvent.sample:
        _writeIfRssStepped(observation);
    }
  }

  void dispose() {
    _disposed = true;
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
