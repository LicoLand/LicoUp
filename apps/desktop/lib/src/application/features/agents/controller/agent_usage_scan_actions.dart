part of 'package:flutter_client/src/application/controller/client_controller.dart';

const Duration _agentUsagePollingInterval = Duration(minutes: 1);

extension ClientAgentUsageScanActions on ClientController {
  void startAgentUsagePolling({
    Duration interval = _agentUsagePollingInterval,
  }) {
    if (_disposed || _agentUsagePollingActive) {
      return;
    }
    final pollingInterval = interval > Duration.zero
        ? interval
        : _agentUsagePollingInterval;
    _agentUsagePollingActive = true;
    _scheduleAgentUsagePoll(pollingInterval);
  }

  void stopAgentUsagePolling() {
    _agentUsagePollingActive = false;
    _agentUsagePollingTimer?.cancel();
    _agentUsagePollingTimer = null;
  }

  void _scheduleAgentUsagePoll(Duration interval) {
    if (_disposed || !_agentUsagePollingActive) {
      return;
    }
    _agentUsagePollingTimer = Timer(interval, () {
      _agentUsagePollingTimer = null;
      unawaited(() async {
        await scanAgentUsage(forceRefresh: false, showProgress: false);
        if (!_disposed && _agentUsagePollingActive) {
          _scheduleAgentUsagePoll(interval);
        }
      }());
    });
  }

  Future<void> ensureAgentUsageLoadedAndFresh({int limit = 20}) {
    if (_disposed || agentUsageReport?.isFresh() == true) {
      return Future<void>.value();
    }
    final activeRefresh = _agentUsageRefreshFuture;
    if (activeRefresh != null) {
      return activeRefresh;
    }

    late final Future<void> refresh;
    refresh = _loadAndRefreshAgentUsage(limit: limit).whenComplete(() {
      if (identical(_agentUsageRefreshFuture, refresh)) {
        _agentUsageRefreshFuture = null;
      }
    });
    _agentUsageRefreshFuture = refresh;
    return refresh;
  }

  Future<void> _loadAndRefreshAgentUsage({required int limit}) async {
    if (_disposed || agentUsageReport?.isFresh() == true) {
      return;
    }
    if (agentUsageReport == null) {
      await loadAgentUsageReports(limit: limit, showProgress: false);
    }
    if (!_disposed && agentUsageReport?.isFresh() != true) {
      await scanAgentUsage(forceRefresh: false, showProgress: false);
    }
  }

  Future<void> scanAgentUsage({
    bool forceRefresh = true,
    bool showProgress = true,
  }) {
    final activeScan = _agentUsageScanFuture;
    if (activeScan != null) {
      return activeScan;
    }
    if (isScanningAgentUsage) {
      return Future<void>.value();
    }

    late final Future<void> scan;
    scan =
        _scanAgentUsage(
          forceRefresh: forceRefresh,
          showProgress: showProgress,
        ).whenComplete(() {
          if (identical(_agentUsageScanFuture, scan)) {
            _agentUsageScanFuture = null;
          }
        });
    _agentUsageScanFuture = scan;
    return scan;
  }

  Future<void> _scanAgentUsage({
    required bool forceRefresh,
    required bool showProgress,
  }) async {
    isScanningAgentUsage = true;
    if (showProgress) {
      lastError = '';
      statusCaption = 'Agent usage';
      _setLocalizedStatusMessage(
        '正在刷新 Token 与流量用量。',
        'Refreshing token and traffic usage.',
      );
      _notifyStateChanged();
    }
    try {
      final report = await agentUsageService.scan(
        agentService: agentService,
        forceRefresh: forceRefresh,
      );
      if (_disposed) {
        return;
      }
      agentUsageReport = report;
      _syncAgentAllowanceOverrides(report);
      agentUsageReports = [
        report,
        ...agentUsageReports.where(
          (candidate) => candidate.generatedAt != report.generatedAt,
        ),
      ].take(20).toList(growable: false);
      final taskId = _activeOrchestrationTaskId;
      if (taskId.isNotEmpty) {
        await _evaluateOrchestrationRoutingBoundary(
          taskId: taskId,
          trigger: 'usage-scan',
        );
      }
      if (showProgress) {
        _setLocalizedStatusMessage(
          '已扫描 ${report.agentCount} 个智能体，共 ${report.totalTokens} 个 Token。',
          'Scanned ${report.agentCount} agents and ${report.totalTokens} tokens.',
        );
      }
    } catch (error) {
      if (!_disposed && showProgress) {
        lastError = error.toString();
        _setLocalizedStatusMessage('智能体用量扫描失败。', 'Agent usage scan failed.');
      }
    } finally {
      isScanningAgentUsage = false;
      _notifyStateChanged();
    }
  }

  Future<void> loadAgentUsageReports({
    int limit = 10,
    bool showProgress = true,
  }) async {
    if (isScanningAgentUsage) {
      return;
    }
    isScanningAgentUsage = true;
    if (showProgress) {
      lastError = '';
      statusCaption = 'Agent usage';
    }
    _notifyStateChanged();
    try {
      agentUsageReports = await agentUsageService.reports(
        agentService: agentService,
        limit: limit,
      );
      agentUsageReport = agentUsageReports.isEmpty
          ? null
          : agentUsageReports.first;
      if (agentUsageReport != null) {
        _syncAgentAllowanceOverrides(agentUsageReport!);
        final taskId = _activeOrchestrationTaskId;
        if (taskId.isNotEmpty) {
          await _evaluateOrchestrationRoutingBoundary(
            taskId: taskId,
            trigger: 'usage-report-load',
          );
        }
      }
      if (showProgress) {
        _setLocalizedStatusMessage(
          '已加载 ${agentUsageReports.length} 份用量报表。',
          'Loaded ${agentUsageReports.length} usage reports.',
        );
      }
    } catch (error) {
      if (showProgress) {
        lastError = error.toString();
        _setLocalizedStatusMessage(
          '智能体用量报表加载失败。',
          'Agent usage reports failed to load.',
        );
      }
    } finally {
      isScanningAgentUsage = false;
      _notifyStateChanged();
    }
  }

  void _syncAgentAllowanceOverrides(
    AgentUsageReport report, {
    Set<String> authoritativeAgentIds = const {},
  }) {
    final next = Map<String, List<AgentUsageAllowance>>.from(
      agentAllowanceOverrides,
    );
    for (final agentId in authoritativeAgentIds) {
      final normalized = agentId.trim();
      if (normalized.isNotEmpty) {
        next[normalized] = const [];
      }
    }
    for (final agent in report.agents) {
      final agentId = agent.agentId.trim();
      if (agentId.isNotEmpty && agent.allowances.isNotEmpty) {
        next[agentId] = agent.allowances;
      }
    }
    agentAllowanceOverrides = next;
  }
}
