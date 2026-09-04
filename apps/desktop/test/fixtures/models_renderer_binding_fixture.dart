import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/models/controller/models_semantic_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_effect.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/projections/models/models_projection_producer.dart';

typedef TestSettingsReader = Future<Map<String, Object?>> Function();
typedef TestSettingsWriter =
    Future<void> Function(Map<String, Object?> content);

/// Test-only composition seam for renderer tests that need real model command
/// behavior without passing Application controllers into Flutter widgets.
final class ModelsRendererBindingFixture {
  ModelsRendererBindingFixture({
    required AgentCommandRunner runner,
    LlmVaultAuthorization? authorization,
    LlmGatewayLifecycleController? lifecycle,
    TestSettingsReader? readSettings,
    TestSettingsWriter? writeSettings,
  }) : _authorization = authorization ?? LlmVaultAuthorization(),
       _ownsAuthorization = authorization == null,
       _lifecycle =
           lifecycle ??
           LlmGatewayLifecycleController(
             agentService: runner,
             readSettings: readSettings ?? _emptySettings,
             monitorInterval: Duration.zero,
             recoveryRetryDelay: Duration.zero,
           ),
       _ownsLifecycle = lifecycle == null {
    _owner = ModelsSemanticController(
      runner: runner,
      authorization: _authorization,
      lifecycle: _lifecycle,
      readSettings: readSettings ?? _emptySettings,
      writeSettings: writeSettings ?? _ignoreSettings,
      useRecoveryAwareLifecycle: !_ownsLifecycle,
    );
    _projection = ModelsProjectionProducer(_owner);
    _intents = _FixtureIntentSink(_handleIntent);
    binding = ModelsBinding(
      projection: _projection,
      intents: _intents,
      effects: const _EmptyEffects(),
    );
  }

  final LlmVaultAuthorization _authorization;
  final bool _ownsAuthorization;
  final LlmGatewayLifecycleController _lifecycle;
  final bool _ownsLifecycle;
  late final ModelsSemanticController _owner;
  late final ModelsProjectionProducer _projection;
  late final _FixtureIntentSink _intents;
  late final ModelsBinding binding;
  Future<void>? _disposal;

  Future<bool> refreshCredentials() => _authorization.inventoryHydrated
      ? Future<bool>.value(true)
      : _owner.refreshCredentials();

  Future<bool> refreshTelegram() => _owner.refreshTelegram();

  Future<void> initializeGateway() => _owner.prepareGatewayPresentation();

  Future<void> settle() => _intents.settle();

  Future<void> _handleIntent(ModelsIntent intent) async {
    final traceId = intent.trace?.traceId;
    switch (intent) {
      case RefreshModels():
        await _owner.refresh(traceId: traceId);
      case RefreshGateway():
        if (await _owner.prepareGatewayPresentation(traceId: traceId)) {
          await _owner.refreshCredentials(traceId: traceId);
        }
      case SetGatewayEnabled(:final enabled):
        await _owner.setGatewayEnabled(enabled, traceId: traceId);
      case SaveGatewayEndpoint(:final endpoint):
        await _owner.saveGatewayEndpoint(endpoint, traceId: traceId);
      case SelectGatewayModel():
        break;
      case AuthorizeModelProvider() || AuthorizeAllGatewayCredentials():
        await _owner.authorizeAllCredentials(traceId: traceId);
      case RecoverModelGateway():
        await _owner.recoverGateway(traceId: traceId);
      case RefreshGatewayCredentials():
        await _owner.refreshCredentials(traceId: traceId);
      case CreateGatewayCredential(
        :final provider,
        :final label,
        :final apiKey,
        :final leaseDays,
      ):
        await _owner.createCredential(
          provider: provider,
          label: label,
          apiKey: apiKey,
          leaseDays: leaseDays,
          traceId: traceId,
        );
      case UpdateGatewayCredential(
        :final credentialId,
        :final label,
        :final extendDays,
      ):
        await _owner.updateCredential(
          credentialId: credentialId,
          label: label,
          extendDays: extendDays,
          traceId: traceId,
        );
      case DeleteGatewayCredential(:final credentialId):
        await _owner.deleteCredential(credentialId, traceId: traceId);
      case SetGatewayCredentialAuthorized(
        :final credentialId,
        :final authorized,
      ):
        await _owner.setCredentialAuthorized(
          credentialId,
          authorized,
          traceId: traceId,
        );
      case RefreshTelegramChannel():
        await _owner.refreshTelegram(traceId: traceId);
      case SaveTelegramToken(:final token):
        await _owner.saveTelegramToken(token, traceId: traceId);
      case ClearTelegramToken():
        await _owner.clearTelegramToken(traceId: traceId);
      case ApproveTelegramPairing(:final code):
        await _owner.approveTelegramPairing(code, traceId: traceId);
      case RevokeTelegramChat(:final chatId):
        await _owner.revokeTelegramChat(chatId, traceId: traceId);
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _intents.settle();
    await _projection.dispose();
    _owner.dispose();
    if (_ownsLifecycle) _lifecycle.dispose();
    if (_ownsAuthorization) _authorization.dispose();
  }

  static Future<Map<String, Object?>> _emptySettings() async => const {};

  static Future<void> _ignoreSettings(Map<String, Object?> _) async {}
}

final class _FixtureIntentSink implements IntentSink<ModelsIntent> {
  _FixtureIntentSink(this._handler);

  final Future<void> Function(ModelsIntent intent) _handler;
  final List<Future<void>> _pending = [];

  @override
  void send(ModelsIntent intent) {
    final operation = _handler(intent);
    _pending.add(operation);
    unawaited(operation.whenComplete(() => _pending.remove(operation)));
  }

  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pending));
    }
  }
}

final class _EmptyEffects implements EffectSource<ModelsEffect> {
  const _EmptyEffects();

  @override
  Stream<ModelsEffect> get effects => const Stream.empty();
}
