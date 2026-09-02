import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_result_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_privacy_projection.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

/// Typed event names emitted by the generated conversation delta stream.
///
/// The protocol generator owns envelope decoding, request/workflow binding,
/// and sequence validation. This enum is only the application projection of
/// the already-decoded event discriminator; widgets never inspect wire maps.
enum ConversationProjectionEventKind {
  turnBound('dispatch.turn.bound'),
  turnStarted('dispatch.turn.started'),
  turnAccepted('agent.turn.accepted'),
  turnProcessing('agent.turn.processing'),
  userMessageCreated('conversation.user.message'),
  messageChunk('agent.message.chunk'),
  messageCompleted('agent.message.completed'),
  turnCompleted('dispatch.turn.completed'),
  turnFailed('dispatch.turn.failed'),
  permissionDenied('permission.denied'),
  approvalNeeded('agent.approval.needed'),
  runtimeUpdating('agent.runtime.updating'),
  runtimeUpdateCompleted('agent.runtime.update.completed'),
  runtimeUpdateInterrupted('agent.runtime.update.interrupted'),
  unknown('');

  const ConversationProjectionEventKind(this.wireName);

  final String wireName;

  static ConversationProjectionEventKind fromWire(Object? value) {
    if (value is! String) return ConversationProjectionEventKind.unknown;
    for (final candidate in ConversationProjectionEventKind.values) {
      if (candidate != ConversationProjectionEventKind.unknown &&
          candidate.wireName == value) {
        return candidate;
      }
    }
    return ConversationProjectionEventKind.unknown;
  }
}

/// Rust-projected interaction state for one conversation scope.
///
/// Nullable enablement is intentional. Older protocol frames do not carry the
/// flags, so consumers can preserve their existing availability projection
/// without pretending that an absent field was sent by Rust.
final class ConversationProjectedTurnState {
  const ConversationProjectedTurnState({
    this.phase = ConversationTurnState.unknown,
    this.inputEnabled,
    this.cancelEnabled,
  });

  final ConversationTurnState phase;
  final bool? inputEnabled;
  final bool? cancelEnabled;

  bool get active => switch (phase) {
    ConversationTurnState.pending ||
    ConversationTurnState.claimed ||
    ConversationTurnState.running ||
    ConversationTurnState.waitingForHuman => true,
    _ => false,
  };

  ConversationProjectedTurnState copyWith({
    ConversationTurnState? phase,
    bool? inputEnabled,
    bool? cancelEnabled,
    bool preserveInputEnabled = true,
    bool preserveCancelEnabled = true,
  }) => ConversationProjectedTurnState(
    phase: phase ?? this.phase,
    inputEnabled: preserveInputEnabled
        ? inputEnabled ?? this.inputEnabled
        : inputEnabled,
    cancelEnabled: preserveCancelEnabled
        ? cancelEnabled ?? this.cancelEnabled
        : cancelEnabled,
  );
}

final class ConversationScopeProjection {
  const ConversationScopeProjection({
    this.messages = const <AgentConversationMessage>[],
    this.turnState = const ConversationProjectedTurnState(),
  });

  final List<AgentConversationMessage> messages;
  final ConversationProjectedTurnState turnState;
}

/// Reactive mirror of the Rust conversation projection.
///
/// [applyDelta] is the only method that mutates projection state. The generated
/// [ConversationDelta] type guarantees that widgets cannot bypass protocol
/// decoding or sequence binding. Notifications are coalesced so token-sized
/// deltas update at most once per display interval while terminal transitions
/// remain immediate.
final class ConversationStateHolder extends ChangeNotifier {
  static const Duration _streamPublishInterval = Duration(milliseconds: 32);

  final Map<String, _ConversationScopeState> _scopes =
      <String, _ConversationScopeState>{};
  Timer? _publishTimer;
  bool _disposed = false;

  ConversationScopeProjection projectionFor(String scopeKey) {
    final scope = _scopes[scopeKey.trim()];
    if (scope == null) return const ConversationScopeProjection();
    return ConversationScopeProjection(
      messages: scope.process.projectedMessages(includeUser: false),
      turnState: scope.turnState,
    );
  }

  List<AgentConversationMessage> messagesFor(String scopeKey) =>
      projectionFor(scopeKey).messages;

  ConversationProjectedTurnState turnStateFor(String scopeKey) =>
      projectionFor(scopeKey).turnState;

  Iterable<String> get scopeKeys => _scopes.keys;

  /// Removes one scope's projection state and publishes immediately.
  ///
  /// Turn scopes are ephemeral for surfaces that detach finished turns (for
  /// example the canonical group pane): once a turn settles, the canonical
  /// readback owns the completed reply, so the live scope must leave the
  /// projection before the reload lands. One-to-one workspaces keep their
  /// conversation scopes for the workspace lifetime and never call this.
  void removeScope(String scopeKey) {
    if (_disposed) return;
    if (_scopes.remove(scopeKey.trim()) == null) return;
    _publishTimer?.cancel();
    _publishTimer = null;
    notifyListeners();
  }

  /// Applies one generated, sequence-bound delta to one conversation scope.
  /// Returns false when the delta has no renderable state consequence.
  bool applyDelta(
    ConversationDelta delta, {
    required String scopeKey,
    required String participantAgentId,
    required String participantLabel,
    String participantRole = '',
  }) {
    if (_disposed || delta is! ConversationDeltaEvent) return false;
    final normalizedScope = scopeKey.trim();
    if (normalizedScope.isEmpty) return false;
    final event = _ProjectedConversationEvent.fromDelta(delta);
    if (event == null) {
      return false;
    }
    final identity = event.turnIdentity;
    if (identity.isEmpty) return false;

    var scope = _scopes[normalizedScope];
    if (scope == null || scope.process.turnId != identity) {
      scope = _ConversationScopeState(
        process: ConversationTurnProcessState(
          turnId: identity,
          userText: '',
          createdAt: event.createdAt,
          scopeKey: normalizedScope,
        ),
      );
      _scopes[normalizedScope] = scope;
    }

    final dispatchEvent = AgentDispatchEvent(
      kind: event.kind.wireName.isEmpty ? event.rawKind : event.kind.wireName,
      sessionId: event.sessionId,
      turnId: event.turnId,
      payload: event.payload,
    );
    scope.process.recordParticipant(
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    scope.turnState = _nextTurnState(scope.turnState, event);

    switch (event.kind) {
      case ConversationProjectionEventKind.turnBound ||
          ConversationProjectionEventKind.turnStarted ||
          ConversationProjectionEventKind.turnAccepted:
        _applyLifecyclePrefix(scope.process, event.payload);
      case ConversationProjectionEventKind.turnProcessing:
        _applyLifecyclePrefix(scope.process, event.payload);
        final evidenceKind = _text(event.payload['evidenceKind']);
        if (const {'reasoning', 'tool', 'plan'}.contains(evidenceKind)) {
          applyPersistentTurnProcessEvent(
            state: scope.process,
            event: dispatchEvent,
            agentId: participantAgentId,
            participantLabel: participantLabel,
            participantRole: participantRole,
          );
        }
      case ConversationProjectionEventKind.runtimeUpdating ||
          ConversationProjectionEventKind.runtimeUpdateCompleted ||
          ConversationProjectionEventKind.runtimeUpdateInterrupted:
        _applyRuntimeUpdate(
          scope.process,
          event,
          participantAgentId,
          participantLabel,
          participantRole,
        );
      case ConversationProjectionEventKind.userMessageCreated:
        _applyUserMessageDelta(scope.process, event);
      case ConversationProjectionEventKind.messageChunk ||
          ConversationProjectionEventKind.messageCompleted:
        _applyMessageDelta(
          scope.process,
          event,
          participantAgentId,
          participantLabel,
          participantRole,
        );
      case ConversationProjectionEventKind.turnCompleted ||
          ConversationProjectionEventKind.turnFailed ||
          ConversationProjectionEventKind.permissionDenied ||
          ConversationProjectionEventKind.approvalNeeded ||
          ConversationProjectionEventKind.unknown:
        applyPersistentTurnProcessEvent(
          state: scope.process,
          event: dispatchEvent,
          agentId: participantAgentId,
          participantLabel: participantLabel,
          participantRole: participantRole,
        );
        if (event.kind == ConversationProjectionEventKind.turnCompleted &&
            scope.process.replyText.trim().isEmpty) {
          final terminalText = _text(event.payload['text']);
          if (terminalText.isNotEmpty) {
            scope.process.setReplyText(
              terminalText,
              createdAt: event.createdAt,
              participantAgentId: participantAgentId,
              participantLabel: participantLabel,
              participantRole: participantRole,
            );
          }
        }
    }

    _publish(immediate: !scope.turnState.active);
    return true;
  }

  void _publish({required bool immediate}) {
    if (_disposed) return;
    if (immediate) {
      _publishTimer?.cancel();
      _publishTimer = null;
      notifyListeners();
      return;
    }
    _publishTimer ??= Timer(_streamPublishInterval, () {
      _publishTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _publishTimer?.cancel();
    _publishTimer = null;
    super.dispose();
  }
}

final class _ConversationScopeState {
  _ConversationScopeState({required this.process});

  final ConversationTurnProcessState process;
  ConversationProjectedTurnState turnState =
      const ConversationProjectedTurnState();
}

final class _ProjectedConversationEvent {
  const _ProjectedConversationEvent({
    required this.kind,
    required this.rawKind,
    required this.sessionId,
    required this.turnId,
    required this.turnHandle,
    required this.createdAt,
    required this.payload,
  });

  final ConversationProjectionEventKind kind;
  final String rawKind;
  final String sessionId;
  final String turnId;
  final String turnHandle;
  final String createdAt;
  final Map<String, dynamic> payload;

  String get turnIdentity {
    if (turnId.isNotEmpty) return turnId;
    if (turnHandle.isNotEmpty) return turnHandle;
    return sessionId;
  }

  static _ProjectedConversationEvent? fromDelta(ConversationDeltaEvent delta) {
    final rawKind = _text(delta.event['event']);
    if (rawKind.isEmpty) return null;
    final rawPayload = delta.event['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};
    final outerTurnHandle = _text(delta.event['turnHandle']);
    final payloadTurnHandle = _text(payload['turnHandle']);
    return _ProjectedConversationEvent(
      kind: ConversationProjectionEventKind.fromWire(rawKind),
      rawKind: rawKind,
      sessionId: _text(delta.event['sessionId']),
      turnId: _text(delta.event['turnId']),
      turnHandle: outerTurnHandle.isNotEmpty
          ? outerTurnHandle
          : payloadTurnHandle,
      createdAt: _text(delta.event['createdAt']).isNotEmpty
          ? _text(delta.event['createdAt'])
          : _text(payload['createdAt']),
      payload: payload,
    );
  }
}

ConversationProjectedTurnState _nextTurnState(
  ConversationProjectedTurnState current,
  _ProjectedConversationEvent event,
) {
  final rawTurnState = event.payload['turnState'];
  final turnStateMap = rawTurnState is Map
      ? Map<String, dynamic>.from(rawTurnState)
      : const <String, dynamic>{};
  var phase = ConversationTurnState.fromWire(
    turnStateMap['state'] ??
        (rawTurnState is String ? rawTurnState : null) ??
        event.payload['state'],
  );
  if (phase == ConversationTurnState.unknown) {
    phase = _phaseFromExplicitLifecycle(event);
  }
  final inputEnabled = _nullableBool(
    turnStateMap['inputEnabled'] ??
        turnStateMap['input_enabled'] ??
        event.payload['inputEnabled'] ??
        event.payload['input_enabled'],
  );
  final cancelEnabled = _nullableBool(
    turnStateMap['cancelEnabled'] ??
        turnStateMap['cancel_enabled'] ??
        event.payload['cancelEnabled'] ??
        event.payload['cancel_enabled'],
  );
  return current.copyWith(
    phase: phase == ConversationTurnState.unknown ? current.phase : phase,
    inputEnabled: inputEnabled,
    cancelEnabled: cancelEnabled,
  );
}

ConversationTurnState _phaseFromExplicitLifecycle(
  _ProjectedConversationEvent event,
) {
  final terminal = event.payload['terminalTransition'];
  if (terminal is Map) {
    if (terminal['kind'] == 'failed') return ConversationTurnState.failed;
    if (terminal['kind'] == 'lifecycle' && terminal['stage'] == 'completed') {
      return ConversationTurnState.succeeded;
    }
  }
  if (event.kind == ConversationProjectionEventKind.turnFailed) {
    return ConversationTurnState.failed;
  }
  if (event.kind == ConversationProjectionEventKind.turnCompleted) {
    return ConversationTurnState.succeeded;
  }
  final stages = event.payload['lifecyclePrefix'];
  if (stages is! List || stages.isEmpty) {
    return ConversationTurnState.unknown;
  }
  return switch (_text(stages.last)) {
    'submitted' => ConversationTurnState.pending,
    'accepted' => ConversationTurnState.claimed,
    'processing' || 'responding' => ConversationTurnState.running,
    'completed' => ConversationTurnState.succeeded,
    'failed' => ConversationTurnState.failed,
    _ => ConversationTurnState.unknown,
  };
}

void _applyLifecyclePrefix(
  ConversationTurnProcessState state,
  Map<String, dynamic> payload,
) {
  final prefix = payload['lifecyclePrefix'];
  if (prefix is! List) return;
  for (final stage in prefix) {
    state.advanceStage(_text(stage));
  }
}

void _applyRuntimeUpdate(
  ConversationTurnProcessState state,
  _ProjectedConversationEvent event,
  String participantAgentId,
  String participantLabel,
  String participantRole,
) {
  final phase = _text(event.payload['phase']);
  final version = _text(event.payload['version']);
  final hint = _text(event.payload['hint']);
  final terminal = switch (event.kind) {
    ConversationProjectionEventKind.runtimeUpdateCompleted => 'completed',
    ConversationProjectionEventKind.runtimeUpdateInterrupted => 'interrupted',
    _ => '',
  };
  final phaseLabel = switch (phase) {
    'preparing' => '准备中',
    'downloading' => '下载中',
    'installing' => '安装中',
    _ => '',
  };
  final subtitle = switch (terminal) {
    'completed' => 'Cursor Agent 更新完成${version.isEmpty ? '' : ' · $version'}',
    'interrupted' => 'Cursor Agent 更新中断${hint.isEmpty ? '' : ' · $hint'}',
    _ =>
      'Cursor Agent 正在更新${version.isEmpty ? '' : ' $version'}'
          '${phaseLabel.isEmpty ? '' : ' · $phaseLabel'}',
  };
  state.setRuntimeUpdate(
    AgentConversationMessage(
      id: '${state.turnId}-runtime-update',
      role: 'event',
      text: terminal.isEmpty ? phase : terminal,
      createdAt: event.createdAt,
      layer: AgentConversationSemanticLayer.execution,
      cardType: 'runtime-update',
      cardTitle: event.rawKind,
      cardSubtitle: subtitle,
      stableIdentity: '${state.turnId}-runtime-update',
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    ),
  );
}

void _applyMessageDelta(
  ConversationTurnProcessState state,
  _ProjectedConversationEvent event,
  String fallbackAgentId,
  String fallbackLabel,
  String fallbackRole,
) {
  _applyLifecyclePrefix(state, event.payload);
  final participantAgentId = _text(event.payload['participantAgentId']).isEmpty
      ? fallbackAgentId
      : _text(event.payload['participantAgentId']);
  final participantLabel = _text(event.payload['participantLabel']).isEmpty
      ? fallbackLabel
      : _text(event.payload['participantLabel']);
  final participantRole = _text(event.payload['participantRole']).isEmpty
      ? fallbackRole
      : _text(event.payload['participantRole']);
  final messageUnit = _text(event.payload['messageUnit']);
  final participantKey = state.participantReplyKey(
    turnId: state.turnId,
    participantAgentId: participantAgentId,
    participantRole: participantRole,
    messageUnit: messageUnit,
  );
  if (participantKey == null) return;
  final merged = ConversationRuntimeResultPolicy.mergeProgressiveText(
    state.replyTextFor(participantKey),
    (event.payload['text'] ?? '').toString(),
    completed: event.kind == ConversationProjectionEventKind.messageCompleted,
  );
  final visible = visibleConversationMessageText(
    'assistant',
    merged,
    kind: AgentConversationMessageKind.assistant,
    agentId: participantAgentId,
  );
  state.setReplyText(
    visible,
    createdAt: event.createdAt,
    participantKey: participantKey,
    participantAgentId: participantAgentId,
    participantLabel: participantLabel,
    participantRole: participantRole,
    messageUnit: messageUnit,
  );
}

/// Mirrors the native submitted-user-message delta onto the blackboard. The
/// text and role arrive from Rust; Flutter never synthesizes a user message
/// outside this delta path.
void _applyUserMessageDelta(
  ConversationTurnProcessState state,
  _ProjectedConversationEvent event,
) {
  _applyLifecyclePrefix(state, event.payload);
  final text = _text(event.payload['text']);
  if (text.isEmpty) return;
  final identity = '${state.turnId}-user';
  state.appendEvidence(
    AgentConversationMessage(
      id: identity,
      role: 'user',
      text: text,
      createdAt: event.createdAt,
      layer: AgentConversationSemanticLayer.thread,
      stableIdentity: identity,
    ),
  );
}

bool? _nullableBool(Object? value) => value is bool ? value : null;

String _text(Object? value) => value is String ? value.trim() : '';
