import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/targets/controller/target_scan_coordinator.dart';
import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/application/features/targets/policy/target_scan_reducer.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';

typedef TargetStatusSink = void Function(TargetStatusUpdate update);

class TargetStatusUpdate {
  const TargetStatusUpdate({
    required this.chinese,
    required this.english,
    this.caption = 'Targets',
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String caption;
  final String errorCode;
}

/// Owns target discovery, incremental scheduling, target tools and tab order.
/// It deliberately knows nothing about ClientController or UI navigation.
class TargetController extends ApplicationStateOwner {
  TargetController({
    required TargetManagementGateway gateway,
    required TargetSnapshotRepository snapshotRepository,
    required TargetTabOrderRepository tabOrderRepository,
    required Object portableData,
    required Iterable<String> packagedTargetIds,
    required bool Function() isMobileRuntime,
    required Future<List<TargetCandidate>> Function() scanMobileTargets,
    required void Function() onTargetsSettled,
    required Future<void> Function() loadSelectedConversation,
    required bool Function() shouldLoadSelectedConversation,
    required TargetStatusSink onStatus,
  }) : _gateway = gateway,
       _scanCoordinator = TargetScanCoordinator(gateway),
       _snapshotRepository = snapshotRepository,
       _tabOrderRepository = tabOrderRepository,
       _portableData = portableData,
       _packagedTargetIds = List.unmodifiable(packagedTargetIds),
       _isMobileRuntime = isMobileRuntime,
       _scanMobileTargets = scanMobileTargets,
       _onTargetsSettled = onTargetsSettled,
       _loadSelectedConversation = loadSelectedConversation,
       _shouldLoadSelectedConversation = shouldLoadSelectedConversation,
       _onStatus = onStatus;

  final TargetManagementGateway _gateway;
  final TargetScanCoordinator _scanCoordinator;
  final TargetSnapshotRepository _snapshotRepository;
  final TargetTabOrderRepository _tabOrderRepository;
  final Object _portableData;
  final List<String> _packagedTargetIds;
  final bool Function() _isMobileRuntime;
  final Future<List<TargetCandidate>> Function() _scanMobileTargets;
  final void Function() _onTargetsSettled;
  final Future<void> Function() _loadSelectedConversation;
  final bool Function() _shouldLoadSelectedConversation;
  final TargetStatusSink _onStatus;

  List<TargetCandidate> _targets = const [];
  List<String> _tabOrder = const [];
  List<String> _pinnedIds = const [];
  bool _pinsInitialized = false;
  Map<String, dynamic>? inspection;
  Map<String, dynamic>? snapshotRestoreResult;
  bool isScanning = false;
  bool isAdding = false;
  bool _disposed = false;
  bool _refreshing = false;
  Completer<void>? _refreshCompletion;
  Future<void>? _queuedForcedScan;
  final Set<String> _nativeModelCatalogRefreshedIds = {};
  final Set<String> _nativeModelCatalogInFlightIds = {};
  final Set<String> _cachedTargetIds = {};
  bool _cachedTargetsNeedRefresh = false;
  int _scanGeneration = 0;
  String _lastErrorCode = '';

  List<TargetCandidate> get targets => _targets;
  List<String> get tabOrder => _tabOrder;
  List<String> get pinnedConversationTargetIds =>
      TargetPolicy.effectivePinnedConversationTargetIds(
        persistedPinnedIds: _pinnedIds,
        pinsInitialized: _pinsInitialized,
      );
  String get lastErrorCode => _lastErrorCode;

  void replaceTargets(List<TargetCandidate> value) {
    _targets = List.unmodifiable(value);
    _cachedTargetIds.clear();
    _cachedTargetsNeedRefresh = false;
    publishChange();
  }

  void replaceTabOrder(List<String> value) {
    _tabOrder = List.unmodifiable(value);
    publishChange();
  }

  void replacePinnedConversationTargetIds(List<String> value) {
    _pinnedIds = List.unmodifiable(value);
    _pinsInitialized = true;
    publishChange();
  }

  void replaceInspection(Map<String, dynamic>? value) {
    inspection = value;
    publishChange();
  }

  void replaceSnapshotRestoreResult(Map<String, dynamic>? value) {
    snapshotRestoreResult = value;
    publishChange();
  }

  Future<void> loadTabOrder() async {
    _tabOrder = await _tabOrderRepository.load(_portableData);
    _pinnedIds = await _tabOrderRepository.loadPinned(_portableData);
    _pinsInitialized = await _tabOrderRepository.hasCustomPinnedIds(
      _portableData,
    );
    publishChange();
  }

  bool isConversationTargetPinned(String targetId) {
    final normalized = targetId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return pinnedConversationTargetIds.contains(normalized);
  }

  Future<void> toggleConversationTargetPinned(String targetId) async {
    final normalized = targetId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final current = pinnedConversationTargetIds.toList(growable: true);
    if (current.contains(normalized)) {
      current.remove(normalized);
    } else {
      current.add(normalized);
    }
    _pinnedIds = List.unmodifiable(current);
    _pinsInitialized = true;
    publishChange();
    try {
      await _tabOrderRepository.savePinned(_portableData, _pinnedIds);
    } catch (_) {
      _lastErrorCode = 'target_pin_save_failed';
      _onStatus(
        const TargetStatusUpdate(
          chinese: '智能体置顶状态保存失败。',
          english: 'Failed to save the agent pin state.',
          caption: 'Agent pins',
          errorCode: 'target_pin_save_failed',
        ),
      );
      publishChange();
    }
  }

  Future<void> hydrateCache() async {
    if (_isMobileRuntime() || _targets.isNotEmpty) return;
    final cached = await _loadCachedTargets();
    if (cached.isEmpty) return;
    _targets = List.unmodifiable(cached);
    _cachedTargetIds
      ..clear()
      ..addAll(cached.map((target) => target.target));
    _cachedTargetsNeedRefresh = _cachedTargetIds.isNotEmpty;
    _onTargetsSettled();
    publishChange();
  }

  Future<void> scan({
    bool showProgress = true,
    bool? surfaceErrors,
    bool forceRescanKnown = false,
  }) => _scan(
    showProgress: showProgress,
    surfaceErrors: surfaceErrors,
    forceRescanKnown: forceRescanKnown,
    coalescedExecution: false,
  );

  Future<void> _scan({
    required bool showProgress,
    required bool? surfaceErrors,
    required bool forceRescanKnown,
    required bool coalescedExecution,
  }) async {
    if (_disposed) return;
    if (_refreshing) {
      final active = _refreshCompletion;
      if (!forceRescanKnown) {
        if (active != null) await active.future;
        return;
      }
      if (coalescedExecution) {
        if (active != null) await active.future;
        if (_disposed) return;
        return _scan(
          showProgress: showProgress,
          surfaceErrors: surfaceErrors,
          forceRescanKnown: true,
          coalescedExecution: true,
        );
      }
      final queued = _queuedForcedScan;
      if (queued != null) return queued;
      late final Future<void> nextForcedScan;
      nextForcedScan =
          () async {
            if (active != null) await active.future;
            if (_disposed) return;
            await _scan(
              showProgress: showProgress,
              surfaceErrors: surfaceErrors,
              forceRescanKnown: true,
              coalescedExecution: true,
            );
          }().whenComplete(() {
            if (identical(_queuedForcedScan, nextForcedScan)) {
              _queuedForcedScan = null;
            }
          });
      _queuedForcedScan = nextForcedScan;
      return nextForcedScan;
    }
    final reportErrors = surfaceErrors ?? showProgress;
    _refreshing = true;
    final refreshCompletion = Completer<void>();
    _refreshCompletion = refreshCompletion;
    final generation = ++_scanGeneration;
    if (showProgress) {
      isScanning = true;
      _lastErrorCode = '';
      _onStatus(
        const TargetStatusUpdate(
          chinese: '正在扫描目标适配器。',
          english: 'Scanning target adapters.',
        ),
      );
      publishChange();
    } else if (reportErrors) {
      _lastErrorCode = '';
    }
    // Conversation history loading stays outside the scan critical section:
    // a slow or failing history read must neither be reported as a scan
    // failure nor hold the refresh gate for later scans.
    var loadSelectedConversation = false;
    try {
      if (_isMobileRuntime()) {
        final targets = await _scanMobileTargets();
        if (!_isCurrentScan(generation)) return;
        _targets = List.unmodifiable(targets);
        _onTargetsSettled();
        if (showProgress) _emitScanComplete();
        return;
      }
      if (_targets.isEmpty) {
        final cached = await _loadCachedTargets();
        if (!_isCurrentScan(generation)) return;
        if (cached.isNotEmpty) {
          _targets = List.unmodifiable(cached);
          _cachedTargetIds
            ..clear()
            ..addAll(cached.map((target) => target.target));
          _cachedTargetsNeedRefresh = _cachedTargetIds.isNotEmpty;
          _onTargetsSettled();
          publishChange();
        }
      }
      final ids = TargetPolicy.incrementalScanIds(
        packagedIds: _packagedTargetIds,
        currentTargets: _targets,
        // Cached discovery is only a paint-fast snapshot. Runtime binaries can
        // move between launches, so the first quiet scan must revalidate known
        // targets instead of treating stale executable bindings as current.
        rescanKnown:
            forceRescanKnown || showProgress || _cachedTargetsNeedRefresh,
      );
      if (ids.isEmpty) {
        if (showProgress) _emitScanComplete();
        return;
      }
      final request = TargetScanRequest(targetIds: ids);
      final batch = await _scanCoordinator.scan(request);
      if (!_isCurrentScan(generation)) return;
      final reduction = TargetScanReducer.reduce(
        currentTargets: _targets,
        requestedTargetIds: request.targetIds,
        batch: batch,
        replaceModelCatalog: false,
      );
      for (final slot in reduction.successfulSlots) {
        _markCachedTargetVerified(slot.targetId);
      }
      if (!_sameTargets(_targets, reduction.targets)) {
        _targets = reduction.targets;
      }
      _onTargetsSettled();
      await _persistCache();
      if (!_isCurrentScan(generation)) return;
      final failures = reduction.failedTargetIds.length;
      if (failures == 0) {
        _cachedTargetsNeedRefresh = false;
      }
      if (failures == request.targetIds.length && _targets.isEmpty) {
        if (reportErrors) {
          _lastErrorCode = 'target_scan_failed';
          _onStatus(
            const TargetStatusUpdate(
              chinese: '目标适配器扫描失败。',
              english: 'Failed to scan target adapters.',
              errorCode: 'target_scan_failed',
            ),
          );
        }
        return;
      }
      if (showProgress) {
        _onStatus(
          TargetStatusUpdate(
            chinese:
                '已扫描 ${_targets.length} 个目标适配器（本次新发现 ${reduction.discoveredCount}）。',
            english:
                'Scanned ${_targets.length} target adapters (${reduction.discoveredCount} newly found).',
          ),
        );
      }
      if (showProgress && _shouldLoadSelectedConversation()) {
        loadSelectedConversation = true;
      }
    } catch (_) {
      if (!_isCurrentScan(generation)) return;
      if (reportErrors) {
        _lastErrorCode = 'target_scan_failed';
        _onStatus(
          const TargetStatusUpdate(
            chinese: '目标适配器扫描失败。',
            english: 'Failed to scan target adapters.',
            errorCode: 'target_scan_failed',
          ),
        );
      }
    } finally {
      if (_isCurrentScan(generation)) {
        _refreshing = false;
        if (showProgress) isScanning = false;
        publishChange();
      }
      if (identical(_refreshCompletion, refreshCompletion)) {
        _refreshCompletion = null;
        if (!refreshCompletion.isCompleted) refreshCompletion.complete();
      }
    }
    if (loadSelectedConversation) {
      try {
        await _loadSelectedConversation();
      } catch (_) {
        // History load failures surface on the conversation surface only;
        // the scan itself succeeded and must not report them.
      }
    }
  }

  /// Revalidates only the selected conversation target. Cached discovery
  /// metadata intentionally carries no executable authority, so reopening an
  /// agent restores its current binding before the selection flow returns.
  /// Opening that Agent's conversation interface also refreshes its native
  /// model catalog (CLI list or named store) without running that lookup for
  /// unused agents.
  Future<bool> ensureConversationRuntimeBinding(String targetId) async {
    final id = targetId.trim();
    if (_disposed || id.isEmpty || _isMobileRuntime()) {
      return _targets.any(
        (target) => target.target == id && target.canRelayRuntime,
      );
    }
    TargetCandidate? current;
    for (final target in _targets) {
      if (target.target == id) {
        current = target;
        break;
      }
    }
    if (current != null && current.canRelayRuntime) {
      ensureSelectedAgentModelCatalog(id);
      return true;
    }
    if (!_cachedTargetIds.contains(id)) {
      return false;
    }
    final refreshCatalog = !_nativeModelCatalogRefreshedIds.contains(id);
    return _revalidateConversationRuntimeBinding(
      id,
      enableAgentCliModelLookup: refreshCatalog,
    );
  }

  /// Loads the native model catalog for an Agent whose conversation interface
  /// the user just opened. Unused-agent discovery still omits this lookup.
  /// [forceEntry] bypasses an already settled refresh (conversation re-entry)
  /// while an in-flight lookup is always joined.
  void ensureSelectedAgentModelCatalog(
    String targetId, {
    bool forceEntry = false,
  }) {
    final id = targetId.trim();
    if (_disposed || id.isEmpty || _isMobileRuntime()) {
      return;
    }
    TargetCandidate? current;
    for (final target in _targets) {
      if (target.target == id) {
        current = target;
        break;
      }
    }
    if (current == null) {
      return;
    }
    _scheduleNativeModelCatalogRefresh(id, current, forceEntry: forceEntry);
  }

  bool isRefreshingNativeModelCatalog(String targetId) {
    return _nativeModelCatalogInFlightIds.contains(targetId.trim());
  }

  Future<void> refreshAgentModelCatalogs(Iterable<String> targetIds) async {
    if (_disposed || _isMobileRuntime()) return;
    final ids = <String>[];
    final seen = <String>{};
    for (final targetId in targetIds) {
      final id = targetId.trim();
      if (id.isNotEmpty && seen.add(id)) ids.add(id);
    }
    if (ids.isEmpty) return;
    final request = TargetScanRequest(
      targetIds: ids,
      enableAgentCliModelLookup: true,
    );
    final TargetScanBatch batch;
    try {
      batch = await _scanCoordinator.scan(request);
    } catch (_) {
      return;
    }
    if (_disposed) return;
    final reduction = TargetScanReducer.reduce(
      currentTargets: _targets,
      requestedTargetIds: request.targetIds,
      batch: batch,
      replaceModelCatalog: true,
    );
    for (final slot in reduction.successfulSlots) {
      final candidate = slot.candidate;
      if (candidate != null &&
          TargetPolicy.hasSelectedAgentModelCatalog(candidate)) {
        _nativeModelCatalogRefreshedIds.add(slot.targetId);
      }
    }
    if (_sameTargets(_targets, reduction.targets)) return;
    _targets = reduction.targets;
    _onTargetsSettled();
    publishChange();
    await _persistCache();
  }

  void _scheduleNativeModelCatalogRefresh(
    String targetId,
    TargetCandidate current, {
    bool forceEntry = false,
  }) {
    if (!forceEntry && _nativeModelCatalogRefreshedIds.contains(targetId)) {
      return;
    }
    if (_nativeModelCatalogInFlightIds.contains(targetId)) {
      return;
    }
    _nativeModelCatalogInFlightIds.add(targetId);
    publishChange();
    unawaited(
      _revalidateConversationRuntimeBinding(
        targetId,
        enableAgentCliModelLookup: true,
      ).whenComplete(() {
        _nativeModelCatalogInFlightIds.remove(targetId);
        if (!_disposed) publishChange();
      }),
    );
  }

  Future<bool> _revalidateConversationRuntimeBinding(
    String targetId, {
    required bool enableAgentCliModelLookup,
  }) async {
    try {
      final candidate = await _probeTarget(
        targetId,
        enableAgentCliModelLookup: enableAgentCliModelLookup,
      );
      if (_disposed) return false;
      _markCachedTargetVerified(targetId);
      if (candidate == null) return false;
      final next = TargetPolicy.mergeProbe(
        _targets,
        targetId,
        candidate,
        replaceModelCatalog: enableAgentCliModelLookup,
      );
      if (enableAgentCliModelLookup &&
          TargetPolicy.hasSelectedAgentModelCatalog(candidate)) {
        _nativeModelCatalogRefreshedIds.add(targetId);
      }
      if (!_sameTargets(_targets, next)) {
        _targets = next;
        _onTargetsSettled();
        publishChange();
        await _persistCache();
      }
      return candidate.canRelayRuntime;
    } catch (_) {
      if (!_disposed) {
        _lastErrorCode = 'target_scan_failed';
        _onStatus(
          const TargetStatusUpdate(
            chinese: '目标适配器扫描失败。',
            english: 'Failed to scan target adapters.',
            errorCode: 'target_scan_failed',
          ),
        );
        publishChange();
      }
      return false;
    }
  }

  Future<TargetCandidate?> _probeTarget(
    String targetId, {
    bool enableAgentCliModelLookup = false,
  }) {
    final request = TargetScanRequest(
      targetIds: [targetId],
      enableAgentCliModelLookup: enableAgentCliModelLookup,
    );
    return _scanCoordinator.scan(request).then((batch) {
      for (final slot in batch.slots) {
        if (slot.targetId == targetId && !slot.failed) {
          return slot.candidate;
        }
      }
      return null;
    });
  }

  void _markCachedTargetVerified(String targetId) {
    _cachedTargetIds.remove(targetId);
    if (_cachedTargetIds.isEmpty) {
      _cachedTargetsNeedRefresh = false;
    }
  }

  bool _sameTargets(List<TargetCandidate> a, List<TargetCandidate> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index += 1) {
      if (a[index].toJson().toString() != b[index].toJson().toString()) {
        return false;
      }
    }
    return true;
  }

  bool _isCurrentScan(int generation) =>
      !_disposed && generation == _scanGeneration;

  Future<void> _persistCache() async {
    try {
      await _snapshotRepository.save(_portableData, _targets);
    } catch (_) {
      // Cache persistence is best effort and must not expose local paths.
    }
  }

  Future<List<TargetCandidate>> _loadCachedTargets() async {
    try {
      return await _snapshotRepository.load(_portableData);
    } catch (_) {
      // Discovery remains authoritative when the local acceleration cache is
      // unavailable, corrupt, or not yet backed by a platform data provider.
      return const [];
    }
  }

  void _emitScanComplete() {
    _onStatus(
      TargetStatusUpdate(
        chinese: '已扫描 ${_targets.length} 个目标适配器。',
        english: 'Scanned ${_targets.length} target adapters.',
      ),
    );
  }

  Future<void> addManualTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) async {
    final id = target.trim();
    if (id.isEmpty) return;
    isAdding = true;
    _lastErrorCode = '';
    _onStatus(
      TargetStatusUpdate(
        chinese: '正在添加 $id 手动目标。',
        english: 'Adding $id manual target.',
      ),
    );
    publishChange();
    try {
      await _gateway.addTarget(
        target: id,
        configPath: configPath.trim(),
        binaryPath: binaryPath.trim(),
        historyRoot: historyRoot.trim(),
        location: location.trim(),
        runtimeConnection: runtimeConnection,
      );
      await scan(showProgress: true, forceRescanKnown: true);
      if (_lastErrorCode.isEmpty) {
        _onStatus(
          TargetStatusUpdate(
            chinese: '已添加 $id 手动目标。',
            english: 'Added $id manual target.',
          ),
        );
      }
    } catch (_) {
      _lastErrorCode = 'target_add_failed';
      _onStatus(
        TargetStatusUpdate(
          chinese: '$id 手动目标添加失败。',
          english: 'Failed to add $id manual target.',
          errorCode: 'target_add_failed',
        ),
      );
    } finally {
      isAdding = false;
      publishChange();
    }
  }

  Future<void> inspectTarget(String target) async {
    final id = target.trim();
    if (id.isEmpty) return;
    await _runTool(
      busy: TargetStatusUpdate(
        chinese: '正在读取 $id 目标适配器。',
        english: 'Inspecting $id target adapter.',
        caption: 'Target inspect',
      ),
      failure: TargetStatusUpdate(
        chinese: '$id 目标适配器读取失败。',
        english: 'Failed to inspect $id target adapter.',
        caption: 'Target inspect',
        errorCode: 'target_inspect_failed',
      ),
      action: () async {
        inspection = await _gateway.inspectTarget(id);
        _onStatus(
          TargetStatusUpdate(
            chinese: '已读取 $id 目标适配器。',
            english: 'Inspected $id target adapter.',
            caption: 'Target inspect',
          ),
        );
      },
    );
  }

  Future<void> restoreSnapshot(String snapshotId) async {
    final id = snapshotId.trim();
    if (id.isEmpty) return;
    await _runTool(
      busy: const TargetStatusUpdate(
        chinese: '正在恢复配置快照。',
        english: 'Restoring configuration snapshot.',
        caption: 'Snapshots',
      ),
      failure: const TargetStatusUpdate(
        chinese: '配置快照恢复失败。',
        english: 'Failed to restore snapshot.',
        caption: 'Snapshots',
        errorCode: 'snapshot_restore_failed',
      ),
      action: () async {
        snapshotRestoreResult = await _gateway.restoreSnapshot(id);
        _onStatus(
          const TargetStatusUpdate(
            chinese: '配置快照已恢复。',
            english: 'Configuration snapshot restored.',
            caption: 'Snapshots',
          ),
        );
      },
    );
  }

  Future<void> _runTool({
    required TargetStatusUpdate busy,
    required TargetStatusUpdate failure,
    required Future<void> Function() action,
  }) async {
    _lastErrorCode = '';
    _onStatus(busy);
    publishChange();
    try {
      await action();
    } catch (_) {
      _lastErrorCode = failure.errorCode;
      _onStatus(failure);
    } finally {
      publishChange();
    }
  }

  List<TargetCandidate> orderedConversationTargets(
    Iterable<TargetCandidate> targets,
  ) {
    return TargetPolicy.orderedConversationTargets(
      targets: targets,
      persistedOrder: _tabOrder,
      pinnedIds: pinnedConversationTargetIds,
    );
  }

  Future<void> reorderConversationAgentTabs(
    List<TargetCandidate> visibleTargets,
    int oldIndex,
    int newIndex,
  ) async {
    final next = TargetPolicy.reorderedTabIds(
      visibleTargets: visibleTargets,
      persistedOrder: _tabOrder,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    if (next == null) return;
    _tabOrder = next;
    publishChange();
    try {
      await _tabOrderRepository.save(_portableData, _tabOrder);
    } catch (_) {
      _lastErrorCode = 'target_tab_order_save_failed';
      _onStatus(
        const TargetStatusUpdate(
          chinese: '智能体标签页顺序保存失败。',
          english: 'Failed to save the agent tab order.',
          caption: 'Agent tabs',
          errorCode: 'target_tab_order_save_failed',
        ),
      );
      publishChange();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scanGeneration += 1;
    _refreshing = false;
    final refreshCompletion = _refreshCompletion;
    _refreshCompletion = null;
    if (refreshCompletion != null && !refreshCompletion.isCompleted) {
      refreshCompletion.complete();
    }
    _queuedForcedScan = null;
    _cachedTargetIds.clear();
    isScanning = false;
    super.dispose();
  }
}
