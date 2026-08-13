import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';

enum LlmVaultAuthorizationFailure { noCredentials, unavailable }

/// One process-scoped authorization session for loading model API keys.
///
/// Authorization performs no provider network check and owns no Gateway
/// process lifecycle. Individual credential IDs may be enabled or cleared
/// independently; [authorized] is true when any credential remains enabled.
final class LlmVaultAuthorization extends ChangeNotifier {
  bool _authorized = false;
  bool _busy = false;
  List<String> _providers = const [];
  List<String> _authorizedCredentialIds = const [];
  List<Map<String, dynamic>> _inventoryEntries = const [];
  bool _inventoryHydrated = false;
  LlmVaultAuthorizationFailure? _failure;
  Future<bool>? _inFlight;
  Future<void>? _inventoryInFlight;

  bool get authorized => _authorized;
  bool get busy => _busy;
  List<String> get providers => _providers;
  List<String> get authorizedCredentialIds => _authorizedCredentialIds;
  List<Map<String, dynamic>> get inventoryEntries => _inventoryEntries;
  bool get inventoryHydrated => _inventoryHydrated;
  LlmVaultAuthorizationFailure? get failure => _failure;

  bool isCredentialAuthorized(String credentialId) =>
      _authorizedCredentialIds.contains(credentialId);

  set authorized(bool value) {
    if (_authorized == value &&
        (value || _authorizedCredentialIds.isEmpty)) {
      return;
    }
    _authorized = value;
    if (!value) {
      _providers = const [];
      _authorizedCredentialIds = const [];
    } else {
      _failure = null;
    }
    notifyListeners();
  }

  Future<bool> authorize(AgentCommandRunner runner) {
    if (_authorized) return Future.value(true);
    return _runExclusive(() => _authorize(runner));
  }

  Future<bool> authorizeCredential(
    AgentCommandRunner runner,
    String credentialId,
  ) {
    if (isCredentialAuthorized(credentialId)) return Future.value(true);
    return _runExclusive(() => _authorize(runner, credentialId: credentialId));
  }

  /// Drops the in-memory Gateway credential session without deleting vault
  /// entries. Concurrent callers share one clear so toggle and lifecycle
  /// refreshes cannot race duplicate native clears.
  Future<bool> clearAuthorization(AgentCommandRunner runner) {
    return _runExclusive(() => _clearAuthorization(runner));
  }

  Future<bool> clearCredential(
    AgentCommandRunner runner,
    String credentialId,
  ) {
    if (!isCredentialAuthorized(credentialId)) return Future.value(true);
    return _runExclusive(
      () => _clearAuthorization(runner, credentialId: credentialId),
    );
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
        _authorizedCredentialIds = const [];
        _failure = LlmVaultAuthorizationFailure.noCredentials;
        notifyListeners();
        return false;
      }
    } catch (_) {
      _providers = const [];
      _authorizedCredentialIds = const [];
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

  Future<bool> _runExclusive(Future<bool> Function() operation) {
    final active = _inFlight;
    if (active != null) {
      return active.then((_) => _runExclusive(operation));
    }
    final started = operation();
    _inFlight = started;
    return started.whenComplete(() => _inFlight = null);
  }

  Future<bool> _authorize(
    AgentCommandRunner runner, {
    String? credentialId,
  }) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final args = <String>['llm-gateway', 'credentials', 'authorize'];
      if (credentialId != null) {
        args
          ..add('--credential-id')
          ..add(credentialId);
      }
      final result = await runner.runCli(args);
      _adoptAuthorizationResult(result);
      if (!_authorized) {
        _failure = result['reasonCode'] == 'no_credentials'
            ? LlmVaultAuthorizationFailure.noCredentials
            : LlmVaultAuthorizationFailure.unavailable;
      }
      return _authorized;
    } catch (_) {
      _authorized = false;
      _providers = const [];
      _authorizedCredentialIds = const [];
      _failure = LlmVaultAuthorizationFailure.unavailable;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> _clearAuthorization(
    AgentCommandRunner runner, {
    String? credentialId,
  }) async {
    _busy = true;
    _failure = null;
    notifyListeners();
    try {
      final args = <String>['llm-gateway', 'credentials', 'clear'];
      if (credentialId != null) {
        args
          ..add('--credential-id')
          ..add(credentialId);
      }
      final result = await runner.runCli(args);
      if (result['ok'] != true) {
        _failure = LlmVaultAuthorizationFailure.unavailable;
        return false;
      }
      _adoptAuthorizationResult(result);
      return true;
    } catch (_) {
      _failure = LlmVaultAuthorizationFailure.unavailable;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _adoptAuthorizationResult(Map<String, dynamic> result) {
    _providers = (result['providers'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    _authorizedCredentialIds =
        (result['authorizedCredentialIds'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList(growable: false);
    _authorized =
        result['authorized'] == true || _authorizedCredentialIds.isNotEmpty;
    if (_authorized) {
      _failure = null;
    }
  }
}
