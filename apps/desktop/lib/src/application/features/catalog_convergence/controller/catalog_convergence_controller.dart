import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_models.dart';

enum CatalogConvergencePhase {
  disabled,
  idle,
  reconciling,
  ready,
  blocked,
  failed,
}

/// Desktop composition for the native convergence authority.
///
/// Pull credentials stay inside the call-scoped [CatalogAuthenticatedPull]
/// adapter. This controller retains only opaque partition identifiers and
/// bounded, privacy-safe status counts.
final class CatalogConvergenceController extends ApplicationStateOwner {
  CatalogConvergenceController({required CatalogConvergenceGateway gateway})
    : _gateway = gateway;

  final CatalogConvergenceGateway _gateway;
  final Map<String, Future<void>> _inFlight = {};
  CatalogConvergenceStatus _status = CatalogConvergenceStatus.empty();
  CatalogConvergencePhase _phase = CatalogConvergencePhase.disabled;
  String _reasonCode = 'catalog_not_configured';
  bool _disposed = false;

  CatalogConvergenceStatus get status => _status;
  CatalogConvergencePhase get phase => _phase;
  String get reasonCode => _reasonCode;
  bool get busy => _inFlight.isNotEmpty;

  Future<void> bootstrap() async {
    if (_disposed) return;
    try {
      _status = await _gateway.status();
      _phase = _status.partitionCount == 0
          ? CatalogConvergencePhase.disabled
          : CatalogConvergencePhase.blocked;
      _reasonCode = _status.partitionCount == 0
          ? 'catalog_not_configured'
          : 'catalog_reconciliation_required';
    } catch (_) {
      _phase = CatalogConvergencePhase.failed;
      _reasonCode = 'catalog_status_failed';
    }
    _notify();
  }

  Future<bool> reconnect({
    required Iterable<String> partitionKeys,
    required CatalogAuthenticatedPull pull,
  }) async {
    final keys = _validatedKeys(partitionKeys);
    if (keys.isEmpty || _disposed) return false;
    _phase = CatalogConvergencePhase.reconciling;
    _reasonCode = 'catalog_reconciling';
    _notify();
    try {
      await _gateway.beginReconnect();
      for (final key in keys) {
        await _refresh(key, pull);
      }
      await _reloadStatus();
      return _phase == CatalogConvergencePhase.ready;
    } catch (_) {
      _phase = CatalogConvergencePhase.blocked;
      _reasonCode = 'catalog_reconciliation_failed';
      await _reloadStatus(preserveFailure: true);
      return false;
    }
  }

  Future<bool> handleInvalidation(
    CatalogInvalidation notification, {
    required CatalogAuthenticatedPull pull,
  }) async {
    if (_disposed) return false;
    _phase = CatalogConvergencePhase.reconciling;
    _reasonCode = 'catalog_reconciling';
    _notify();
    try {
      final keys = await _gateway.invalidate(notification);
      for (final key in keys) {
        await _refresh(key, pull);
      }
      await _reloadStatus();
      return _phase == CatalogConvergencePhase.ready;
    } catch (_) {
      _phase = CatalogConvergencePhase.blocked;
      _reasonCode = 'catalog_reconciliation_failed';
      await _reloadStatus(preserveFailure: true);
      return false;
    }
  }

  Future<CatalogDiscoveryResult> discover(String partitionKey) async {
    final key = _validatedKeys([partitionKey]).single;
    final result = await _gateway.listTools(key);
    if (result.ok) {
      await _gateway.observeUi(key);
      await _reloadStatus();
    } else {
      _phase = CatalogConvergencePhase.blocked;
      _reasonCode = result.reasonCode;
      _notify();
    }
    return result;
  }

  Future<void> disable() async {
    await _gateway.purge();
    _status = CatalogConvergenceStatus.empty();
    _phase = CatalogConvergencePhase.disabled;
    _reasonCode = 'catalog_disabled';
    _notify();
  }

  Future<void> removePartition(String partitionKey) async {
    final key = _validatedKeys([partitionKey]).single;
    await _gateway.purge(partitionKey: key);
    await _reloadStatus();
  }

  Future<void> _refresh(String key, CatalogAuthenticatedPull pull) {
    final existing = _inFlight[key];
    if (existing != null) return existing;
    late final Future<void> refresh;
    refresh =
        () async {
          final snapshot = await pull(key);
          await _gateway.replacePartition(key, snapshot);
        }().whenComplete(() {
          if (identical(_inFlight[key], refresh)) _inFlight.remove(key);
        });
    _inFlight[key] = refresh;
    return refresh;
  }

  Future<void> _reloadStatus({bool preserveFailure = false}) async {
    try {
      _status = await _gateway.status();
      if (!preserveFailure) {
        _phase = _status.discoveryBlocked
            ? CatalogConvergencePhase.blocked
            : CatalogConvergencePhase.ready;
        _reasonCode = _status.discoveryBlocked
            ? 'catalog_reconciliation_required'
            : 'catalog_current';
      }
    } catch (_) {
      _phase = CatalogConvergencePhase.failed;
      _reasonCode = 'catalog_status_failed';
    }
    _notify();
  }

  List<String> _validatedKeys(Iterable<String> values) {
    final keys = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (keys.length > catalogConvergenceMaxPartitions) {
      throw const FormatException('catalog_partition_capacity');
    }
    return keys;
  }

  void _notify() {
    if (!_disposed) publishChange();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
