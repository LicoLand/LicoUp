import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_resources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Narrow renderer-facing inputs for the model catalog view.
final class ModelsCatalogInputs {
  const ModelsCatalogInputs({
    required this.scope,
    required this.phase,
    required this.gateway,
    required this.credentials,
    required this.credentialMigrationPending,
    required this.telegram,
    this.notice,
  });

  factory ModelsCatalogInputs.fromProjection(ModelsProjection projection) =>
      ModelsCatalogInputs(
        scope: modelsPresentationScope,
        phase: projection.phase,
        gateway: projection.gateway,
        credentials: projection.credentials,
        credentialMigrationPending: projection.credentialMigrationPending,
        telegram: projection.telegram,
        notice: projection.notice,
      );

  final ResourceScope scope;
  final PresentationPhase phase;
  final GatewayProjection gateway;
  final List<GatewayCredentialProjection> credentials;
  final bool credentialMigrationPending;
  final TelegramProjection telegram;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelsCatalogInputs &&
          other.scope == scope &&
          other.phase == phase &&
          other.gateway == gateway &&
          samePresentationList(other.credentials, credentials) &&
          other.credentialMigrationPending == credentialMigrationPending &&
          other.telegram == telegram &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    phase,
    gateway,
    Object.hashAll(credentials),
    credentialMigrationPending,
    telegram,
    notice,
  );
}

/// Narrow renderer actions for the model catalog. Every dispatch carries the
/// pinned originating scope so asynchronous failures stay attributable.
final class ModelsCatalogActions {
  const ModelsCatalogActions({
    required this.origin,
    required this.refreshModels,
    required this.refreshGateway,
    required this.setGatewayEnabled,
    required this.saveGatewayEndpoint,
    required this.selectGatewayModel,
    required this.authorizeModelProvider,
    required this.recoverGateway,
    required this.refreshGatewayCredentials,
    required this.migrateGatewayCredentials,
    required this.createGatewayCredential,
    required this.updateGatewayCredential,
    required this.deleteGatewayCredential,
    required this.setGatewayCredentialAuthorized,
    required this.authorizeAllGatewayCredentials,
    required this.refreshTelegramChannel,
    required this.saveTelegramToken,
    required this.clearTelegramToken,
    required this.approveTelegramPairing,
    required this.revokeTelegramChat,
  });

  factory ModelsCatalogActions.fromIntents(IntentSink<ModelsIntent> intents) {
    const origin = ActionOrigin(
      scope: modelsPresentationScope,
      resource: modelsCatalogResource,
    );
    final channel = CallbackActions<ModelsIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return ModelsCatalogActions(
      origin: origin,
      refreshModels: () => channel.dispatch(const RefreshModels()),
      refreshGateway: () => channel.dispatch(const RefreshGateway()),
      setGatewayEnabled: (enabled) =>
          channel.dispatch(SetGatewayEnabled(enabled)),
      saveGatewayEndpoint: (endpoint) =>
          channel.dispatch(SaveGatewayEndpoint(endpoint)),
      selectGatewayModel: (providerId, modelId) =>
          channel.dispatch(SelectGatewayModel(providerId, modelId)),
      authorizeModelProvider: (providerId) =>
          channel.dispatch(AuthorizeModelProvider(providerId)),
      recoverGateway: () => channel.dispatch(const RecoverModelGateway()),
      refreshGatewayCredentials: () =>
          channel.dispatch(const RefreshGatewayCredentials()),
      migrateGatewayCredentials: () =>
          channel.dispatch(const MigrateGatewayCredentials()),
      createGatewayCredential:
          ({
            required String provider,
            required String label,
            required String apiKey,
            required int leaseDays,
          }) => channel.dispatch(
            CreateGatewayCredential(
              provider: provider,
              label: label,
              apiKey: apiKey,
              leaseDays: leaseDays,
            ),
          ),
      updateGatewayCredential:
          (credentialId, {String? label, int? extendDays}) => channel.dispatch(
            UpdateGatewayCredential(
              credentialId: credentialId,
              label: label,
              extendDays: extendDays,
            ),
          ),
      deleteGatewayCredential: (credentialId) =>
          channel.dispatch(DeleteGatewayCredential(credentialId)),
      setGatewayCredentialAuthorized: (credentialId, authorized) => channel
          .dispatch(SetGatewayCredentialAuthorized(credentialId, authorized)),
      authorizeAllGatewayCredentials: () =>
          channel.dispatch(const AuthorizeAllGatewayCredentials()),
      refreshTelegramChannel: () =>
          channel.dispatch(const RefreshTelegramChannel()),
      saveTelegramToken: (token) => channel.dispatch(SaveTelegramToken(token)),
      clearTelegramToken: () => channel.dispatch(const ClearTelegramToken()),
      approveTelegramPairing: (code) =>
          channel.dispatch(ApproveTelegramPairing(code)),
      revokeTelegramChat: (chatId) =>
          channel.dispatch(RevokeTelegramChat(chatId)),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function() refreshModels;
  final FutureOr<void> Function() refreshGateway;
  final FutureOr<void> Function(bool enabled) setGatewayEnabled;
  final FutureOr<void> Function(String endpoint) saveGatewayEndpoint;
  final FutureOr<void> Function(String providerId, String modelId)
  selectGatewayModel;
  final FutureOr<void> Function(String providerId) authorizeModelProvider;
  final FutureOr<void> Function() recoverGateway;
  final FutureOr<void> Function() refreshGatewayCredentials;
  final FutureOr<void> Function() migrateGatewayCredentials;
  final FutureOr<void> Function({
    required String provider,
    required String label,
    required String apiKey,
    required int leaseDays,
  })
  createGatewayCredential;
  final FutureOr<void> Function(
    String credentialId, {
    String? label,
    int? extendDays,
  })
  updateGatewayCredential;
  final FutureOr<void> Function(String credentialId) deleteGatewayCredential;
  final FutureOr<void> Function(String credentialId, bool authorized)
  setGatewayCredentialAuthorized;
  final FutureOr<void> Function() authorizeAllGatewayCredentials;
  final FutureOr<void> Function() refreshTelegramChannel;
  final FutureOr<void> Function(String token) saveTelegramToken;
  final FutureOr<void> Function() clearTelegramToken;
  final FutureOr<void> Function(String code) approveTelegramPairing;
  final FutureOr<void> Function(int chatId) revokeTelegramChat;
}
