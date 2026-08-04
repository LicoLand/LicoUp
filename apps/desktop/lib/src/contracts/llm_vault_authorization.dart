import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';

enum LlmVaultAuthorizationFailure { noCredentials, unavailable }

/// One process-scoped authorization session for loading model API keys.
///
/// Authorization performs no provider network check and owns no Gateway
/// process lifecycle. Every consumer observes the same session, so the owner
/// is never prompted twice during one LicoUp process lifetime.
final class LlmVaultAuthorization extends ChangeNotifier {
  bool _authorized = false;
  bool _busy = false;
  List<String> _providers = const [];
  List<Map<String, dynamic>> _inventoryEntries = const [];
  bool _inventoryHydrated = false;
  LlmVaultAuthorizationFailure? _failure;
  Future<bool>? _inFlight;
  Future<void>? _inventoryInFlight;

  bool get authorized => _authorized;
  bool get busy => _busy;
  List<String> get providers => _providers;
  List<Map<String, dynamic>> get inventoryEntries => _inventoryEntries;
  bool get inventoryHydrated => _inventoryHydrated;
  LlmVaultAuthorizationFailure? get failure => _failure;

  set authorized(bool value) {
    if (_authorized == value) return;
    _authorized = value;
    if (!value) {
      _providers = const [];
    } else {
      _failure = null;
    }
    notifyListeners();
  }

  Future<bool> authorize(AgentCommandRunner runner) {
    if (_authorized) return Future.value(true);
    final active = _inFlight;
    if (active != null) return active;
    final operation = _authorize(runner);
    _inFlight = operation;
    return operation.whenComplete(() => _inFlight = null);
  }

  /// Starts the automatic client bootstrap without opening the protected
  /// store when the public metadata inventory is empty. Manual authorization
  /// deliberately bypasses this preflight so it can migrate a legacy vault.
  Future<bool> authorizeExisting(AgentCommandRunner runner) async {
    if (_authorized) return true;
    try {
      await refreshInventory(runner);
      if (_inventoryEntries.isEmpty) {
        _providers = const [];
        _failure = LlmVaultAuthorizationFailure.noCredentials;
        notifyListeners();
        return false;
      }
    } catch (_) {
      _providers = const [];
      _failure = LlmVaultAuthorizationFailure.unavailable;
      notifyListeners();
      return false;
    }
    return authorize(runner);
  }

  /// Refreshes only the public, local metadata inventory. Concurrent callers
  /// share one native round trip so navigation and authorization refreshes
  /// cannot queue duplicate reads behind the lifecycle monitor.
  Future<void> refreshInventory(AgentCommandRunner runner) {
    final active = _inventoryInFlight;
    if (active != null) return active;
    final operation = _refreshInventory(runner);
    _inventoryInFlight = operation;
    return operation.whenComplete(() => _inventoryInFlight = null);
  }

  Future<void> _refreshInventory(AgentCommandRunner runner) async {
    final inventory = await runner.runCli(const [
      'llm-gateway',
      'credentials',
      'list',
    ]);
    adoptInventory(inventory);
  }

  /// Applies a command's non-secret inventory projection without another
  /// native read. Create, edit, and delete commands already return this data.
  void adoptInventory(Map<String, dynamic> inventory) {
    _inventoryEntries = List.unmodifiable(
      (inventory['entries'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((entry) => Map<String, dynamic>.unmodifiable(entry)),
    );
    _inventoryHydrated = true;
    notifyListeners();
  }

  Future<bool> _authorize(AgentCommandRunner runner) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await runner.runCli(const [
        'llm-gateway',
        'credentials',
        'authorize',
      ]);
      _providers = (result['providers'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      _authorized = result['authorized'] == true;
      if (!_authorized) {
        _failure = result['reasonCode'] == 'no_credentials'
            ? LlmVaultAuthorizationFailure.noCredentials
            : LlmVaultAuthorizationFailure.unavailable;
      }
      return _authorized;
    } catch (_) {
      _authorized = false;
      _providers = const [];
      _failure = LlmVaultAuthorizationFailure.unavailable;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
