part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientProxyBridgeActions on ClientController {
  static const _defaultProxyBridgeTargets = [
    'codex',
    'claude-code',
    'antigravity',
    'opencode',
    'cursor',
    'kimi-code',
  ];

  bool get proxyBridgeEnabled {
    final document = proxyBridgeStatus?['document'];
    if (document is Map) {
      return document['enabled'] == true;
    }
    return false;
  }

  String get proxyBridgeProxyUrl {
    final documentProxy = proxyBridgeStatus?['document'] is Map
        ? (proxyBridgeStatus!['document'] as Map)['proxy']
        : null;
    if (documentProxy is Map) {
      final value = (documentProxy['proxyUrl'] ?? '').toString();
      if (value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    final detectedProxy = proxyBridgeStatus?['proxy'];
    if (detectedProxy is Map) {
      return (detectedProxy['proxyUrl'] ?? '').toString().trim();
    }
    return '';
  }

  bool get proxyBridgeReachable {
    final proxy = proxyBridgeStatus?['proxy'];
    if (proxy is Map) {
      return proxy['reachable'] == true;
    }
    final document = proxyBridgeStatus?['document'];
    if (document is Map && document['proxy'] is Map) {
      return (document['proxy'] as Map)['reachable'] == true;
    }
    return false;
  }

  List<String> get proxyBridgeAvailableTargets {
    final scanned = scannedTargets
        .where((target) => target.visibleInClient)
        .map((target) => target.target)
        .where((target) => _allProxyBridgeTargets.contains(target))
        .toList(growable: true);
    if (scanned.isNotEmpty) {
      return List.unmodifiable(scanned);
    }
    return _defaultProxyBridgeTargets;
  }

  List<String> get _selectedProxyBridgeTargets {
    if (proxyBridgeSelectedTargets.isNotEmpty) {
      return proxyBridgeSelectedTargets
          .where(_allProxyBridgeTargets.contains)
          .toList(growable: false);
    }
    final document = proxyBridgeStatus?['document'];
    if (document is Map && document['targets'] is List) {
      final targets = (document['targets'] as List)
          .whereType<Map>()
          .map((item) => (item['target'] ?? '').toString())
          .where(_allProxyBridgeTargets.contains)
          .toList(growable: false);
      if (targets.isNotEmpty) {
        return targets;
      }
    }
    return proxyBridgeAvailableTargets;
  }

  bool isProxyBridgeTargetSelected(String target) {
    return _selectedProxyBridgeTargets.contains(target);
  }

  void setProxyBridgeTargetSelected(String target, bool selected) {
    final next = Set<String>.from(_selectedProxyBridgeTargets);
    if (selected) {
      next.add(target);
    } else {
      next.remove(target);
    }
    proxyBridgeSelectedTargets = next;
    _notifyStateChanged();
  }

  Future<void> refreshProxyBridgeStatus() async {
    if (_rejectProxyBridgeOnMobile()) {
      return;
    }
    await _runProxyBridgeAction(
      busyMessage: '正在检测 Clash Verge 代理桥接。',
      busyMessageEnglish: 'Detecting the Clash Verge proxy bridge.',
      successMessage: 'Clash 代理桥接状态已刷新。',
      successMessageEnglish: 'Clash proxy bridge status refreshed.',
      errorMessage: 'Clash 代理桥接检测失败。',
      errorMessageEnglish: 'Failed to detect the Clash proxy bridge.',
      action: () async {
        proxyBridgeStatus = await agentService.proxyBridgeStatus();
        _syncProxyBridgeSelectedTargetsFromStatus();
      },
    );
  }

  Future<void> planProxyBridge() async {
    if (_rejectProxyBridgeOnMobile()) {
      return;
    }
    await _runProxyBridgeAction(
      busyMessage: '正在生成 Clash 代理桥接计划。',
      busyMessageEnglish: 'Generating a Clash proxy bridge plan.',
      successMessage: 'Clash 代理桥接计划已生成。',
      successMessageEnglish: 'Clash proxy bridge plan generated.',
      errorMessage: 'Clash 代理桥接计划失败。',
      errorMessageEnglish: 'Failed to generate a Clash proxy bridge plan.',
      action: () async {
        proxyBridgePlan = await agentService.proxyBridgePlan(
          targets: _selectedProxyBridgeTargets.join(','),
        );
        proxyBridgeStatus ??= proxyBridgePlan;
      },
    );
  }

  Future<void> applyProxyBridge() async {
    if (_rejectProxyBridgeOnMobile()) {
      return;
    }
    await _runProxyBridgeAction(
      busyMessage: '正在启用 Clash 代理桥接。',
      busyMessageEnglish: 'Enabling the Clash proxy bridge.',
      successMessage: 'Clash 代理桥接已启用。',
      successMessageEnglish: 'Clash proxy bridge enabled.',
      errorMessage: 'Clash 代理桥接启用失败。',
      errorMessageEnglish: 'Failed to enable the Clash proxy bridge.',
      action: () async {
        final result = await agentService.proxyBridgeApply(
          targets: _selectedProxyBridgeTargets.join(','),
        );
        proxyBridgeStatus = result;
        proxyBridgePlan = result;
        _syncProxyBridgeSelectedTargetsFromStatus();
      },
    );
  }

  Future<void> rollbackProxyBridge() async {
    if (_rejectProxyBridgeOnMobile()) {
      return;
    }
    await _runProxyBridgeAction(
      busyMessage: '正在关闭 Clash 代理桥接。',
      busyMessageEnglish: 'Disabling the Clash proxy bridge.',
      successMessage: 'Clash 代理桥接已关闭。',
      successMessageEnglish: 'Clash proxy bridge disabled.',
      errorMessage: 'Clash 代理桥接关闭失败。',
      errorMessageEnglish: 'Failed to disable the Clash proxy bridge.',
      action: () async {
        final result = await agentService.proxyBridgeRollback();
        proxyBridgeStatus = result;
        proxyBridgePlan = null;
        _syncProxyBridgeSelectedTargetsFromStatus();
      },
    );
  }

  Future<void> _runProxyBridgeAction({
    required String busyMessage,
    required String busyMessageEnglish,
    required String successMessage,
    required String successMessageEnglish,
    required String errorMessage,
    required String errorMessageEnglish,
    required Future<void> Function() action,
  }) async {
    isProxyBridgeBusy = true;
    _setLocalizedStatusMessage(busyMessage, busyMessageEnglish);
    statusCaption = 'Proxy Bridge';
    _notifyStateChanged();
    try {
      await action();
      _setLocalizedStatusMessage(successMessage, successMessageEnglish);
      statusCaption = 'Proxy Bridge';
    } catch (error) {
      lastError = error.toString();
      _setLocalizedStatusMessage(errorMessage, errorMessageEnglish);
      statusCaption = 'Error';
    } finally {
      isProxyBridgeBusy = false;
      _notifyStateChanged();
    }
  }

  void _syncProxyBridgeSelectedTargetsFromStatus() {
    final document = proxyBridgeStatus?['document'];
    if (document is! Map || document['targets'] is! List) {
      if (proxyBridgeSelectedTargets.isEmpty) {
        proxyBridgeSelectedTargets = Set<String>.from(
          proxyBridgeAvailableTargets,
        );
      }
      return;
    }
    final targets = (document['targets'] as List)
        .whereType<Map>()
        .map((item) => (item['target'] ?? '').toString())
        .where(_allProxyBridgeTargets.contains)
        .toSet();
    proxyBridgeSelectedTargets = targets.isEmpty
        ? Set<String>.from(proxyBridgeAvailableTargets)
        : targets;
  }

  bool _rejectProxyBridgeOnMobile() {
    if (!_mobileClientRuntimePlatform) {
      return false;
    }
    proxyBridgeStatus = null;
    proxyBridgePlan = null;
    isProxyBridgeBusy = false;
    _setLocalizedStatusMessage(
      '手机端不支持 Clash 代理桥接。',
      'The Clash proxy bridge is unavailable on mobile.',
    );
    statusCaption = 'Proxy Bridge';
    _notifyStateChanged();
    return true;
  }
}

const _allProxyBridgeTargets = {
  'codex',
  'claude-code',
  'antigravity',
  'opencode',
  'openclaw',
  'cursor',
  'code',
  'copilot',
  'kilo-code',
  'kimi-code',
  'hermes',
};
