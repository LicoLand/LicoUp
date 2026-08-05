import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';

const int agentResourceUsageMaxSamples = 180;
const Duration agentResourceUsageSamplingInterval = Duration(seconds: 5);

/// One sampled point for one agent. Deltas are relative to the previous
/// sample; the first sample carries zero deltas and a zero interval.
final class AgentResourceUsageSample {
  const AgentResourceUsageSample({
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

/// Owns the per-agent sampled history for all running local agents.
///
/// Samples are collected while a diagnostic surface is open; all history
/// stays in memory and nothing is written to disk.
final class AgentResourceUsageController extends ChangeNotifier {
  AgentResourceUsageController({
    required this.gateway,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AgentResourceUsageGateway gateway;
  final DateTime Function() _now;

  final Map<String, List<AgentResourceUsageSample>> _samplesByAgent = {};
  final Map<String, int> _lastReadBytes = {};
  final Map<String, int> _lastWriteBytes = {};
  final Map<String, DateTime> _lastAt = {};
  Timer? _timer;
  bool _disposed = false;
  bool _scanning = false;
  String? _lastError;

  bool get isSampling => _timer != null;

  bool get isScanning => _scanning;

  String? get lastError => _lastError;

  int get runningAgentCount => _samplesByAgent.length;

  /// Sampled history for one agent, newest last.
  List<AgentResourceUsageSample> samplesFor(String target) {
    return List.unmodifiable(_samplesByAgent[target] ?? const []);
  }

  /// Latest sample per running agent, keyed by target id.
  Map<String, AgentResourceUsageSample> get latestByAgent {
    return {
      for (final entry in _samplesByAgent.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.last,
    };
  }

  void start({Duration interval = agentResourceUsageSamplingInterval}) {
    if (_disposed || _timer != null) {
      return;
    }
    _timer = Timer.periodic(interval, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Scans all running agents and appends one sample per agent.
  Future<void> refresh() async {
    if (_disposed || _scanning) {
      return;
    }
    _scanning = true;
    try {
      final report = await gateway.scan();
      if (_disposed) {
        return;
      }
      final at = _now();
      for (final agent in report.agents) {
        if (!agent.running) {
          continue;
        }
        _appendSample(agent, at);
      }
      notifyListeners();
    } catch (_) {
      _lastError = 'agent_resource_scan_failed';
      notifyListeners();
    } finally {
      _scanning = false;
    }
  }

  void _appendSample(AgentResourceUsageAgent agent, DateTime at) {
    final target = agent.target;
    final previousAt = _lastAt[target];
    _lastAt[target] = at;
    if (previousAt == null) {
      _lastReadBytes[target] = agent.totalDiskReadBytes ?? 0;
      _lastWriteBytes[target] = agent.totalDiskWriteBytes ?? 0;
      return;
    }
    var interval = at.difference(previousAt);
    if (interval.isNegative) {
      interval = Duration.zero;
    }
    final deltaRead = _delta(agent.totalDiskReadBytes, _lastReadBytes[target]);
    final deltaWrite = _delta(
      agent.totalDiskWriteBytes,
      _lastWriteBytes[target],
    );
    _lastReadBytes[target] = agent.totalDiskReadBytes ?? 0;
    _lastWriteBytes[target] = agent.totalDiskWriteBytes ?? 0;
    final samples = _samplesByAgent.putIfAbsent(target, () => []);
    samples.add(
      AgentResourceUsageSample(
        at: at,
        rssBytes: agent.totalRssBytes,
        deltaReadBytes: deltaRead,
        deltaWriteBytes: deltaWrite,
        interval: interval,
      ),
    );
    if (samples.length > agentResourceUsageMaxSamples) {
      samples.removeRange(0, samples.length - agentResourceUsageMaxSamples);
    }
  }

  int _delta(int? current, int? previous) {
    if (current == null) {
      return 0;
    }
    final delta = current - (previous ?? 0);
    return delta > 0 ? delta : 0;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
