import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/agents/contracts/provider_quota_gateway.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';

const Duration defaultProviderQuotaPollingInterval = Duration(minutes: 5);

/// Owns provider-quota snapshot state, polling, and the single-flight refresh
/// guard. Shaped on [AgentUsageController]: the composition root only
/// projects this state, and the roster receives one immutable
/// agent-id-keyed projection as plain state — the UI never merges Maps.
final class ProviderQuotaController extends ChangeNotifier {
  ProviderQuotaController({required this.gateway});

  final ProviderQuotaGateway gateway;

  /// Immutable projection of the latest snapshot envelope, keyed by agent id.
  /// Agents without a quota source are absent; stale snapshots stay retained
  /// and flagged until the native projection replaces them.
  Map<String, ProviderQuotaSnapshot> snapshots = const {};

  /// Envelope timestamp of the native projection behind [snapshots].
  String generatedAt = '';

  Timer? _pollingTimer;
  final Set<Object> _pollingOwners = <Object>{};
  final Object _defaultPollingOwner = Object();
  Duration _pollingInterval = defaultProviderQuotaPollingInterval;
  Future<void>? _refreshFuture;
  bool _disposed = false;

  @visibleForTesting
  int get pollingOwnerCount => _pollingOwners.length;

  void startPolling({Duration interval = defaultProviderQuotaPollingInterval}) {
    acquirePollingOwner(_defaultPollingOwner, interval: interval);
  }

  void stopPolling() {
    releasePollingOwner(_defaultPollingOwner);
  }

  void acquirePollingOwner(
    Object owner, {
    Duration interval = defaultProviderQuotaPollingInterval,
  }) {
    if (_disposed) return;
    final wasEmpty = _pollingOwners.isEmpty;
    _pollingOwners.add(owner);
    final normalized = interval > Duration.zero
        ? interval
        : defaultProviderQuotaPollingInterval;
    if (wasEmpty || normalized < _pollingInterval) {
      _pollingInterval = normalized;
    }
    if (wasEmpty && _pollingOwners.isNotEmpty) {
      unawaited(refresh());
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
        await refresh();
        if (!_disposed && _pollingOwners.isNotEmpty) {
          _schedulePoll(_pollingInterval);
        }
      }());
    });
  }

  /// Single-flight refresh: concurrent callers share one in-flight pull, and
  /// a failed pull retains the previous projection silently — quota chrome is
  /// ambient and never surfaces its own error status.
  Future<void> refresh({bool forceRefresh = false}) {
    if (_disposed) {
      return Future<void>.value();
    }
    final active = _refreshFuture;
    if (active != null) return active;
    late final Future<void> refresh;
    refresh = _refresh(forceRefresh: forceRefresh).whenComplete(() {
      if (identical(_refreshFuture, refresh)) _refreshFuture = null;
    });
    _refreshFuture = refresh;
    return refresh;
  }

  Future<void> _refresh({required bool forceRefresh}) async {
    try {
      final report = await gateway.snapshot(forceRefresh: forceRefresh);
      if (_disposed) return;
      snapshots = report.byAgentId;
      generatedAt = report.generatedAt;
    } catch (_) {
      // Retain the last projection; native marks it stale past its TTL.
      return;
    }
    if (!_disposed) notifyListeners();
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
