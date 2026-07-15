import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/agents/models/agent_allowance_defaults.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

typedef LayoutAllowanceRefreshCallback = Future<void> Function(String targetId);
typedef LayoutPairingAction = Future<void> Function(BuildContext context);
typedef LayoutPostFrameScheduler = void Function(VoidCallback callback);

/// Converts the application controller into the bounded semantic state used by
/// every layout profile's chrome.
final class ClientLayoutChromeAdapter extends ChangeNotifier
    implements LayoutChromePort {
  ClientLayoutChromeAdapter(
    this._controller, {
    Duration allowanceRefreshInterval = const Duration(minutes: 1),
    LayoutAllowanceRefreshCallback? allowanceRefresher,
    LayoutPairingAction? pairingAction,
    LayoutPostFrameScheduler? postFrameScheduler,
  }) : _allowanceRefreshInterval = allowanceRefreshInterval {
    if (allowanceRefreshInterval <= Duration.zero) {
      throw const FormatException('layout_chrome_refresh_interval_invalid');
    }
    _allowanceRefresher =
        allowanceRefresher ?? _controller.refreshAgentAllowances;
    _pairingAction =
        pairingAction ??
        (context) => showMobileRelayPopup(context, _controller);
    _postFrameScheduler =
        postFrameScheduler ??
        (callback) {
          WidgetsBinding.instance.addPostFrameCallback((_) => callback());
        };
    _value = _snapshotFromController();
    _controller.addListener(_handleControllerChanged);
    _updateRefreshTarget(_value.allowance?.targetId ?? '');
  }

  final ClientController _controller;
  final Duration _allowanceRefreshInterval;
  late final LayoutAllowanceRefreshCallback _allowanceRefresher;
  late final LayoutPairingAction _pairingAction;
  late final LayoutPostFrameScheduler _postFrameScheduler;

  late LayoutChromeSnapshot _value;
  Timer? _allowanceRefreshTimer;
  String _allowanceRefreshTarget = '';
  int _refreshGeneration = 0;
  bool _disposed = false;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  Future<void> openPairing(BuildContext context) => _pairingAction(context);

  void _handleControllerChanged() {
    if (_disposed) {
      return;
    }
    final next = _snapshotFromController();
    _updateRefreshTarget(next.allowance?.targetId ?? '');
    if (next == _value) {
      return;
    }
    _value = next;
    notifyListeners();
  }

  LayoutChromeSnapshot _snapshotFromController() {
    final status = LayoutChromeStatusSnapshot(
      message: _controller.displayStatusMessage,
      caption: _controller.displayStatusCaption,
    );
    if (_controller.currentSection != ClientSection.agents) {
      return LayoutChromeSnapshot(status: status);
    }
    final target = _controller.selectedConversationAgent;
    if (target == null) {
      return LayoutChromeSnapshot(status: status);
    }
    final report = _controller.agentUsageReport;
    final usage = report?.agent(target.target);
    final cached = _controller.allowancesForAgent(target.target);
    final allowances = cached.isNotEmpty
        ? cached
        : defaultAllowancesFor(target.target);
    return LayoutChromeSnapshot(
      status: status,
      allowance: LayoutChromeAllowanceSnapshot(
        targetId: target.target,
        targetLabel: target.label,
        meters: allowances.map(_meterSnapshot),
        totalTokens: report?.totalTokens ?? 0,
        targetTokens: usage?.totalTokens,
      ),
    );
  }

  static LayoutChromeAllowanceMeterSnapshot _meterSnapshot(
    AgentUsageAllowance allowance,
  ) => LayoutChromeAllowanceMeterSnapshot(
    kind: allowance.kind,
    label: allowance.label,
    provider: allowance.provider,
    period: allowance.period,
    status: allowance.status,
    value: allowance.value,
    unit: allowance.unit,
    message: allowance.message,
  );

  void _updateRefreshTarget(String rawTargetId) {
    final targetId = rawTargetId.trim();
    if (targetId == _allowanceRefreshTarget) {
      return;
    }
    _allowanceRefreshTimer?.cancel();
    _allowanceRefreshTimer = null;
    _refreshGeneration += 1;
    _allowanceRefreshTarget = targetId;
    if (targetId.isEmpty) {
      return;
    }
    final generation = _refreshGeneration;
    _postFrameScheduler(() {
      if (_disposed ||
          generation != _refreshGeneration ||
          targetId != _allowanceRefreshTarget) {
        return;
      }
      _refreshAllowance(targetId);
    });
    _allowanceRefreshTimer = Timer.periodic(_allowanceRefreshInterval, (_) {
      if (_disposed || targetId != _allowanceRefreshTarget) {
        return;
      }
      _refreshAllowance(targetId);
    });
  }

  void _refreshAllowance(String targetId) {
    unawaited(_refreshAllowanceSafely(targetId));
  }

  Future<void> _refreshAllowanceSafely(String targetId) async {
    try {
      await _allowanceRefresher(targetId);
    } catch (_) {
      // The controller keeps its previous semantic snapshot on refresh
      // failures; shell chrome must remain usable and quiet.
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _refreshGeneration += 1;
    _allowanceRefreshTimer?.cancel();
    _allowanceRefreshTimer = null;
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }
}
