import 'dart:async';
import 'dart:convert';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';

typedef ModelsSettingsReader = Future<Map<String, Object?>> Function();
typedef ModelsSettingsWriter =
    Future<void> Function(Map<String, Object?> content);

/// Owns model-gateway commands and their non-sensitive application state.
///
/// Secret values are accepted only by the command methods that need them and
/// are never copied into fields, projections, notices, or diagnostics.
final class ModelsSemanticController extends ApplicationStateOwner {
  ModelsSemanticController({
    required AgentCommandRunner runner,
    required LlmVaultAuthorization authorization,
    required LlmGatewayLifecycleController lifecycle,
    required ModelsSettingsReader readSettings,
    required ModelsSettingsWriter writeSettings,
    this.useRecoveryAwareLifecycle = true,
  }) : _runner = runner,
       _authorization = authorization,
       _lifecycle = lifecycle,
       _readSettings = readSettings,
       _writeSettings = writeSettings {
    _lifecycleSubscription = _lifecycle.changes.listen(
      (_) => _dependencyChanged(),
    );
  }

  final AgentCommandRunner _runner;
  final LlmVaultAuthorization _authorization;
  final LlmGatewayLifecycleController _lifecycle;
  final ModelsSettingsReader _readSettings;
  final ModelsSettingsWriter _writeSettings;
  final bool useRecoveryAwareLifecycle;

  late final StreamSubscription<ApplicationChange> _lifecycleSubscription;
  bool _busy = false;
  bool _gatewayPresentationPrepared = false;
  int _configuredPort = defaultLlmGatewayPort;
  String? _noticeCode;
  bool _telegramConfigured = false;
  String _telegramState = 'unknown';
  String _telegramTokenSource = 'none';
  String? _telegramBotUsername;
  List<Map<String, Object?>> _telegramPairings = const [];
  List<Map<String, Object?>> _telegramChats = const [];

  bool get busy => _busy || _authorization.busy || _lifecycle.busy;
  bool get gatewayPresentationPrepared => _gatewayPresentationPrepared;
  int get configuredPort => _configuredPort;
  String? get noticeCode => _noticeCode;
  bool get telegramConfigured => _telegramConfigured;
  String get telegramState => _telegramState;
  String get telegramTokenSource => _telegramTokenSource;
  String? get telegramBotUsername => _telegramBotUsername;
  List<Map<String, Object?>> get telegramPairings => _telegramPairings;
  List<Map<String, Object?>> get telegramChats => _telegramChats;
  LlmGatewayLifecycleController get lifecycle => _lifecycle;
  LlmVaultAuthorization get authorization => _authorization;

  Future<bool> prepareGatewayPresentation({String? traceId}) => _execute(
    () async {
      await _loadConfiguredPort();
      _gatewayPresentationPrepared = true;
      if (_lifecycle.lastReport == null) await _lifecycle.detect();
    },
    failureCode: 'gateway_status_failed',
    traceId: traceId,
  );

  Future<bool> refresh({String? traceId}) => _execute(
    () async {
      await _loadConfiguredPort();
      await Future.wait<void>([
        _lifecycle.pollNow(),
        _authorization.refreshInventory(_runner),
        _refreshTelegram(),
      ]);
    },
    failureCode: 'models_refresh_failed',
    traceId: traceId,
  );

  Future<bool> setGatewayEnabled(bool enabled, {String? traceId}) => _execute(
    () async {
      if (enabled) {
        if (useRecoveryAwareLifecycle) {
          await _lifecycle.start();
        } else {
          await _lifecycle.startOnce();
        }
        if (_lifecycle.state != LlmGatewayRuntimeState.running) {
          throw const _SemanticCommandFailure();
        }
      } else {
        await _lifecycle.stop();
      }
    },
    failureCode: enabled ? 'gateway_start_failed' : 'gateway_stop_failed',
    successCode: enabled ? 'gateway_started' : 'gateway_stopped',
    traceId: traceId,
  );

  Future<bool> recoverGateway({String? traceId}) => _execute(
    _lifecycle.restart,
    failureCode: 'gateway_recovery_failed',
    traceId: traceId,
  );

  Future<bool> saveGatewayEndpoint(String endpoint, {String? traceId}) async {
    final port = _localPort(endpoint);
    if (port == null) {
      _noticeCode = 'invalid_local_gateway_endpoint';
      publishChange(ApplicationCause(traceId: traceId));
      return false;
    }
    return _execute(
      () async {
        final content = await _readSettings();
        content[llmGatewayPortSettingsKey] = port;
        await _writeSettings(content);
        _configuredPort = port;
      },
      failureCode: 'gateway_endpoint_save_failed',
      successCode: 'gateway_endpoint_saved',
      traceId: traceId,
    );
  }

  Future<bool> refreshCredentials({String? traceId}) => _execute(
    () => _authorization.refreshInventory(_runner),
    failureCode: 'credential_inventory_failed',
    traceId: traceId,
  );

  Future<bool> createCredential({
    required String provider,
    required String label,
    required String apiKey,
    required int leaseDays,
    String? traceId,
  }) async {
    final normalizedProvider = provider.trim();
    final normalizedLabel = label.trim();
    final normalizedApiKey = apiKey.trim();
    if (normalizedProvider.isEmpty ||
        normalizedLabel.isEmpty ||
        normalizedApiKey.isEmpty ||
        leaseDays <= 0) {
      _noticeCode = 'credential_input_invalid';
      publishChange(ApplicationCause(traceId: traceId));
      return false;
    }
    return _execute(
      () async {
        final result = await _runner.runCliWithStdin(
          const [
            'llm-gateway',
            'credentials',
            'create',
            '--stdin-json',
            'true',
          ],
          jsonEncode({
            'provider': normalizedProvider,
            'label': normalizedLabel,
            'apiKey': normalizedApiKey,
            'leaseDays': leaseDays,
          }),
        );
        _authorization.adoptInventory(result);
      },
      failureCode: 'credential_create_failed',
      traceId: traceId,
    );
  }

  Future<bool> updateCredential({
    required String credentialId,
    String? label,
    int? extendDays,
    String? traceId,
  }) async {
    final id = credentialId.trim();
    if (id.isEmpty || (label == null && extendDays == null)) {
      _noticeCode = 'credential_update_invalid';
      publishChange(ApplicationCause(traceId: traceId));
      return false;
    }
    return _execute(
      () async {
        final update = <String, Object>{};
        if (label != null) update['label'] = label.trim();
        if (extendDays != null) update['extendDays'] = extendDays;
        final result = await _runner.runCliWithStdin([
          'llm-gateway',
          'credentials',
          'update',
          id,
          '--stdin-json',
          'true',
        ], jsonEncode(update));
        _authorization.adoptInventory(result);
      },
      failureCode: 'credential_update_failed',
      traceId: traceId,
    );
  }

  Future<bool> deleteCredential(String credentialId, {String? traceId}) =>
      _execute(
        () async {
          final result = await _runner.runCli([
            'llm-gateway',
            'credentials',
            'delete',
            credentialId,
          ]);
          if (_authorization.isCredentialAuthorized(credentialId)) {
            await _authorization.clearCredential(_runner, credentialId);
          }
          _authorization.adoptInventory(result);
        },
        failureCode: 'credential_delete_failed',
        traceId: traceId,
      );

  Future<bool> setCredentialAuthorized(
    String credentialId,
    bool authorized, {
    String? traceId,
  }) => _execute(
    () async {
      final succeeded = authorized
          ? await _authorization.authorizeCredential(_runner, credentialId)
          : await _authorization.clearCredential(_runner, credentialId);
      if (!succeeded) throw const _SemanticCommandFailure();
      if (authorized) await _authorization.refreshInventory(_runner);
      await _lifecycle.pollNow();
    },
    failureCode: authorized
        ? 'credential_authorization_failed'
        : 'credential_revoke_failed',
    successCode: authorized ? 'credential_authorized' : 'credential_revoked',
    traceId: traceId,
  );

  Future<bool> authorizeAllCredentials({String? traceId}) => _execute(
    () async {
      final authorized = await _authorization.authorize(_runner);
      if (!authorized) throw const _SemanticCommandFailure();
      await _authorization.refreshInventory(_runner);
      await _lifecycle.pollNow();
    },
    failureCode: 'credential_authorization_failed',
    traceId: traceId,
  );

  Future<bool> refreshTelegram({String? traceId}) => _execute(
    _refreshTelegram,
    failureCode: 'telegram_refresh_failed',
    traceId: traceId,
  );

  Future<bool> saveTelegramToken(String token, {String? traceId}) async {
    final normalized = token.trim();
    if (normalized.isEmpty || !normalized.contains(':')) {
      _noticeCode = 'telegram_token_invalid';
      publishChange(ApplicationCause(traceId: traceId));
      return false;
    }
    return _execute(
      () async {
        await _runner.runCliWithStdin(const [
          'gateway',
          'channel',
          'telegram',
          'credentials',
          'set',
          '--stdin-json',
          'true',
        ], jsonEncode({'botToken': normalized}));
        await _restartGateway();
        await _refreshTelegram();
      },
      failureCode: 'telegram_token_save_failed',
      successCode: 'telegram_token_saved',
      traceId: traceId,
    );
  }

  Future<bool> clearTelegramToken({String? traceId}) => _execute(
    () async {
      await _runner.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'clear',
      ]);
      await _restartGateway();
      await _refreshTelegram();
    },
    failureCode: 'telegram_token_clear_failed',
    successCode: 'telegram_token_cleared',
    traceId: traceId,
  );

  Future<bool> approveTelegramPairing(String code, {String? traceId}) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      _noticeCode = 'telegram_pairing_code_required';
      publishChange(ApplicationCause(traceId: traceId));
      return false;
    }
    return _execute(
      () async {
        await _runner.runCli([
          'gateway',
          'channel',
          'telegram',
          'pairing',
          'approve',
          normalized,
        ]);
        await _refreshTelegram();
      },
      failureCode: 'telegram_pairing_approve_failed',
      successCode: 'telegram_pairing_approved',
      traceId: traceId,
    );
  }

  Future<bool> revokeTelegramChat(int chatId, {String? traceId}) => _execute(
    () async {
      await _runner.runCli([
        'gateway',
        'channel',
        'telegram',
        'pairing',
        'revoke',
        '$chatId',
      ]);
      await _refreshTelegram();
    },
    failureCode: 'telegram_chat_revoke_failed',
    successCode: 'telegram_chat_revoked',
    traceId: traceId,
  );

  Future<void> _loadConfiguredPort() async {
    final settings = await _readSettings();
    final value = settings[llmGatewayPortSettingsKey];
    final parsed = value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    if (parsed != null && _validPort(parsed)) _configuredPort = parsed;
  }

  Future<void> _refreshTelegram() async {
    final results = await Future.wait<Map<String, dynamic>>([
      _runner.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'status',
      ]),
      _runner.runCli(const ['gateway', 'channel', 'status']),
      _runner.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'pairing',
        'list',
      ]),
    ]);
    final credentials = results[0];
    final channel = results[1];
    final pairing = results[2];
    final channels = _stringMap(channel['channels']);
    final telegram = _stringMap(channels['telegram']);
    _telegramConfigured = credentials['configured'] == true;
    _telegramTokenSource = '${credentials['tokenSource'] ?? 'none'}';
    _telegramState =
        '${telegram['state'] ?? credentials['token'] ?? 'unknown'}';
    final username = '${telegram['botUsername'] ?? ''}'.trim();
    _telegramBotUsername = username.isEmpty ? null : username;
    _telegramPairings = _objectMapList(pairing['pairings']);
    _telegramChats = _objectMapList(pairing['chats']);
  }

  Future<void> _restartGateway() async {
    await _lifecycle.stop();
    await _lifecycle.start();
  }

  Future<bool> _execute(
    Future<void> Function() action, {
    required String failureCode,
    String? successCode,
    String? traceId,
  }) async {
    if (_busy) return false;
    _busy = true;
    _noticeCode = null;
    publishChange(ApplicationCause(traceId: traceId));
    try {
      await action();
      _noticeCode = successCode;
      return true;
    } on Object {
      _noticeCode = failureCode;
      return false;
    } finally {
      _busy = false;
      publishChange(ApplicationCause(traceId: traceId));
    }
  }

  int? _localPort(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'http' ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !_validPort(uri.port)) {
      return null;
    }
    return uri.port;
  }

  bool _validPort(int value) => value > 0 && value <= 65535;

  Map<String, Object?> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {for (final entry in value.entries) '${entry.key}': entry.value};
  }

  List<Map<String, Object?>> _objectMapList(Object? value) {
    if (value is! List) return const [];
    return List.unmodifiable([
      for (final item in value)
        if (item is Map) _stringMap(item),
    ]);
  }

  void _dependencyChanged() {
    if (!applicationStateDisposed) publishChange();
  }

  @override
  void dispose() {
    unawaited(_lifecycleSubscription.cancel());
    super.dispose();
  }
}

final class _SemanticCommandFailure implements Exception {
  const _SemanticCommandFailure();
}
