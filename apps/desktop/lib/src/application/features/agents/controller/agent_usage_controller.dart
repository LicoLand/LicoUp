import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';

const Duration defaultAgentUsagePollingInterval = Duration(minutes: 1);
const int defaultAgentUsageHistoryDays = 30;
const int minAgentUsageHistoryDays = 1;
const int maxAgentUsageHistoryDays = 365;

typedef AgentUsageStatusSink =
    void Function({
      required String chinese,
      required String english,
      required String caption,
      String errorCode,
    });

/// Owns usage-report state, bounded history, polling, and all single-flight
/// guards. The application composition root only projects this state.
final class AgentUsageController extends ChangeNotifier {
  AgentUsageController({
    required this.gateway,
    required this.selectedAgentId,
    required this.onStatus,
  });

  final AgentUsageGateway gateway;
  final String Function() selectedAgentId;
  final AgentUsageStatusSink onStatus;

  AgentUsageReport? report;
  List<AgentUsageReport> reports = const [];
  bool scanning = false;
  int historyDays = defaultAgentUsageHistoryDays;

  Timer? _pollingTimer;
  final Set<Object> _pollingOwners = <Object>{};
  final Object _defaultPollingOwner = Object();
  Duration _pollingInterval = defaultAgentUsagePollingInterval;
  Future<void>? _refreshFuture;
  Future<void>? _scanFuture;
  bool _disposed = false;

  @visibleForTesting
  int get pollingOwnerCount => _pollingOwners.length;

  AgentUsageAgentSummary? get selectedUsage {
    final agentId = selectedAgentId().trim();
    return agentId.isEmpty ? null : report?.agent(agentId);
  }

  void replaceReport(AgentUsageReport? value) {
    report = value;
  }

  void replaceReports(List<AgentUsageReport> value) {
    reports = List.unmodifiable(value);
  }

  @visibleForTesting
  void replaceScanning(bool value) {
    scanning = value;
  }

  void startPolling({Duration interval = defaultAgentUsagePollingInterval}) {
    acquirePollingOwner(_defaultPollingOwner, interval: interval);
  }

  void stopPolling() {
    releasePollingOwner(_defaultPollingOwner);
  }

  void acquirePollingOwner(
    Object owner, {
    Duration interval = defaultAgentUsagePollingInterval,
  }) {
    if (_disposed) return;
    final wasEmpty = _pollingOwners.isEmpty;
    _pollingOwners.add(owner);
    final normalized = interval > Duration.zero
        ? interval
        : defaultAgentUsagePollingInterval;
    if (wasEmpty || normalized < _pollingInterval) {
      _pollingInterval = normalized;
    }
    if (wasEmpty && _pollingOwners.isNotEmpty) {
      _schedulePoll(_pollingInterval);
    }
  }

  void releasePollingOwner(Object owner) {
    _pollingOwners.remove(owner);
    if (_pollingOwners.isNotEmpty) return;
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  void _schedulePoll(Duration interval) {
    if (_disposed || _pollingOwners.isEmpty) return;
    _pollingTimer = Timer(interval, () {
      _pollingTimer = null;
      unawaited(() async {
        await scan(forceRefresh: false, showProgress: false);
        if (!_disposed && _pollingOwners.isNotEmpty) {
          _schedulePoll(_pollingInterval);
        }
      }());
    });
  }

  Future<void> ensureLoadedAndFresh({int limit = 20}) {
    if (_disposed || _reportMatchesActiveWindowAndIsFresh) {
      return Future<void>.value();
    }
    final active = _refreshFuture;
    if (active != null) return active;
    late final Future<void> refresh;
    refresh = _loadAndRefresh(limit: limit).whenComplete(() {
      if (identical(_refreshFuture, refresh)) _refreshFuture = null;
    });
    _refreshFuture = refresh;
    return refresh;
  }

  Future<void> _loadAndRefresh({required int limit}) async {
    if (_disposed || _reportMatchesActiveWindowAndIsFresh) return;
    if (report == null) await loadReports(limit: limit, showProgress: false);
    if (!_disposed && !_reportMatchesActiveWindowAndIsFresh) {
      await scan(forceRefresh: false, showProgress: false);
    }
  }

  bool get _reportMatchesActiveWindowAndIsFresh =>
      report?.windowDays == historyDays && report?.isFresh() == true;

  Future<void> setHistoryDays(int value) async {
    final normalized = value
        .clamp(minAgentUsageHistoryDays, maxAgentUsageHistoryDays)
        .toInt();
    if (normalized == historyDays) return;
    historyDays = normalized;
    notifyListeners();
    final active = _scanFuture;
    if (active != null) {
      await active;
    }
    if (_disposed) return;
    await scan(forceRefresh: true);
  }

  Future<void> scan({bool forceRefresh = true, bool showProgress = true}) {
    final active = _scanFuture;
    if (active != null) return active;
    if (scanning || _disposed) return Future<void>.value();
    late final Future<void> scanFuture;
    scanFuture = _scan(forceRefresh: forceRefresh, showProgress: showProgress)
        .whenComplete(() {
          if (identical(_scanFuture, scanFuture)) _scanFuture = null;
        });
    _scanFuture = scanFuture;
    return scanFuture;
  }

  Future<void> _scan({
    required bool forceRefresh,
    required bool showProgress,
  }) async {
    scanning = true;
    if (showProgress) {
      onStatus(
        chinese: '正在刷新本机 Token 用量。',
        english: 'Refreshing local token usage.',
        caption: 'Agent usage',
      );
      notifyListeners();
    }
    try {
      final next = await gateway.scan(
        forceRefresh: forceRefresh,
        historyDays: historyDays,
      );
      if (_disposed) return;
      report = next;
      reports = List.unmodifiable(
        [
          next,
          ...reports.where(
            (candidate) => candidate.generatedAt != next.generatedAt,
          ),
        ].take(20),
      );
      if (showProgress) {
        onStatus(
          chinese: '已扫描 ${next.agentCount} 个智能体，共 ${next.totalTokens} 个 Token。',
          english:
              'Scanned ${next.agentCount} agents and ${next.totalTokens} tokens.',
          caption: 'Agent usage',
        );
      }
    } catch (_) {
      if (!_disposed && showProgress) {
        onStatus(
          chinese: '智能体用量扫描失败。',
          english: 'Agent usage scan failed.',
          caption: 'Agent usage',
          errorCode: 'agent_usage_scan_failed',
        );
      }
    } finally {
      scanning = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> loadReports({int limit = 10, bool showProgress = true}) async {
    if (scanning || _disposed) return;
    scanning = true;
    if (showProgress) {
      onStatus(chinese: '', english: '', caption: 'Agent usage');
    }
    notifyListeners();
    try {
      reports = List.unmodifiable(await gateway.reports(limit: limit));
      report = reports.isEmpty ? null : reports.first;
      if (showProgress) {
        onStatus(
          chinese: '已加载 ${reports.length} 份用量报表。',
          english: 'Loaded ${reports.length} usage reports.',
          caption: 'Agent usage',
        );
      }
    } catch (_) {
      if (showProgress) {
        onStatus(
          chinese: '智能体用量报表加载失败。',
          english: 'Agent usage reports failed to load.',
          caption: 'Agent usage',
          errorCode: 'agent_usage_reports_failed',
        );
      }
    } finally {
      scanning = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pollingOwners.clear();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    super.dispose();
  }
}
