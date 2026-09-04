import 'package:licoup/src/presentation/presentation_semantics.dart';

final class ModelProviderProjection {
  ModelProviderProjection({
    required this.id,
    required this.name,
    required Iterable<PresentationChoice> models,
    required this.authorized,
  }) : models = immutablePresentationList(models);

  final String id;
  final String name;
  final List<PresentationChoice> models;
  final bool authorized;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelProviderProjection &&
          other.id == id &&
          other.name == name &&
          samePresentationList(other.models, models) &&
          other.authorized == authorized;

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(models), authorized);
}

final class GatewayProjection {
  const GatewayProjection({
    this.initialized = false,
    required this.endpoint,
    required this.port,
    required this.stateLabel,
    required this.running,
    required this.managed,
    required this.credentialsApplied,
    required this.modelReady,
    required this.credentialsAuthorized,
    this.recoveryNoticeLabel = '',
    this.recoveryAttempt = 0,
    this.maxRecoveryAttempts = 3,
    this.processLabel = '',
    this.pid,
  });

  final bool initialized;
  final String endpoint;
  final int port;
  final String stateLabel;
  final bool running;
  final bool managed;
  final bool credentialsApplied;
  final bool modelReady;
  final bool credentialsAuthorized;
  final String recoveryNoticeLabel;
  final int recoveryAttempt;
  final int maxRecoveryAttempts;
  final String processLabel;
  final int? pid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayProjection &&
          other.initialized == initialized &&
          other.endpoint == endpoint &&
          other.port == port &&
          other.stateLabel == stateLabel &&
          other.running == running &&
          other.managed == managed &&
          other.credentialsApplied == credentialsApplied &&
          other.modelReady == modelReady &&
          other.credentialsAuthorized == credentialsAuthorized &&
          other.recoveryNoticeLabel == recoveryNoticeLabel &&
          other.recoveryAttempt == recoveryAttempt &&
          other.maxRecoveryAttempts == maxRecoveryAttempts &&
          other.processLabel == processLabel &&
          other.pid == pid;

  @override
  int get hashCode => Object.hash(
    initialized,
    endpoint,
    port,
    stateLabel,
    running,
    managed,
    credentialsApplied,
    modelReady,
    credentialsAuthorized,
    recoveryNoticeLabel,
    recoveryAttempt,
    maxRecoveryAttempts,
    processLabel,
    pid,
  );
}

final class GatewayCredentialProjection {
  const GatewayCredentialProjection({
    required this.id,
    required this.providerLabel,
    required this.label,
    required this.authorized,
    this.createdAtEpochSeconds,
    this.expiresAtEpochSeconds,
  });

  final String id;
  final String providerLabel;
  final String label;
  final bool authorized;
  final int? createdAtEpochSeconds;
  final int? expiresAtEpochSeconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GatewayCredentialProjection &&
          other.id == id &&
          other.providerLabel == providerLabel &&
          other.label == label &&
          other.authorized == authorized &&
          other.createdAtEpochSeconds == createdAtEpochSeconds &&
          other.expiresAtEpochSeconds == expiresAtEpochSeconds;

  @override
  int get hashCode => Object.hash(
    id,
    providerLabel,
    label,
    authorized,
    createdAtEpochSeconds,
    expiresAtEpochSeconds,
  );
}

final class TelegramPairingProjection {
  const TelegramPairingProjection({
    required this.code,
    required this.chatId,
    required this.userId,
    this.username,
  });

  final String code;
  final int chatId;
  final int userId;
  final String? username;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TelegramPairingProjection &&
          other.code == code &&
          other.chatId == chatId &&
          other.userId == userId &&
          other.username == username;

  @override
  int get hashCode => Object.hash(code, chatId, userId, username);
}

final class TelegramChatProjection {
  const TelegramChatProjection({
    required this.chatId,
    required this.userId,
    this.username,
    this.agentId,
  });

  final int chatId;
  final int userId;
  final String? username;
  final String? agentId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TelegramChatProjection &&
          other.chatId == chatId &&
          other.userId == userId &&
          other.username == username &&
          other.agentId == agentId;

  @override
  int get hashCode => Object.hash(chatId, userId, username, agentId);
}

final class TelegramProjection {
  TelegramProjection({
    required this.stateLabel,
    required this.configured,
    required this.tokenSourceLabel,
    required Iterable<TelegramPairingProjection> pairings,
    required Iterable<TelegramChatProjection> chats,
    this.botUsername,
  }) : pairings = immutablePresentationList(pairings),
       chats = immutablePresentationList(chats);

  final String stateLabel;
  final bool configured;
  final String tokenSourceLabel;
  final String? botUsername;
  final List<TelegramPairingProjection> pairings;
  final List<TelegramChatProjection> chats;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TelegramProjection &&
          other.stateLabel == stateLabel &&
          other.configured == configured &&
          other.tokenSourceLabel == tokenSourceLabel &&
          other.botUsername == botUsername &&
          samePresentationList(other.pairings, pairings) &&
          samePresentationList(other.chats, chats);

  @override
  int get hashCode => Object.hash(
    stateLabel,
    configured,
    tokenSourceLabel,
    botUsername,
    Object.hashAll(pairings),
    Object.hashAll(chats),
  );
}

final class ModelsProjection {
  ModelsProjection({
    required Iterable<ModelProviderProjection> providers,
    required this.gatewayEnabled,
    required this.gatewayStateLabel,
    required this.phase,
    GatewayProjection? gateway,
    Iterable<GatewayCredentialProjection> credentials = const [],
    TelegramProjection? telegram,
    this.notice,
  }) : providers = immutablePresentationList(providers),
       gateway =
           gateway ??
           const GatewayProjection(
             initialized: false,
             endpoint: 'http://127.0.0.1:15722',
             port: 15722,
             stateLabel: 'unknown',
             running: false,
             managed: false,
             credentialsApplied: false,
             modelReady: false,
             credentialsAuthorized: false,
           ),
       credentials = immutablePresentationList(credentials),
       telegram =
           telegram ??
           TelegramProjection(
             stateLabel: 'unknown',
             configured: false,
             tokenSourceLabel: 'none',
             pairings: const [],
             chats: const [],
           );

  final List<ModelProviderProjection> providers;
  final bool gatewayEnabled;
  final String gatewayStateLabel;
  final PresentationPhase phase;
  final GatewayProjection gateway;
  final List<GatewayCredentialProjection> credentials;
  final TelegramProjection telegram;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelsProjection &&
          samePresentationList(other.providers, providers) &&
          other.gatewayEnabled == gatewayEnabled &&
          other.gatewayStateLabel == gatewayStateLabel &&
          other.phase == phase &&
          other.gateway == gateway &&
          samePresentationList(other.credentials, credentials) &&
          other.telegram == telegram &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(providers),
    gatewayEnabled,
    gatewayStateLabel,
    phase,
    gateway,
    Object.hashAll(credentials),
    telegram,
    notice,
  );
}
