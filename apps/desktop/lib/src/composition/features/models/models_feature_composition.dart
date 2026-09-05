import 'dart:async';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/models/controller/models_semantic_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_effect.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/projections/models/models_projection_producer.dart';

final class ModelsFeatureComposition {
  ModelsFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent,
       _owner = ModelsSemanticController(
         runner: controller.agentService,
         authorization: controller.llmVaultAuthorization,
         lifecycle: controller.llmGatewayLifecycleController,
         readSettings: controller.agentWorkspaceReadSettingsState,
         writeSettings: controller.agentWorkspaceWriteSettingsState,
       ) {
    _projection = ModelsProjectionProducer(_owner);
    _effects = SemanticEffectChannel<ModelsEffect>();
    _intents = SemanticIntentChannel<ModelsIntent>(_handleIntent);
    binding = ModelsBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ModelsSemanticController _owner;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final ModelsProjectionProducer _projection;
  late final SemanticEffectChannel<ModelsEffect> _effects;
  late final SemanticIntentChannel<ModelsIntent> _intents;
  late final ModelsBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(ModelsIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    final traceId = trace?.traceId;
    final succeeded = switch (intent) {
      RefreshModels() => await _owner.refresh(traceId: traceId),
      RefreshGateway() => await _refreshGateway(traceId),
      SetGatewayEnabled(:final enabled) => await _owner.setGatewayEnabled(
        enabled,
        traceId: traceId,
      ),
      SaveGatewayEndpoint(:final endpoint) => await _owner.saveGatewayEndpoint(
        endpoint,
        traceId: traceId,
      ),
      SelectGatewayModel() => false,
      AuthorizeModelProvider() => await _owner.authorizeAllCredentials(
        traceId: traceId,
      ),
      RecoverModelGateway() => await _owner.recoverGateway(traceId: traceId),
      RefreshGatewayCredentials() => await _owner.refreshCredentials(
        traceId: traceId,
      ),
      CreateGatewayCredential(
        :final provider,
        :final label,
        :final apiKey,
        :final leaseDays,
      ) =>
        await _owner.createCredential(
          provider: provider,
          label: label,
          apiKey: apiKey,
          leaseDays: leaseDays,
          traceId: traceId,
        ),
      UpdateGatewayCredential(
        :final credentialId,
        :final label,
        :final extendDays,
      ) =>
        await _owner.updateCredential(
          credentialId: credentialId,
          label: label,
          extendDays: extendDays,
          traceId: traceId,
        ),
      DeleteGatewayCredential(:final credentialId) =>
        await _owner.deleteCredential(credentialId, traceId: traceId),
      SetGatewayCredentialAuthorized(:final credentialId, :final authorized) =>
        await _owner.setCredentialAuthorized(
          credentialId,
          authorized,
          traceId: traceId,
        ),
      AuthorizeAllGatewayCredentials() => await _owner.authorizeAllCredentials(
        traceId: traceId,
      ),
      RefreshTelegramChannel() => await _owner.refreshTelegram(
        traceId: traceId,
      ),
      SaveTelegramToken(:final token) => await _owner.saveTelegramToken(
        token,
        traceId: traceId,
      ),
      ClearTelegramToken() => await _owner.clearTelegramToken(traceId: traceId),
      ApproveTelegramPairing(:final code) =>
        await _owner.approveTelegramPairing(code, traceId: traceId),
      RevokeTelegramChat(:final chatId) => await _owner.revokeTelegramChat(
        chatId,
        traceId: traceId,
      ),
    };
    if (!succeeded) {
      _effects.emit(
        ModelsActionRejected(
          _owner.noticeCode ?? 'models_action_failed',
          trace: trace,
        ),
      );
    }
  }

  Future<bool> _refreshGateway(String? traceId) async {
    final prepared = await _owner.prepareGatewayPresentation(traceId: traceId);
    if (!prepared) return false;
    return _owner.refreshCredentials(traceId: traceId);
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
    _owner.dispose();
  }
}
