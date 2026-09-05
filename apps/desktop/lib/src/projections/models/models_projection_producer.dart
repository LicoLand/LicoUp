import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/models/controller/models_semantic_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class ModelsProjectionProducer
    implements ProjectionSource<ModelsProjection> {
  ModelsProjectionProducer(this._owner) : _current = _read(_owner) {
    _subscription = _owner.changes.listen(_handleChange);
  }

  final ModelsSemanticController _owner;
  final StreamController<ProjectionUpdate<ModelsProjection>> _changes =
      StreamController<ProjectionUpdate<ModelsProjection>>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ApplicationChange> _subscription;
  ModelsProjection _current;
  bool _disposed = false;

  @override
  ModelsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ModelsProjection>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) {
    if (_disposed) return;
    final next = _read(_owner);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: _trace(change.cause)));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_changes);
  }

  static ModelsProjection _read(ModelsSemanticController owner) {
    final lifecycle = owner.lifecycle;
    final report = lifecycle.lastReport ?? const <String, dynamic>{};
    final authorization = owner.authorization;
    final noticeCode = owner.noticeCode?.trim() ?? '';
    final stateLabel = lifecycle.state.name;
    final port = owner.configuredPort;
    return ModelsProjection(
      providers: const [],
      gatewayEnabled: lifecycle.state.name == 'running',
      gatewayStateLabel: stateLabel,
      phase: owner.busy
          ? PresentationPhase.applying
          : noticeCode.isNotEmpty && !_successNoticeCodes.contains(noticeCode)
          ? PresentationPhase.failed
          : PresentationPhase.ready,
      gateway: GatewayProjection(
        initialized: owner.gatewayPresentationPrepared,
        endpoint: 'http://127.0.0.1:$port',
        port: port,
        stateLabel: stateLabel,
        running: lifecycle.state.name == 'running',
        managed: lifecycle.managed,
        credentialsApplied: report['credentialsApplied'] == true,
        modelReady: report['modelReady'] == true,
        credentialsAuthorized: authorization.authorized,
        recoveryNoticeLabel: lifecycle.notice?.name ?? '',
        recoveryAttempt: lifecycle.recoveryAttempt,
        maxRecoveryAttempts: LlmGatewayLifecycleController.maxRecoveryAttempts,
        processLabel: '${report['processName'] ?? ''}',
        pid: report['pid'] is int ? report['pid'] as int : null,
      ),
      credentials: [
        for (final entry in authorization.inventoryEntries)
          GatewayCredentialProjection(
            id: '${entry['credentialId'] ?? entry['id'] ?? ''}',
            providerLabel: '${entry['provider'] ?? ''}',
            label: '${entry['label'] ?? ''}',
            authorized: authorization.isCredentialAuthorized(
              '${entry['credentialId'] ?? entry['id'] ?? ''}',
            ),
            createdAtEpochSeconds: entry['createdAtEpochSeconds'] is int
                ? entry['createdAtEpochSeconds'] as int
                : null,
            expiresAtEpochSeconds: entry['expiresAtEpochSeconds'] is int
                ? entry['expiresAtEpochSeconds'] as int
                : null,
          ),
      ],
      telegram: TelegramProjection(
        stateLabel: owner.telegramState,
        configured: owner.telegramConfigured,
        tokenSourceLabel: owner.telegramTokenSource,
        botUsername: owner.telegramBotUsername,
        pairings: [
          for (final item in owner.telegramPairings)
            if ('${item['code'] ?? ''}'.trim().isNotEmpty)
              TelegramPairingProjection(
                code: '${item['code']}'.trim().toUpperCase(),
                chatId: _intValue(item['chatId']),
                userId: _intValue(item['userId']),
                username: _optionalString(item['username']),
              ),
        ],
        chats: [
          for (final item in owner.telegramChats)
            if (_intValue(item['chatId']) != 0)
              TelegramChatProjection(
                chatId: _intValue(item['chatId']),
                userId: _intValue(item['userId']),
                username: _optionalString(item['username']),
                agentId: _optionalString(item['agentId']),
              ),
        ],
      ),
      notice: noticeCode.isEmpty
          ? null
          : PresentationNotice(
              id: 'models-action-failure',
              title: 'Models',
              message: noticeCode,
              severity: _successNoticeCodes.contains(noticeCode)
                  ? PresentationNoticeSeverity.success
                  : PresentationNoticeSeverity.error,
              reasonCode: noticeCode,
            ),
    );
  }
}

const _successNoticeCodes = {
  'gateway_started',
  'gateway_stopped',
  'gateway_endpoint_saved',
  'credential_authorized',
  'credential_revoked',
  'telegram_token_saved',
  'telegram_token_cleared',
  'telegram_pairing_approved',
  'telegram_chat_revoked',
};

int _intValue(Object? value) => value is num ? value.toInt() : 0;

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
