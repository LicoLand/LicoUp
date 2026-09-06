import 'dart:async';
import 'dart:convert';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Conversation read-side composition with separate native-history and
/// Canonical Conversation authorities. Both 1:1 and group turns are projected
/// from the application's sole [ConversationStateHolder].
final class ConversationProjectionProducer {
  ConversationProjectionProducer(this._controller)
    : projection = ConversationProjectionChannel<ConversationProjection>(
        _readRoot(_controller),
      ),
      nativeCatalog =
          ConversationProjectionChannel<NativeConversationCatalogProjection>(
            _readNativeCatalog(_controller),
          ),
      canonicalEvents =
          ConversationProjectionChannel<CanonicalConversationProjection>(
            _readCanonical(
              _controller,
              const <String, dynamic>{},
              const <ConversationParticipantRuntimeProjection>[],
            ),
          ),
      persistentTurns = ConversationProjectionChannel<PersistentTurnProjection>(
        _readPersistentTurns(_controller, const {}),
      ),
      composer = ConversationProjectionChannel<ComposerProjection>(
        _readComposer(_controller),
      ),
      attachments =
          ConversationProjectionChannel<ConversationAttachmentsProjection>(
            _readAttachments(_controller, const <String, String>{}),
          ),
      tabActivity =
          ConversationProjectionChannel<ConversationTabActivityProjection>(
            _readTabActivity(_controller),
          ),
      notifications =
          ConversationProjectionChannel<ConversationNotificationsProjection>(
            _readNotifications(_controller),
          ),
      archive = ConversationProjectionChannel<ConversationArchiveProjection>(
        _readArchive(_controller),
      ) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      _controller.conversationPresentationSignals.structureChanges.listen(
        _handleChange,
      ),
      _controller.conversationPresentationSignals.activeChanges.listen(
        _handleChange,
      ),
      _controller.conversationPresentationSignals.liveChanges.listen(
        _handleChange,
      ),
      _controller.conversationPresentationSignals.tabActivityChanges.listen(
        _handleChange,
      ),
      _controller.conversationStateHolder.changes.listen(_handleChange),
      _controller.clientConversationController.changes.listen(_handleChange),
      _controller.messagingNotificationCenter.changes.listen(_handleChange),
      _controller.targetController.changes.listen(_handleChange),
      _controller.providerQuotaController.changes.listen(_handleChange),
    ];
    unawaited(_synchronizeAssistantProfile());
    unawaited(_synchronizeStrategyProjection());
    unawaited(_synchronizeGroupTurns());
  }

  final ClientController _controller;
  final _groupTurns = <String, _GroupTurn>{};
  final _groupTurnSubscriptions =
      <String, StreamSubscription<AgentDispatchEvent>>{};
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  bool _syncingGroupTurns = false;
  bool _groupSyncRequested = false;
  Map<String, dynamic> _assistantProfile = const <String, dynamic>{};
  String _assistantProfileMembershipId = '';
  int _assistantProfileGeneration = 0;
  List<ConversationParticipantRuntimeProjection> _strategyProfiles = const [];
  String _strategyProjectionConversationId = '';
  String _strategyProjectionRevision = '';
  int _strategyProjectionGeneration = 0;
  Map<String, String> _attachmentDataById = const <String, String>{};
  bool _closed = false;

  final ConversationProjectionChannel<ConversationProjection> projection;
  final ConversationProjectionChannel<NativeConversationCatalogProjection>
  nativeCatalog;
  final ConversationProjectionChannel<CanonicalConversationProjection>
  canonicalEvents;
  final ConversationProjectionChannel<PersistentTurnProjection> persistentTurns;
  final ConversationProjectionChannel<ComposerProjection> composer;
  final ConversationProjectionChannel<ConversationAttachmentsProjection>
  attachments;
  final ConversationProjectionChannel<ConversationTabActivityProjection>
  tabActivity;
  final ConversationProjectionChannel<ConversationNotificationsProjection>
  notifications;
  final ConversationProjectionChannel<ConversationArchiveProjection> archive;

  void _handleChange(ApplicationChange change) {
    if (_closed) return;
    _publishAll(_trace(change.cause));
    unawaited(_synchronizeAssistantProfile());
    unawaited(_synchronizeStrategyProjection());
    unawaited(_synchronizeGroupTurns());
  }

  void publishLocalChange({TraceContext? trace}) => _publishAll(trace);

  /// Publishes only the composer channel. Draft edits arrive at keystroke
  /// rate; recomputing and equality-scanning the whole projection set per
  /// keystroke is wasted work because only the draft can differ.
  void publishComposerDraft({TraceContext? trace}) =>
      composer.publish(_readComposer(_controller), trace: trace);

  void _publishAll(TraceContext? trace) {
    projection.publish(_readRoot(_controller), trace: trace);
    nativeCatalog.publish(_readNativeCatalog(_controller), trace: trace);
    canonicalEvents.publish(
      _readCanonical(_controller, _assistantProfile, _strategyProfiles),
      trace: trace,
    );
    persistentTurns.publish(
      _readPersistentTurns(_controller, _groupTurns),
      trace: trace,
    );
    composer.publish(_readComposer(_controller), trace: trace);
    attachments.publish(
      _readAttachments(_controller, _attachmentDataById),
      trace: trace,
    );
    tabActivity.publish(_readTabActivity(_controller), trace: trace);
    notifications.publish(_readNotifications(_controller), trace: trace);
    archive.publish(_readArchive(_controller), trace: trace);
  }

  Future<void> refreshCanonicalAssistantProfile() =>
      _synchronizeAssistantProfile(force: true);

  Future<void> refreshCanonicalStrategyProjection() =>
      _synchronizeStrategyProjection(force: true);

  void cacheAttachmentBytes(
    Map<String, List<int>> bytesById, {
    TraceContext? trace,
  }) {
    _attachmentDataById = Map<String, String>.unmodifiable({
      for (final entry in bytesById.entries)
        entry.key: base64Encode(entry.value),
    });
    _publishAll(trace);
  }

  Future<void> _synchronizeAssistantProfile({bool force = false}) async {
    if (_closed) return;
    final membershipId =
        _controller
            .clientConversationController
            .selectedConversation
            ?.assistantMembershipId
            .trim() ??
        '';
    if (!force && membershipId == _assistantProfileMembershipId) return;
    _assistantProfileMembershipId = membershipId;
    final generation = ++_assistantProfileGeneration;
    if (membershipId.isEmpty) {
      if (_assistantProfile.isEmpty) return;
      _assistantProfile = const <String, dynamic>{};
      _publishAll(null);
      return;
    }
    Map<String, dynamic> profile = const <String, dynamic>{};
    try {
      profile =
          await _controller.clientConversationController.membershipProfile(
            membershipId,
          ) ??
          const <String, dynamic>{};
    } on Object {
      profile = const <String, dynamic>{};
    }
    if (_closed ||
        generation != _assistantProfileGeneration ||
        membershipId != _assistantProfileMembershipId) {
      return;
    }
    _assistantProfile = Map<String, dynamic>.unmodifiable(profile);
    _publishAll(null);
  }

  Future<void> _synchronizeStrategyProjection({bool force = false}) async {
    if (_closed) return;
    final conversation =
        _controller.clientConversationController.selectedConversation;
    final conversationId = conversation?.id.trim() ?? '';
    final revision = conversation?.strategyRevision.trim() ?? '';
    if (!force &&
        conversationId == _strategyProjectionConversationId &&
        revision == _strategyProjectionRevision) {
      return;
    }
    final generation = ++_strategyProjectionGeneration;
    if (conversation == null || !conversation.group || revision.isEmpty) {
      _strategyProjectionConversationId = conversationId;
      _strategyProjectionRevision = revision;
      if (_strategyProfiles.isEmpty) return;
      _strategyProfiles = const [];
      _publishAll(null);
      return;
    }
    try {
      final definitions = adaptiveFlywheelMaps(
        await _controller.adaptiveFlywheelGateway.execute({
          'action': 'strategy.definition.list',
        }),
      ).map(AdaptiveFlywheelDefinition.fromJson);
      if (!definitions.any(
        (definition) =>
            definition.authorized && definition.revisionDigest == revision,
      )) {
        _strategyProjectionConversationId = conversationId;
        _strategyProjectionRevision = revision;
        return;
      }
      final inspection = AdaptiveFlywheelInspection.fromJson(
        adaptiveFlywheelStringMap(
          await _controller.adaptiveFlywheelGateway.execute({
            'action': 'strategy.definition.inspect',
            'revisionDigest': revision,
          }),
        ),
      );
      if (_closed ||
          generation != _strategyProjectionGeneration ||
          _controller.clientConversationController.selectedConversationId !=
              conversationId ||
          !inspection.authorized) {
        return;
      }
      _strategyProjectionConversationId = conversationId;
      _strategyProjectionRevision = revision;
      _strategyProfiles =
          List<ConversationParticipantRuntimeProjection>.unmodifiable([
            for (final slot in inspection.slots.where(
              (slot) => slot.kind == 'actor',
            ))
              for (final binding in inspection.bindings[slot.id] ?? const [])
                if (binding.valueId.trim().isNotEmpty)
                  ConversationParticipantRuntimeProjection(
                    agentId: binding.valueId.trim(),
                    model: binding.model.trim(),
                    reasoningEffort: binding.reasoningEffort.trim(),
                  ),
          ]);
      _publishAll(null);
    } on Object {
      // The persisted revision remains authoritative when inspection is
      // unavailable; the renderer simply omits runtime-profile decoration.
    }
  }

  Future<void> _synchronizeGroupTurns() async {
    if (_closed) return;
    if (_syncingGroupTurns) {
      _groupSyncRequested = true;
      return;
    }
    _syncingGroupTurns = true;
    try {
      do {
        _groupSyncRequested = false;
        await _synchronizeGroupTurnsOnce();
      } while (_groupSyncRequested && !_closed);
    } finally {
      _syncingGroupTurns = false;
    }
  }

  Future<void> _synchronizeGroupTurnsOnce() async {
    final conversationId = _controller
        .clientConversationController
        .selectedConversationId
        .trim();
    final gateway = _controller.conversationGateway;
    final persistent = gateway is PersistentAgentConversationGateway
        ? gateway as PersistentAgentConversationGateway
        : null;
    if (conversationId.isEmpty || persistent == null) {
      await _detachGroupTurns();
      return;
    }
    if (_groupTurns.values.any(
      (turn) => turn.conversationId != conversationId,
    )) {
      await _detachGroupTurns();
    }

    final posted = _controller.clientConversationController.liveTurns;
    List<Map<String, dynamic>> discovered = const [];
    try {
      discovered = await persistent.activeTurns(
        agentId: '',
        conversationId: conversationId,
      );
    } on Object {
      // An observer lookup failure is a detach condition, not a turn failure.
    }
    if (_closed ||
        _controller.clientConversationController.selectedConversationId
                .trim() !=
            conversationId) {
      return;
    }
    final byHandle = <String, Map<String, dynamic>>{};
    for (final turn in <Map<String, dynamic>>[...posted, ...discovered]) {
      final handle = (turn['turnHandle'] ?? '').toString().trim();
      if (handle.isNotEmpty) byHandle[handle] = turn;
    }
    for (final entry in byHandle.entries) {
      if (_groupTurnSubscriptions.containsKey(entry.key)) continue;
      final retained = _groupTurns[entry.key];
      if (retained?.settling == true) continue;
      final metadata =
          retained ?? _resolveGroupTurn(conversationId, entry.key, entry.value);
      if (metadata == null) continue;
      _groupTurns[entry.key] = metadata;
      _attachGroupTurn(persistent, metadata);
    }
    _publishAll(null);
  }

  _GroupTurn? _resolveGroupTurn(
    String conversationId,
    String handle,
    Map<String, dynamic> raw,
  ) {
    final membershipId = (raw['membershipId'] ?? '').toString().trim();
    final projectedAgent = (raw['agent'] ?? raw['agentId'] ?? '')
        .toString()
        .trim();
    final conversation =
        _controller.clientConversationController.selectedConversation;
    if (conversation == null || membershipId.isEmpty) return null;
    for (final membership in conversation.activeAgentMemberships) {
      if (membership.id != membershipId) continue;
      final agentId = membership.principal.agentId.trim();
      if (agentId.isEmpty ||
          (projectedAgent.isNotEmpty && projectedAgent != agentId)) {
        return null;
      }
      final label = membership.principal.displayName.trim();
      return _GroupTurn(
        handle: handle,
        conversationId: conversationId,
        membershipId: membershipId,
        agentId: agentId,
        label: label.isEmpty ? agentId : label,
        role: membership.id == conversation.assistantMembershipId
            ? 'assistant'
            : 'member',
      );
    }
    return null;
  }

  void _attachGroupTurn(
    PersistentAgentConversationGateway gateway,
    _GroupTurn turn,
  ) {
    turn.observing = true;
    _groupTurnSubscriptions[turn.handle] = gateway
        .attachActiveTurn(
          turnHandle: turn.handle,
          conversationId: turn.conversationId,
          afterCursor: turn.cursor,
        )
        .listen(
          (event) {
            if (_closed ||
                _controller.clientConversationController.selectedConversationId
                        .trim() !=
                    turn.conversationId) {
              return;
            }
            final cursor = event.payload['cursor'];
            if (cursor is int && cursor > turn.cursor) turn.cursor = cursor;
            _controller.conversationStateHolder.applyDelta(
              ConversationDeltaEvent(<String, dynamic>{
                'event': event.kind,
                'sessionId': event.sessionId,
                'turnId': 'live-${turn.handle}',
                'turnHandle': turn.handle,
                'payload': event.payload,
              }),
              scopeKey: turn.scopeKey,
              participantAgentId: turn.agentId,
              participantLabel: turn.label,
              participantRole: turn.role,
            );
            if (_eventIsTerminal(event)) {
              unawaited(_settleGroupTurn(turn.handle));
            }
          },
          onDone: () => unawaited(_settleGroupTurn(turn.handle)),
          onError: (Object _) => unawaited(_recoverGroupObserver(turn.handle)),
          cancelOnError: false,
        );
  }

  Future<void> _recoverGroupObserver(String handle) async {
    final turn = _groupTurns[handle];
    if (turn == null || turn.settling) return;
    turn
      ..settling = true
      ..observing = false;
    final subscription = _groupTurnSubscriptions.remove(handle);
    if (subscription != null) unawaited(subscription.cancel());
    final reloaded = await _controller.clientConversationController
        .reloadSelected();
    if (_closed) return;
    final selected =
        _controller.clientConversationController.selectedConversationId
            .trim() ==
        turn.conversationId;
    if (!selected) {
      _removeGroupTurn(turn);
    } else if (reloaded && _groupTurnIsDurable(turn)) {
      _surfacePersistedGroupFailure(turn);
      _removeGroupTurn(turn);
    } else {
      Map<String, dynamic>? active;
      final gateway = _controller.conversationGateway;
      PersistentAgentConversationGateway? persistentGateway;
      if (gateway is PersistentAgentConversationGateway) {
        persistentGateway = gateway as PersistentAgentConversationGateway;
        try {
          final discovered = await persistentGateway.activeTurns(
            agentId: '',
            conversationId: turn.conversationId,
          );
          for (final raw in discovered) {
            if ((raw['turnHandle'] ?? '').toString().trim() == handle) {
              active = raw;
              break;
            }
          }
        } on Object {
          active = null;
        }
      }
      if (!_closed &&
          active != null &&
          persistentGateway != null &&
          _controller.clientConversationController.selectedConversationId
                  .trim() ==
              turn.conversationId) {
        turn.settling = false;
        _attachGroupTurn(persistentGateway, turn);
      } else {
        _removeGroupTurn(turn);
      }
    }
    if (_groupTurnSubscriptions.isEmpty) {
      _controller.clientConversationController.settleLiveDispatch();
    }
    _publishAll(null);
  }

  Future<void> _settleGroupTurn(String handle) async {
    final turn = _groupTurns[handle];
    if (turn == null || turn.settling) return;
    turn
      ..settling = true
      ..observing = false;
    final subscription = _groupTurnSubscriptions.remove(handle);
    if (subscription != null) unawaited(subscription.cancel());
    final reloaded = await _controller.clientConversationController
        .reloadSelected();
    if (_closed) return;
    final stillSelected =
        _controller.clientConversationController.selectedConversationId
            .trim() ==
        turn.conversationId;
    final durable = reloaded && _groupTurnIsDurable(turn);
    if (stillSelected && durable) {
      _surfacePersistedGroupFailure(turn);
      _removeGroupTurn(turn);
    } else {
      turn.settling = false;
    }
    if (_groupTurnSubscriptions.isEmpty) {
      _controller.clientConversationController.settleLiveDispatch();
    }
    _publishAll(null);
  }

  bool _groupTurnIsDurable(_GroupTurn turn) =>
      _controller.clientConversationController.events.any(
        (event) => event.finalized && event.correlationId.trim() == turn.handle,
      );

  void _surfacePersistedGroupFailure(_GroupTurn turn) {
    for (final event
        in _controller.clientConversationController.events.reversed) {
      if (!event.finalized || event.correlationId.trim() != turn.handle) {
        continue;
      }
      for (final part in event.parts.reversed) {
        if (part.kind != ConversationEventPartKind.diagnostic) continue;
        final failure = persistentTurnDiagnosticFailure(part.content);
        if (failure == null) continue;
        _controller.clientConversationController.surfaceFailure(
          failure.stage.isEmpty ? 'native/turn' : failure.stage,
          failure.code,
          component: failure.component,
          retryable: failure.retryable,
          recovery: failure.recovery,
        );
        return;
      }
    }
  }

  void _removeGroupTurn(_GroupTurn turn) {
    _groupTurns.remove(turn.handle);
    _controller.conversationStateHolder.removeScope(turn.scopeKey);
  }

  Future<void> _detachGroupTurns() async {
    final subscriptions = _groupTurnSubscriptions.values.toList();
    _groupTurnSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final turn in _groupTurns.values) {
      turn.observing = false;
      _controller.conversationStateHolder.removeScope(turn.scopeKey);
    }
    _groupTurns.clear();
    _publishAll(null);
  }

  Future<void> cancelGroupTurn(String membershipId) async {
    final candidates = _groupTurns.values
        .where((turn) => turn.membershipId == membershipId && !turn.settling)
        .toList(growable: false);
    if (candidates.length != 1) return;
    final source = _controller.conversationGateway;
    final gateway = source is PersistentAgentConversationGateway
        ? source as PersistentAgentConversationGateway
        : null;
    if (gateway == null) return;
    final turn = candidates.single;
    await gateway.cancelActiveTurn(
      turnHandle: turn.handle,
      conversationId: turn.conversationId,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await _detachGroupTurns();
    await Future.wait<void>([
      projection.close(),
      nativeCatalog.close(),
      canonicalEvents.close(),
      persistentTurns.close(),
      composer.close(),
      attachments.close(),
      tabActivity.close(),
      notifications.close(),
      archive.close(),
    ]);
  }
}

final class ConversationProjectionChannel<T> implements ProjectionSource<T> {
  ConversationProjectionChannel(this._current);

  final StreamController<ProjectionUpdate<T>> _controller =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;
  bool _closed = false;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _controller.stream;

  void publish(T next, {TraceContext? trace}) {
    if (_closed || next == _current) return;
    _current = next;
    _controller.add(ProjectionUpdate<T>(next, trace: trace));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

final class _GroupTurn {
  _GroupTurn({
    required this.handle,
    required this.conversationId,
    required this.membershipId,
    required this.agentId,
    required this.label,
    required this.role,
  });

  final String handle;
  final String conversationId;
  final String membershipId;
  final String agentId;
  final String label;
  final String role;
  int cursor = 0;
  bool settling = false;
  bool observing = false;

  String get scopeKey => 'group:$conversationId:$handle';
}

ConversationProjection _readRoot(ClientController controller) {
  final canonical = controller.clientConversationController;
  final canonicalId = canonical.selectedConversationId.trim();
  if (canonicalId.isNotEmpty) {
    return ConversationProjection(
      authority: ConversationAuthority.canonicalConversation,
      conversationId: canonicalId,
      membershipId: canonical.selectedConversation?.assistantMembershipId ?? '',
    );
  }
  return ConversationProjection(
    authority: ConversationAuthority.nativeCatalog,
    conversationId: controller.conversationComposerScopeKey,
    membershipId: controller.selectedConversationAgentId,
  );
}

NativeConversationCatalogProjection _readNativeCatalog(
  ClientController controller,
) {
  final sessions = controller.selectedConversationSessions;
  final catalogs = <NativeConversationAgentCatalogProjection>[
    for (final entry in controller.conversationSessionsByAgent.entries)
      NativeConversationAgentCatalogProjection(
        agentId: entry.key,
        sessions: entry.value,
      ),
  ];
  final runningSessionIds = <String>{
    for (final catalog in catalogs)
      for (final session in catalog.sessions)
        if (_nativeSessionIsRunning(controller, session)) session.id,
  };
  final serve = controller.opencodeServeState;
  return NativeConversationCatalogProjection(
    sessions: [
      for (final session in sessions)
        NativeConversationSessionProjection(
          id: session.id,
          title: session.title,
          updatedLabel: session.updatedAt,
          selected: session.id == controller.selectedConversationSessionId,
        ),
    ],
    nativeSessions: sessions,
    agentCatalogs: catalogs,
    runningSessionIds: runningSessionIds,
    loadingMore: controller.isLoadingMoreSelectedConversationSessions,
    messagePageLoading: controller.isLoadingEarlierSelectedConversationMessages,
    messagePageError: controller.selectedConversationMessagePageError,
    preparingNewConversation: controller.preparingNewConversation,
    authorizingRuntime: controller.isAuthorizingConversationRuntime,
    pendingPermissionRetryTool: controller.pendingPermissionRetryTool,
    supportsLicoProfile: controller.selectedConversationSupportsLicoProfile,
    selectedLicoProfile: controller.selectedConversationLicoProfile,
    supportsImages: controller.selectedConversationSupportsImageAttachments,
    opencodeServeStatus: (serve?['status'] ?? '').toString(),
    opencodeServePort: serve?['port'] is int ? serve!['port'] as int : null,
    opencodeServePortConflict: serve?['portConflict'] == true,
    hasMore: controller.selectedConversationSessionsHasMore,
    phase: controller.isLoadingConversations
        ? PresentationPhase.loading
        : controller.lastError.isNotEmpty
        ? PresentationPhase.failed
        : PresentationPhase.ready,
    notice: controller.lastError.isEmpty
        ? null
        : _notice('native-conversation', controller.lastError),
  );
}

CanonicalConversationProjection _readCanonical(
  ClientController controller,
  Map<String, dynamic> assistantProfile,
  List<ConversationParticipantRuntimeProjection> strategyProfiles,
) {
  final owner = controller.clientConversationController;
  final conversation = owner.selectedConversation;
  final memberships = <String, ClientConversationMembership>{
    for (final membership in conversation?.memberships ?? const [])
      membership.id: membership,
  };
  return CanonicalConversationProjection(
    conversationId: owner.selectedConversationId,
    conversation: conversation,
    canonicalEvents: owner.events,
    recentParticipantAgentIds: owner.recentParticipantAgentIds,
    groupConversations: owner.groupConversations,
    participantRuntimeProfiles: strategyProfiles,
    quotaSnapshots: controller.providerQuotaController.snapshots,
    assistantModel: (assistantProfile['preferredModel'] ?? '').toString(),
    assistantReasoningEffort:
        (assistantProfile['preferredReasoningEffort'] ?? '').toString(),
    failureStage: owner.failureStage,
    failureRef: owner.failureRef,
    failureRecovery: owner.failureRecovery,
    failureCopyBlob: owner.failureCopyBlob,
    sending: owner.sending,
    events: [
      for (final event in owner.events)
        CanonicalConversationEventProjection(
          id: event.id,
          sequence: event.sequence,
          authorLabel:
              memberships[event.authorMembershipId]?.principal.displayName ??
              '',
          parts: [
            for (final part in event.parts)
              ConversationPartProjection(
                id: part.id,
                kind: _canonicalPartKind(part.kind),
                content: part.content,
                collapsed: part.kind != ConversationEventPartKind.text,
              ),
          ],
          finalized: event.finalized,
          sendStateLabel: event.finalized ? 'finalized' : 'streaming',
        ),
    ],
    hasEarlier:
        conversation != null && conversation.eventCount > owner.events.length,
    phase: owner.loading
        ? PresentationPhase.loading
        : owner.failureCode.isNotEmpty
        ? PresentationPhase.failed
        : PresentationPhase.ready,
    dispatchPending: owner.dispatchPending,
    notice: owner.failureCode.isEmpty
        ? null
        : PresentationNotice(
            id: 'canonical-conversation',
            title: 'Conversation',
            message: owner.failureCode,
            severity: PresentationNoticeSeverity.error,
            reasonCode: owner.failureCode,
            reference: owner.failureRef,
            recovery: owner.failureRecovery,
            copyText: owner.failureCopyBlob,
          ),
  );
}

PersistentTurnProjection _readPersistentTurns(
  ClientController controller,
  Map<String, _GroupTurn> groupTurns,
) {
  final canonicalId = controller
      .clientConversationController
      .selectedConversationId
      .trim();
  if (canonicalId.isNotEmpty) {
    return PersistentTurnProjection(
      conversationId: canonicalId,
      memberships: [
        for (final turn in groupTurns.values)
          if (turn.conversationId == canonicalId)
            _membershipTurn(
              controller.conversationStateHolder.projectionFor(turn.scopeKey),
              membershipId: turn.membershipId,
              agentLabel: turn.label,
              participantAgentId: turn.agentId,
              participantRole: turn.role,
              turnHandle: turn.handle,
              observed: turn.observing,
              fallbackFailure:
                  controller.clientConversationController.failureCode,
            ),
      ],
    );
  }
  final scopeKey = controller.conversationComposerScopeKey;
  if (scopeKey.isEmpty) {
    return PersistentTurnProjection(conversationId: '', memberships: const []);
  }
  final agent = controller.selectedConversationAgent;
  final state = controller.conversationStateHolder.projectionFor(scopeKey);
  final hasTurn = state.messages.isNotEmpty || state.turnState.active;
  return PersistentTurnProjection(
    conversationId: scopeKey,
    memberships: hasTurn
        ? [
            _membershipTurn(
              state,
              membershipId: controller.selectedConversationAgentId,
              agentLabel:
                  agent?.label ?? controller.selectedConversationAgentId,
              participantAgentId: controller.selectedConversationAgentId,
              fallbackFailure: controller.lastError,
            ),
          ]
        : const [],
  );
}

MembershipTurnProjection _membershipTurn(
  ConversationScopeProjection state, {
  required String membershipId,
  required String agentLabel,
  required String participantAgentId,
  String participantRole = '',
  String turnHandle = '',
  bool observed = false,
  String fallbackFailure = '',
}) {
  var phase = _turnPhase(state.turnState.phase, fallbackFailure);
  if (phase == PersistentTurnPhase.idle && observed) {
    phase = PersistentTurnPhase.running;
  }
  return MembershipTurnProjection(
    membershipId: membershipId,
    agentLabel: agentLabel,
    phase: phase,
    inputEnabled:
        state.turnState.inputEnabled ?? phase != PersistentTurnPhase.waiting,
    liveParts: _messageParts(state.messages),
    messages: state.messages,
    turnHandle: turnHandle,
    participantAgentId: participantAgentId,
    participantRole: participantRole,
    cancelEnabled:
        state.turnState.cancelEnabled ?? state.turnState.active || observed,
    failureReasonCode: phase == PersistentTurnPhase.failed
        ? fallbackFailure
        : '',
  );
}

List<ConversationPartProjection> _messageParts(
  Iterable<AgentConversationMessage> messages,
) {
  final result = <ConversationPartProjection>[];
  void append(AgentConversationMessage message) {
    result.add(
      ConversationPartProjection(
        id: message.stableIdentity.isEmpty
            ? message.id
            : message.stableIdentity,
        kind: _nativePartKind(message.kind),
        content: message.text,
        collapsed: message.collapsed,
      ),
    );
    for (final child in message.childMessages) {
      append(child);
    }
  }

  for (final message in messages) {
    append(message);
  }
  return result;
}

ComposerProjection _readComposer(ClientController controller) {
  final canonical = controller.clientConversationController;
  final groupId = canonical.selectedConversationId.trim();
  if (groupId.isNotEmpty) {
    final scopeKey = 'group:$groupId';
    return ComposerProjection(
      conversationId: scopeKey,
      draft: controller.conversationPresentationSignals.composerDraftFor(
        scopeKey,
      ),
      inputEnabled:
          canonical.selectedConversation?.localOwnerMembership != null &&
          !canonical.sending,
      sendLabel: canonical.dispatchPending ? 'Steer' : 'Send',
    );
  }
  final scopeKey = controller.conversationComposerScopeKey;
  return ComposerProjection(
    conversationId: scopeKey,
    draft: controller.conversationPresentationSignals.composerDraftFor(
      scopeKey,
    ),
    inputEnabled: controller.selectedConversationAgent?.canRelayRuntime == true,
    sendLabel: controller.isSendingConversationMessage ? 'Steer' : 'Send',
    modelOptions: controller.selectedConversationModelOptions,
    selectedModel: controller.selectedConversationModel,
    defaultModel: controller.selectedConversationDefaultModel,
    reasoningEffortOptions:
        controller.selectedConversationReasoningEffortOptions,
    selectedReasoningEffort: controller.selectedConversationReasoningEffort,
    defaultReasoningEffort:
        controller.selectedConversationDefaultReasoningEffort,
    workingDirectory: controller.selectedConversationWorkingDirectory,
    workingDirectorySelectable:
        controller.canSelectNewConversationWorkingDirectory,
  );
}

ConversationAttachmentsProjection _readAttachments(
  ClientController controller,
  Map<String, String> attachmentDataById,
) {
  final canonicalId = controller
      .clientConversationController
      .selectedConversationId
      .trim();
  final scopeKey = canonicalId.isNotEmpty
      ? 'group:$canonicalId'
      : controller.conversationComposerScopeKey;
  final attachments = controller.conversationPresentationSignals
      .composerAttachmentsFor(scopeKey);
  return ConversationAttachmentsProjection(
    conversationId: scopeKey,
    attachments: [
      for (final attachment in attachments)
        ConversationAttachmentProjection(
          id: attachment.id,
          displayName: attachment.name,
          mediaKind: attachment.mediaType,
          stateLabel: controller.conversationPresentationSignals
              .composerAttachmentStatusFor(scopeKey),
          dataBase64: attachmentDataById[attachment.id] ?? '',
        ),
    ],
    acceptsImages: canonicalId.isNotEmpty
        ? _groupAssistantAcceptsImages(controller)
        : controller.selectedConversationSupportsImageAttachments,
    statusCode: controller.conversationPresentationSignals
        .composerAttachmentStatusFor(scopeKey),
  );
}

bool _groupAssistantAcceptsImages(ClientController controller) {
  final agentId = controller
      .clientConversationController
      .selectedConversation
      ?.assistantMembership
      ?.principal
      .agentId
      .trim();
  if (agentId == null || agentId.isEmpty) return false;
  for (final target in controller.targetController.targets) {
    if (target.target != agentId && target.id != agentId) continue;
    return target.conversationCapabilityMatrix['multimodal'] == true &&
        target.location == 'local' &&
        !target.hasValidVirtualMachineConnection;
  }
  return false;
}

ConversationTabActivityProjection _readTabActivity(
  ClientController controller,
) {
  final agentActivities = <ConversationAgentActivityProjection>[
    for (final entry in controller.conversationTabActivityByAgent.entries)
      ConversationAgentActivityProjection(
        agentId: entry.key,
        activity: entry.value,
      ),
  ];
  final canonical = controller.clientConversationController;
  if (canonical.selectedConversationId.isNotEmpty) {
    return ConversationTabActivityProjection(
      conversationId: canonical.selectedConversationId,
      active: true,
      unreadCount: canonical.failureCode.isEmpty ? 0 : 1,
      requiresAttention: canonical.failureCode.isNotEmpty,
      agentActivities: agentActivities,
    );
  }
  final agentId = controller.selectedConversationAgentId;
  final activity = controller.conversationTabActivityFor(agentId);
  return ConversationTabActivityProjection(
    conversationId: controller.conversationComposerScopeKey,
    active: agentId.isNotEmpty,
    unreadCount: activity == AgentConversationTabActivity.none ? 0 : 1,
    requiresAttention: activity == AgentConversationTabActivity.needsApproval,
    agentActivities: agentActivities,
  );
}

ConversationNotificationsProjection _readNotifications(
  ClientController controller,
) => ConversationNotificationsProjection(
  notices: [
    for (final item in controller.messagingNotificationCenter.items)
      PresentationNotice(
        id: item.id,
        title: 'Conversation',
        message: item.messageEnglish,
        severity: switch (item.tone) {
          MessagingNotificationTone.info =>
            PresentationNoticeSeverity.information,
          MessagingNotificationTone.warning =>
            PresentationNoticeSeverity.warning,
          MessagingNotificationTone.failure => PresentationNoticeSeverity.error,
          MessagingNotificationTone.success =>
            PresentationNoticeSeverity.success,
        },
        reasonCode: item.code,
      ),
  ],
);

ConversationArchiveProjection _readArchive(ClientController controller) {
  final owner = controller.clientConversationController;
  final sourceAgentIds = <String>{
    '',
    for (final target in controller.targetController.targets) target.id,
    for (final target in controller.targetController.targets) target.target,
  };
  return ConversationArchiveProjection(
    conversations: [
      for (final conversation in owner.archivedConversations)
        ArchivedConversationItemProjection(
          id: conversation.id,
          title: conversation.title,
          destinationLabel: conversation.group ? 'Group' : 'Conversation',
        ),
    ],
    phase: owner.loading ? PresentationPhase.loading : PresentationPhase.ready,
    queryDraft: controller.archiveQueryDraft,
    backupInProgress: controller.isCollectingConversationArchive,
    backupDestinations: [
      for (final sourceAgentId in sourceAgentIds)
        ConversationArchiveDestinationProjection(
          sourceAgentId: sourceAgentId,
          allDestination: controller.conversationArchiveDestinationFor(
            selectionMode: 'all',
            sourceAgentId: sourceAgentId,
          ),
          exactKeywordDestination: controller.conversationArchiveDestinationFor(
            selectionMode: 'exact-keyword',
            sourceAgentId: sourceAgentId,
          ),
        ),
    ],
  );
}

bool _nativeSessionIsRunning(
  ClientController controller,
  AgentConversationSession session,
) {
  if (session.running) return true;
  if (!controller.isSendingConversationMessage) return false;
  final nativeSessionId = session.nativeSessionId.trim();
  final selectedSessionId = controller.selectedConversationSession?.id ?? '';
  return (controller.sendingConversationSessionId.isNotEmpty &&
          session.id == controller.sendingConversationSessionId) ||
      (controller.sendingConversationNativeSessionId.isNotEmpty &&
          nativeSessionId == controller.sendingConversationNativeSessionId) ||
      (controller.sendingConversationSessionId.isEmpty &&
          controller.sendingConversationNativeSessionId.isEmpty &&
          session.id == selectedSessionId);
}

ConversationPartKind _canonicalPartKind(ConversationEventPartKind kind) =>
    switch (kind) {
      ConversationEventPartKind.text => ConversationPartKind.text,
      ConversationEventPartKind.reasoning => ConversationPartKind.reasoning,
      ConversationEventPartKind.toolCall ||
      ConversationEventPartKind.toolResult => ConversationPartKind.tool,
      ConversationEventPartKind.artifact ||
      ConversationEventPartKind.image => ConversationPartKind.artifact,
      ConversationEventPartKind.diagnostic => ConversationPartKind.diagnostic,
      ConversationEventPartKind.metadata ||
      ConversationEventPartKind.unknown => ConversationPartKind.metadata,
    };

ConversationPartKind _nativePartKind(AgentConversationMessageKind kind) =>
    switch (kind) {
      AgentConversationMessageKind.user ||
      AgentConversationMessageKind.assistant => ConversationPartKind.text,
      AgentConversationMessageKind.reasoning => ConversationPartKind.reasoning,
      AgentConversationMessageKind.toolCall ||
      AgentConversationMessageKind.toolResult => ConversationPartKind.tool,
      AgentConversationMessageKind.error => ConversationPartKind.diagnostic,
      AgentConversationMessageKind.subagent => ConversationPartKind.artifact,
      AgentConversationMessageKind.metadata ||
      AgentConversationMessageKind.event => ConversationPartKind.metadata,
    };

PersistentTurnPhase _turnPhase(
  ConversationTurnState phase,
  String failureCode,
) => switch (phase) {
  ConversationTurnState.pending ||
  ConversationTurnState.claimed ||
  ConversationTurnState.running => PersistentTurnPhase.running,
  ConversationTurnState.waitingForHuman => PersistentTurnPhase.waiting,
  ConversationTurnState.succeeded => PersistentTurnPhase.completed,
  ConversationTurnState.failed ||
  ConversationTurnState.interrupted ||
  ConversationTurnState.cancelled => PersistentTurnPhase.failed,
  ConversationTurnState.unknown =>
    failureCode.trim().isEmpty
        ? PersistentTurnPhase.idle
        : PersistentTurnPhase.failed,
};

bool _eventIsTerminal(AgentDispatchEvent event) {
  final terminal = event.payload['terminalTransition'];
  if (terminal is Map && (terminal['kind'] ?? '').toString().isNotEmpty) {
    return true;
  }
  return const {
    'dispatch.turn.completed',
    'dispatch.turn.failed',
    'permission.denied',
  }.contains(event.kind);
}

PresentationNotice _notice(String id, String code) => PresentationNotice(
  id: id,
  title: 'Conversation',
  message: code,
  severity: PresentationNoticeSeverity.error,
  reasonCode: code,
);

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
