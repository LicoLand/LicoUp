part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientTargetActions on ClientController {
  Future<void> scanTargets({
    bool showProgress = true,
    bool? surfaceErrors,
    bool forceRescanKnown = false,
  }) async {
    if (_isRefreshingTargets) {
      return;
    }
    final reportErrors = surfaceErrors ?? showProgress;
    _isRefreshingTargets = true;
    final scanGeneration = ++_targetScanGeneration;
    if (showProgress) {
      isScanningTargets = true;
      lastError = '';
      _setLocalizedStatusMessage('正在扫描目标适配器。', 'Scanning target adapters.');
      statusCaption = 'Targets';
      _notifyStateChanged();
    } else if (reportErrors) {
      lastError = '';
    }
    try {
      if (_mobileClientRuntimePlatform) {
        scannedTargets = await _scanMobileRelayTargets();
        _syncAgentOrchestrationPolicy();
        _selectDefaultConversationAgent();
        if (showProgress) {
          _setLocalizedStatusMessage(
            '已扫描 ${scannedTargets.length} 个目标适配器。',
            'Scanned ${scannedTargets.length} target adapters.',
          );
          statusCaption = 'Targets';
        }
        return;
      }

      // Restore last discovery snapshot before any probe so the sidebar is not
      // empty while concurrent per-agent scripts run.
      if (scannedTargets.isEmpty) {
        final cached = await scannedTargetsCacheStore.load(portableData);
        if (cached.isNotEmpty && scanGeneration == _targetScanGeneration) {
          scannedTargets = cached;
          _syncAgentOrchestrationPolicy();
          _selectDefaultConversationAgent();
          _notifyStateChanged();
        }
      }

      final knownIds = scannedTargets
          .map((target) => target.target.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final shouldRescanKnown = forceRescanKnown || showProgress;
      final idsToScan = AgentService.packagedScanTargetIds
          .where((id) => shouldRescanKnown || !knownIds.contains(id))
          .toList(growable: false);

      if (idsToScan.isEmpty) {
        if (showProgress) {
          _setLocalizedStatusMessage(
            '已扫描 ${scannedTargets.length} 个目标适配器。',
            'Scanned ${scannedTargets.length} target adapters.',
          );
          statusCaption = 'Targets';
        }
        return;
      }

      var discovered = 0;
      var failures = 0;
      await Future.wait<void>([
        for (final targetId in idsToScan)
          _scanOneTargetAndUpsert(
            targetId,
            scanGeneration: scanGeneration,
            onDiscovered: () => discovered += 1,
            onFailure: () => failures += 1,
          ),
      ]);
      if (scanGeneration != _targetScanGeneration) {
        return;
      }

      _syncAgentOrchestrationPolicy();
      _selectDefaultConversationAgent();
      await _persistScannedTargetsCache();
      if (failures == idsToScan.length && scannedTargets.isEmpty) {
        if (reportErrors) {
          lastError = 'scan failed';
          _setLocalizedStatusMessage(
            '目标适配器扫描失败。',
            'Failed to scan target adapters.',
          );
          statusCaption = 'Targets';
        }
        return;
      }
      if (showProgress) {
        _setLocalizedStatusMessage(
          '已扫描 ${scannedTargets.length} 个目标适配器（本次新发现 $discovered）。',
          'Scanned ${scannedTargets.length} target adapters ($discovered newly found).',
        );
        statusCaption = 'Targets';
      }
      if (showProgress &&
          selectedConversationAgentId.isNotEmpty &&
          !selectedConversationIsOrchestration &&
          !_mobileClientRuntimePlatform) {
        await loadConversationSessions(selectedConversationAgentId);
      }
    } catch (error) {
      debugPrint('Failed to scan targets: $error');
      if (reportErrors) {
        lastError = error.toString();
        _setLocalizedStatusMessage(
          '目标适配器扫描失败。',
          'Failed to scan target adapters.',
        );
        statusCaption = 'Targets';
      }
    } finally {
      if (scanGeneration == _targetScanGeneration) {
        _isRefreshingTargets = false;
        if (showProgress) {
          isScanningTargets = false;
        }
        _notifyStateChanged();
      }
    }
  }

  Future<void> _scanOneTargetAndUpsert(
    String targetId, {
    required int scanGeneration,
    required VoidCallback onDiscovered,
    required VoidCallback onFailure,
  }) async {
    try {
      final candidate = await agentService.scanOneTarget(targetId);
      if (scanGeneration != _targetScanGeneration) {
        return;
      }
      if (candidate == null) {
        final before = scannedTargets.length;
        scannedTargets = scannedTargets
            .where((target) => target.target != targetId)
            .toList(growable: false);
        if (scannedTargets.length != before) {
          _notifyStateChanged();
          await _persistScannedTargetsCache();
        }
        return;
      }
      final existingIndex = scannedTargets.indexWhere(
        (target) => target.target == candidate.target,
      );
      if (existingIndex < 0) {
        onDiscovered();
        scannedTargets = [...scannedTargets, candidate];
      } else {
        final next = List<TargetCandidate>.from(scannedTargets);
        next[existingIndex] = candidate;
        scannedTargets = next;
      }
      _notifyStateChanged();
      await _persistScannedTargetsCache();
    } catch (error) {
      onFailure();
      debugPrint('Failed to scan target $targetId: $error');
    }
  }

  Future<void> _persistScannedTargetsCache() async {
    try {
      await scannedTargetsCacheStore.save(portableData, scannedTargets);
    } catch (error) {
      debugPrint('Failed to persist scanned targets cache: $error');
    }
  }

  Future<void> _hydrateScannedTargetsCache() async {
    if (_mobileClientRuntimePlatform || scannedTargets.isNotEmpty) {
      return;
    }
    final cached = await scannedTargetsCacheStore.load(portableData);
    if (cached.isEmpty) {
      return;
    }
    scannedTargets = cached;
    _syncAgentOrchestrationPolicy();
    _selectDefaultConversationAgent();
    _notifyStateChanged();
  }

  Future<List<TargetCandidate>> _scanMobileRelayTargets({
    Map<String, dynamic>? pairingStatus,
  }) async {
    final status = pairingStatus;
    if (status == null) {
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      if (!mobileRelayConfig.hasPairing) {
        return const [];
      }
      final refreshedStatus = await mobileRelayService.refreshPairingStatus(
        agentService: agentService,
      );
      mobileRelayConfig = await mobileRelayService.loadConfig(
        agentService: agentService,
      );
      return _mobileRelayTargetsFromStatus(refreshedStatus);
    }
    if (!mobileRelayConfig.hasPairing) {
      return const [];
    }
    return _mobileRelayTargetsFromStatus(status);
  }

  List<TargetCandidate> _mobileRelayTargetsFromStatus(
    Map<String, dynamic> status,
  ) {
    final targets =
        ((status['pairing'] as Map?)?['pc'] as Map?)?['targets'] as List?;
    if (targets == null) {
      return const [];
    }
    return targets
        .whereType<Map>()
        .map(
          (item) => TargetCandidate.fromJson(Map<String, dynamic>.from(item)),
        )
        .where((target) => target.visibleInClient && target.canRelayRuntime)
        .toList(growable: false);
  }

  void _selectDefaultConversationAgent({bool preferDirectAgent = false}) {
    final visibleTargets = scannedTargets
        .where((target) => target.isConversationAgent)
        .where((target) => !isAgentOrchestrationTargetId(target.target))
        .toList(growable: false);
    if (visibleTargets.isEmpty) {
      selectedConversationAgentId = '';
      _preparingNewConversation = false;
      _stopConversationRefreshScheduling();
      return;
    }
    if (!_mobileClientRuntimePlatform &&
        routingModuleAvailable &&
        !preferDirectAgent) {
      if (selectedConversationAgentId.isEmpty ||
          isAgentOrchestrationTargetId(selectedConversationAgentId) ||
          !visibleTargets.any(
            (target) => target.target == selectedConversationAgentId,
          )) {
        selectedConversationAgentId = agentOrchestrationTargetId;
        _preparingNewConversation = false;
        _ensureOrchestrationConversationSession();
        return;
      }
    }
    if (selectedConversationAgentId.isEmpty ||
        isAgentOrchestrationTargetId(selectedConversationAgentId) ||
        !visibleTargets.any(
          (target) => target.target == selectedConversationAgentId,
        )) {
      selectedConversationAgentId = visibleTargets.first.target;
      _preparingNewConversation = false;
    }
  }

  Future<void> addManualTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  }) async {
    final trimmedTarget = target.trim();
    if (trimmedTarget.isEmpty) {
      return;
    }
    isAddingTarget = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在添加 $trimmedTarget 手动目标。',
      'Adding $trimmedTarget manual target.',
    );
    statusCaption = 'Targets';
    _notifyStateChanged();
    try {
      await agentService.addTarget(
        target: trimmedTarget,
        configPath: configPath.trim(),
        binaryPath: binaryPath.trim(),
        historyRoot: historyRoot.trim(),
      );
      _setLocalizedStatusMessage(
        '已添加 $trimmedTarget 手动目标。',
        'Added $trimmedTarget manual target.',
      );
      statusCaption = 'Targets';
      await scanTargets(showProgress: true, forceRescanKnown: true);
      if (lastError.trim().isEmpty) {
        _setLocalizedStatusMessage(
          '已添加 $trimmedTarget 手动目标。',
          'Added $trimmedTarget manual target.',
        );
        statusCaption = 'Targets';
      }
    } catch (error) {
      debugPrint('Failed to add manual target: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '$trimmedTarget 手动目标添加失败。',
        'Failed to add $trimmedTarget manual target.',
      );
      statusCaption = 'Targets';
    } finally {
      isAddingTarget = false;
      _notifyStateChanged();
    }
  }

  Future<void> inspectTarget(String target) async {
    final trimmed = target.trim();
    if (trimmed.isEmpty) {
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage(
      '正在读取 $trimmed 目标适配器。',
      'Inspecting $trimmed target adapter.',
    );
    statusCaption = 'Target inspect';
    _notifyStateChanged();
    try {
      targetInspection = await agentService.inspectTarget(trimmed);
      _setLocalizedStatusMessage(
        '已读取 $trimmed 目标适配器。',
        'Inspected $trimmed target adapter.',
      );
      statusCaption = 'Target inspect';
    } catch (error) {
      debugPrint('Failed to inspect target: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '$trimmed 目标适配器读取失败。',
        'Failed to inspect $trimmed target adapter.',
      );
      statusCaption = 'Target inspect';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> planTargetConfig(String target) async {
    final trimmed = target.trim();
    if (trimmed.isEmpty) {
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage(
      '正在生成 $trimmed MCP 配置计划。',
      'Planning $trimmed MCP config.',
    );
    statusCaption = 'MCP plan';
    _notifyStateChanged();
    try {
      targetConfigPlan = await agentService.planTargetConfig(trimmed);
      _setLocalizedStatusMessage(
        '已生成 $trimmed MCP 配置计划。',
        'Planned $trimmed MCP config.',
      );
      statusCaption = 'MCP plan';
    } catch (error) {
      debugPrint('Failed to plan target config: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '$trimmed MCP 配置计划生成失败。',
        'Failed to plan $trimmed MCP config.',
      );
      statusCaption = 'MCP plan';
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> restoreSnapshot(String snapshotId) async {
    final trimmed = snapshotId.trim();
    if (trimmed.isEmpty) {
      return;
    }
    lastError = '';
    _setLocalizedStatusMessage(
      '正在恢复配置快照。',
      'Restoring configuration snapshot.',
    );
    statusCaption = 'Snapshots';
    _notifyStateChanged();
    try {
      snapshotRestoreResult = await agentService.restoreSnapshot(trimmed);
      _setLocalizedStatusMessage(
        '配置快照已恢复。',
        'Configuration snapshot restored.',
      );
      statusCaption = 'Snapshots';
    } catch (error) {
      debugPrint('Failed to restore snapshot: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage('配置快照恢复失败。', 'Failed to restore snapshot.');
      statusCaption = 'Snapshots';
    } finally {
      _notifyStateChanged();
    }
  }
}
