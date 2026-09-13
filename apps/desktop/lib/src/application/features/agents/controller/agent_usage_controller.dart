import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/agents/contracts/agent_usage_gateway.dart';
import 'package:licoup/src/application/features/agents/controller/agent_usage_daily_cache.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

const Duration defaultAgentUsagePollingInterval = Duration(minutes: 5);

/// Long-lived native projection depth. One backfill scan covers all UI presets.
const int defaultAgentUsageScanHistoryDays = agentUsageDailyCacheMaxDays;

/// Default UI viewport over the native window projection.
const int defaultAgentUsageDisplayHistoryDays = 30;

/// Backward-compatible alias for the default display window.
const int defaultAgentUsageHistoryDays = defaultAgentUsageDisplayHistoryDays;
const int minAgentUsageHistoryDays = 1;
const int maxAgentUsageHistoryDays = agentUsageDailyCacheMaxDays;

typedef AgentUsageStatusSink =
    void Function({
      required String chinese,
      required String english,
      required String caption,
      String errorCode,
    });

/// Owns usage-report state, bounded history, polling, and all single-flight
/// guards. The application composition root only projects this state.
/// Flutter holds one immutable native projection and never merges Maps.
final class AgentUsageController extends ApplicationStateOwner {
  AgentUsageController({
    required this.gateway,
    required this.selectedAgentId,
    required this.onStatus,
  });

  final AgentUsageGateway gateway;
  final String Function() selectedAgentId;
  final AgentUsageStatusSink onStatus;

  /// Viewport-projected report for charts and summaries.
  AgentUsageReport? report;

  /// Retained scan reports (newest first) for history/debug surfaces.
  List<AgentUsageReport> reports = const [];

  /// True only for user-visible refresh operations (force refresh / first load).
  bool scanning = false;

  /// UI viewport in days (7 / 30 / 90 presets). Never drives scan size.
  int historyDays = defaultAgentUsageDisplayHistoryDays;

  AgentUsageReport? _nativeProjection;
  int _projectionGeneration = 0;
  AgentUsageReport? _viewportSource;
  int? _viewportDays;
  Timer? _pollingTimer;
  final Set<Object> _pollingOwners = <Object>{};
  final Object _defaultPollingOwner = Object();
  Duration _pollingInterval = defaultAgentUsagePollingInterval;
  Future<void>? _refreshFuture;
  Future<void>? _scanFuture;
  Future<void>? _modelRefreshFuture;
  Future<void>? _modelDirectoryFuture;
  int _pendingReportLoads = 0;
  bool _loadFailed = false;
  bool _modelRefreshVisible = false;
  bool _modelDirectoryChecked = false;
  bool _modelDirectoryRefreshAttempted = false;
  bool _disposed = false;

  int get pollingOwnerCount => _pollingOwners.length;

  bool get dailyCacheIsEmpty => _nativeProjection == null;

  /// Includes silent cache, scan, and directory work so an empty first view
  /// stays in its loading state until the complete bootstrap has settled.
  /// This is presentation state; the existing operation guards remain owners
  /// of scheduling and explicit refresh visibility.
  bool get loading =>
      scanning ||
      _pendingReportLoads > 0 ||
      _refreshFuture != null ||
      _scanFuture != null ||
      _modelRefreshFuture != null ||
      _modelDirectoryFuture != null;

  bool get loadFailed => _loadFailed;

  /// Backward-compatible alias for tests and facades.
  AgentUsageReport? get scanCache =>
      projectViewport(_nativeProjection, agentUsageDailyCacheMaxDays);

  /// True when the native projection covers 90 days and was refreshed recently.
  bool get hasFreshScanCoverage =>
      _hasFullCoverage() &&
      (_nativeProjection?.hasCurrentParserRevision ?? false) &&
      (_nativeProjection?.isFresh() ?? false);

  AgentUsageAgentSummary? get selectedUsage {
    final agentId = selectedAgentId().trim();
    return agentId.isEmpty ? null : report?.agent(agentId);
  }

  void replaceReport(AgentUsageReport? value) {
    _loadFailed = false;
    _projectionGeneration++;
    _nativeProjection = value;
    _applyViewport();
  }

  void replaceReports(List<AgentUsageReport> value) {
    _loadFailed = false;
    _projectionGeneration++;
    reports = List.unmodifiable(value);
    _nativeProjection = _newestProjection(value);
    _applyViewport();
  }

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
        if (_hasFullCoverage()) {
          await _refreshNativeProjection(showProgress: false);
        } else {
          await scan(
            forceRefresh: false,
            showProgress: false,
            historyDays: defaultAgentUsageScanHistoryDays,
          );
        }
        if (!_disposed && _pollingOwners.isNotEmpty) {
          _schedulePoll(_pollingInterval);
        }
      }());
    });
  }

  Future<void> ensureLoadedAndFresh({int limit = 20}) {
    if (_disposed) {
      return Future<void>.value();
    }
    if (hasFreshScanCoverage) {
      _applyViewport();
      publishChange();
      unawaited(_loadMissingModelDirectory());
      return Future<void>.value();
    }
    final active = _refreshFuture;
    if (active != null) return active;
    late final Future<void> refresh;
    refresh = _loadAndRefresh(limit: limit).whenComplete(() {
      if (identical(_refreshFuture, refresh)) {
        _refreshFuture = null;
      }
      unawaited(_loadMissingModelDirectory());
      if (!_disposed) {
        publishChange();
      }
    });
    _refreshFuture = refresh;
    publishChange();
    return refresh;
  }

  Future<void> _loadAndRefresh({required int limit}) async {
    if (_disposed) {
      return;
    }
    if (hasFreshScanCoverage) {
      _applyViewport();
      publishChange();
      return;
    }
    if (_nativeProjection == null || report == null) {
      await loadReports(limit: limit, showProgress: false);
    }
    if (_disposed) {
      return;
    }
    if (hasFreshScanCoverage) {
      _applyViewport();
      publishChange();
      return;
    }
    if (!_hasFullCoverage() ||
        !(_nativeProjection?.hasCurrentParserRevision ?? false)) {
      await scan(
        forceRefresh: false,
        showProgress: false,
        historyDays: defaultAgentUsageScanHistoryDays,
      );
    } else if (!_isFreshToday()) {
      await _refreshNativeProjection(showProgress: false);
    }
    if (_disposed) {
      return;
    }
    _applyViewport();
    publishChange();
  }

  /// Changes only the viewport. Never triggers scan, slice, or gateway I/O.
  Future<void> setHistoryDays(int value) async {
    final normalized = value
        .clamp(minAgentUsageHistoryDays, maxAgentUsageHistoryDays)
        .toInt();
    if (normalized == historyDays) return;
    historyDays = normalized;
    _applyViewport();
    publishChange();
  }

  void _applyViewport() {
    if (identical(_viewportSource, _nativeProjection) &&
        _viewportDays == historyDays &&
        report != null) {
      return;
    }
    _viewportSource = _nativeProjection;
    _viewportDays = historyDays;
    report = projectViewport(_nativeProjection, historyDays);
  }

  AgentUsageReport _normalizeScanReport(
    AgentUsageReport scanned,
    int scanDays,
  ) {
    if (scanned.windowDays >= scanDays) {
      return scanned;
    }
    return scanned.copyWith(window: {...scanned.window, 'days': scanDays});
  }

  Future<void> scan({
    bool forceRefresh = true,
    bool showProgress = true,
    int? historyDays,
  }) {
    final refreshingModels = _modelRefreshFuture;
    if (refreshingModels != null) {
      return refreshingModels;
    }
    final active = _scanFuture;
    if (active != null) return active;
    if ((scanning && showProgress) || _disposed) {
      return Future<void>.value();
    }
    late final Future<void> scanFuture;
    scanFuture =
        _scan(
          forceRefresh: forceRefresh,
          showProgress: showProgress,
          historyDays: historyDays,
        ).whenComplete(() {
          if (identical(_scanFuture, scanFuture)) {
            _scanFuture = null;
          }
          if (!_disposed) {
            publishChange();
          }
        });
    _scanFuture = scanFuture;
    publishChange();
    return scanFuture;
  }

  Future<void> _scan({
    required bool forceRefresh,
    required bool showProgress,
    int? historyDays,
    bool refreshModelDirectory = false,
  }) async {
    final scanDays = historyDays ?? defaultAgentUsageScanHistoryDays;
    bool visible() =>
        showProgress || (refreshModelDirectory && _modelRefreshVisible);
    if (visible()) {
      _showScanProgress();
    }
    try {
      var registryUnavailable = false;
      if (refreshModelDirectory) {
        try {
          registryUnavailable = !(await gateway.refreshModelRegistry()).ok;
        } on Object {
          registryUnavailable = true;
        }
        if (_disposed) {
          return;
        }
      }
      final next = await gateway.scan(
        forceRefresh: forceRefresh,
        historyDays: scanDays,
      );
      if (_disposed) return;
      final normalized = _normalizeScanReport(next, scanDays);
      _loadFailed = false;
      _projectionGeneration++;
      _nativeProjection = normalized;
      _applyViewport();
      if (scanDays >= agentUsageDailyCacheMaxDays) {
        reports = List.unmodifiable(
          [
            normalized,
            ...reports.where(
              (candidate) => candidate.generatedAt != normalized.generatedAt,
            ),
          ].take(20),
        );
      }
      if (visible()) {
        final shown = report ?? normalized;
        onStatus(
          chinese: registryUnavailable
              ? '模型目录刷新暂不可用，已使用本地目录更新用量。'
              : '已扫描 ${shown.agentCount} 个智能体，共 ${shown.totalTokens} 个 Token。',
          english: registryUnavailable
              ? 'Model directory refresh is unavailable. Usage was updated with the local directory.'
              : 'Scanned ${shown.agentCount} agents and ${shown.totalTokens} tokens.',
          caption: 'Agent usage',
          errorCode: registryUnavailable
              ? 'model_registry_refresh_unavailable'
              : '',
        );
      }
    } catch (_) {
      _loadFailed = true;
      if (!_disposed && visible()) {
        onStatus(
          chinese: '智能体用量扫描失败。',
          english: 'Agent usage scan failed.',
          caption: 'Agent usage',
          errorCode: 'agent_usage_scan_failed',
        );
      }
    } finally {
      if (visible()) {
        scanning = false;
      }
      if (!_disposed) publishChange();
    }
  }

  void _showScanProgress() {
    scanning = true;
    onStatus(
      chinese: '正在刷新本机 Token 用量。',
      english: 'Refreshing local token usage.',
      caption: 'Agent usage',
    );
    publishChange();
  }

  /// Explicit refresh joins a local scan, refreshes the public registry, and
  /// scans again using the resulting native model identities.
  Future<void> refreshModelDirectoryAndScan() =>
      _refreshModelDirectoryAndScan(showProgress: true);

  Future<void> _refreshModelDirectoryAndScan({required bool showProgress}) {
    if (_disposed) {
      return Future<void>.value();
    }
    final active = _modelRefreshFuture;
    if (active != null) {
      if (showProgress && !_modelRefreshVisible) {
        _modelRefreshVisible = true;
        _showScanProgress();
      }
      return active;
    }
    _modelRefreshVisible = showProgress;
    _modelDirectoryRefreshAttempted = true;
    final precedingScan = _scanFuture;
    late final Future<void> refresh;
    refresh =
        (() async {
          await precedingScan;
          if (_disposed) {
            return;
          }
          await _scan(
            forceRefresh: true,
            showProgress: showProgress,
            refreshModelDirectory: true,
          );
        })().whenComplete(() {
          if (identical(_modelRefreshFuture, refresh)) {
            _modelRefreshFuture = null;
            _modelRefreshVisible = false;
          }
          if (!_disposed) {
            publishChange();
          }
        });
    _modelRefreshFuture = refresh;
    publishChange();
    return refresh;
  }

  /// Bootstrap only an absent directory after the local statistics are ready.
  /// The per-controller check is consumed before I/O, so failure never causes
  /// polling or repeated panel mounts to initiate another network request.
  Future<void> _loadMissingModelDirectory() {
    if (_disposed || _modelDirectoryChecked) {
      return _modelDirectoryFuture ?? Future<void>.value();
    }
    _modelDirectoryChecked = true;
    late final Future<void> pending;
    pending = _readMissingModelDirectory().whenComplete(() {
      if (identical(_modelDirectoryFuture, pending)) {
        _modelDirectoryFuture = null;
      }
      if (!_disposed) {
        publishChange();
      }
    });
    _modelDirectoryFuture = pending;
    publishChange();
    return pending;
  }

  Future<void> _readMissingModelDirectory() async {
    try {
      final registry = await gateway.readModelRegistry();
      if (_disposed ||
          _modelDirectoryRefreshAttempted ||
          !registry.ok ||
          registry.status != 'empty') {
        return;
      }
      await _refreshModelDirectoryAndScan(showProgress: false);
    } on Object {
      // Existing statistics remain usable. Explicit refresh can retry.
    }
  }

  Future<void> _refreshNativeProjection({required bool showProgress}) async {
    await scan(
      forceRefresh: false,
      showProgress: showProgress,
      historyDays: defaultAgentUsageScanHistoryDays,
    );
  }

  Future<void> loadReports({int limit = 10, bool showProgress = true}) async {
    if ((scanning && showProgress) || _disposed) return;
    _pendingReportLoads++;
    final projectionGeneration = _projectionGeneration;
    if (showProgress) {
      scanning = true;
      onStatus(chinese: '', english: '', caption: 'Agent usage');
    }
    publishChange();
    try {
      final retained = await gateway.reports(limit: limit);
      // A scan may publish fresher model identities while this older local
      // read is pending. Never roll its projection or retained history back.
      if (_disposed || projectionGeneration != _projectionGeneration) {
        return;
      }
      reports = List.unmodifiable(retained);
      _loadFailed = false;
      if (reports.isEmpty) {
        if (_nativeProjection == null) {
          report = null;
        } else {
          _applyViewport();
        }
      } else {
        _nativeProjection = _newestProjection(reports);
        _applyViewport();
      }
      if (showProgress) {
        onStatus(
          chinese: '已加载 ${reports.length} 份用量报表。',
          english: 'Loaded ${reports.length} usage reports.',
          caption: 'Agent usage',
        );
      }
    } catch (_) {
      if (!_disposed && projectionGeneration == _projectionGeneration) {
        _loadFailed = true;
      }
      if (showProgress) {
        onStatus(
          chinese: '智能体用量报表加载失败。',
          english: 'Agent usage reports failed to load.',
          caption: 'Agent usage',
          errorCode: 'agent_usage_reports_failed',
        );
      }
    } finally {
      _pendingReportLoads--;
      if (showProgress) {
        scanning = false;
      }
      if (!_disposed) publishChange();
    }
  }

  bool _hasFullCoverage() {
    final source = _nativeProjection;
    if (source == null) {
      return false;
    }
    return source.windowDays >= agentUsageDailyCacheMaxDays;
  }

  bool _isFreshToday() {
    return _nativeProjection?.isFresh() ?? false;
  }

  AgentUsageReport? _newestProjection(List<AgentUsageReport> value) {
    if (value.isEmpty) {
      return null;
    }
    AgentUsageReport newest = value.first;
    for (final candidate in value.skip(1)) {
      final newestTime = DateTime.tryParse(newest.generatedAt)?.toUtc();
      final candidateTime = DateTime.tryParse(candidate.generatedAt)?.toUtc();
      if (newestTime == null) {
        newest = candidate;
        continue;
      }
      if (candidateTime != null && candidateTime.isAfter(newestTime)) {
        newest = candidate;
      }
    }
    return newest;
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
