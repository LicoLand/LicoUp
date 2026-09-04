import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Test-only semantic bridge for the pre-boundary Canonical Conversation
/// scenarios. Production renderers still receive only immutable bindings.
final class CanonicalGroupBindingFixture {
  CanonicalGroupBindingFixture({
    required this.controller,
    required this.targets,
    PersistentAgentConversationGateway? persistentGateway,
    this.onPickComposerImages,
    this.onClearComposerImages,
    this.onCopyText,
    this.assistantSupportsImageAttachments = false,
    this.composerAttachments = const <ConversationAttachment>[],
  }) : _persistentGateway = persistentGateway {
    _controllerRendererState = _readControllerRendererState();
    _subscriptions = [
      controller.changes.listen(_handleControllerChange),
      _turnStates.changes.listen((_) => _publish()),
    ];
    unawaited(_synchronizeTurns());
  }

  final ClientConversationController controller;
  List<TargetCandidate> targets;
  PersistentAgentConversationGateway? _persistentGateway;
  VoidCallback? onPickComposerImages;
  VoidCallback? onClearComposerImages;
  Future<void> Function(String)? onCopyText;
  bool assistantSupportsImageAttachments;
  List<ConversationAttachment> composerAttachments;
  String assistantModel = '';
  String assistantReasoningEffort = '';
  List<AdaptiveFlywheelAssignmentProjection> strategyProfiles = const [];

  final _ConversationEffectBus _effects = _ConversationEffectBus();
  final ConversationStateHolder _turnStates = ConversationStateHolder();
  final StreamController<bool> _changes = StreamController<bool>.broadcast(
    sync: true,
  );
  final Map<String, _FixtureTurn> _turns = {};
  final Map<String, StreamSubscription<AgentDispatchEvent>> _turnSubscriptions =
      {};
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  bool _syncingTurns = false;
  bool _turnSyncRequested = false;
  bool _publishing = false;
  bool _publishScheduled = false;
  bool _scheduledRendererInvalidation = false;
  bool _closed = false;
  late Object _controllerRendererState;

  Stream<bool> get changes => _changes.stream;
  int controllerChangeRevision = 0;

  PersistentAgentConversationGateway? get persistentGateway =>
      _persistentGateway;

  set persistentGateway(PersistentAgentConversationGateway? value) {
    if (identical(value, _persistentGateway)) return;
    _persistentGateway = value;
    unawaited(_replacePersistentGateway());
  }

  AgentsBinding get agents => AgentsBinding(
    projection: _ProjectionSource<AgentsProjection>(_agentsProjection),
    intents: const _IgnoredAgentsIntents(),
    effects: const _EmptyEffects<AgentsEffect>(),
  );

  ConversationBinding get conversation => ConversationBinding(
    projection: _ProjectionSource<ConversationProjection>(_rootProjection),
    nativeCatalog: _ProjectionSource<NativeConversationCatalogProjection>(
      NativeConversationCatalogProjection(
        sessions: const [],
        hasMore: false,
        phase: PresentationPhase.ready,
      ),
    ),
    canonicalEvents: _ProjectionSource<CanonicalConversationProjection>(
      canonical,
    ),
    persistentTurns: _ProjectionSource<PersistentTurnProjection>(turns),
    composer: _ProjectionSource<ComposerProjection>(composer),
    attachments: _ProjectionSource<ConversationAttachmentsProjection>(
      attachments,
    ),
    tabActivity: _ProjectionSource<ConversationTabActivityProjection>(
      ConversationTabActivityProjection(
        conversationId: controller.selectedConversationId,
        active: controller.selectedConversationId.isNotEmpty,
        unreadCount: controller.failureCode.isEmpty ? 0 : 1,
        requiresAttention: controller.failureCode.isNotEmpty,
      ),
    ),
    notifications: _ProjectionSource<ConversationNotificationsProjection>(
      ConversationNotificationsProjection(notices: const []),
    ),
    archive: _ProjectionSource<ConversationArchiveProjection>(
      ConversationArchiveProjection(
        conversations: [
          for (final item in controller.archivedConversations)
            ArchivedConversationItemProjection(
              id: item.id,
              title: item.title,
              destinationLabel: item.group ? 'Group' : 'Conversation',
            ),
        ],
        phase: controller.loading
            ? PresentationPhase.loading
            : PresentationPhase.ready,
      ),
    ),
    intents: _ConversationIntents(this),
    effects: _effects,
  );

  AgentsProjection get _agentsProjection {
    final selectedAgentId =
        controller
            .selectedConversation
            ?.assistantMembership
            ?.principal
            .agentId ??
        (targets.isEmpty ? '' : targets.first.target);
    return AgentsProjection(
      targets: [
        for (final target in targets)
          AgentTargetProjection(
            id: target.target,
            displayName: target.label,
            available: target.isConversationAgent,
            pinned: false,
            capabilityLabel: target.adapterStatus,
          ),
      ],
      selectedAgentId: selectedAgentId,
      workingDirectoryLabel: '',
      phase: PresentationPhase.ready,
      targetDetails: targets,
      adaptiveFlywheel: AdaptiveFlywheelProjection(
        definitions: const [],
        selectedRevision:
            controller.selectedConversation?.strategyRevision ?? '',
        inspection: strategyProfiles.isEmpty
            ? null
            : AdaptiveFlywheelInspectionProjection(
                status: 'active',
                currentStates: const [],
                neighborStates: const [],
                allowedOperations: const ['strategy.run.start'],
                assignments: strategyProfiles,
                slots: const [],
                states: const [],
                edges: const [],
                initialState: '',
                diagnosticCode: '',
              ),
        callableAgents: const [],
        assistant: AdaptiveFlywheelAssistantProjection(
          conversationId: controller.selectedConversationId,
          membershipId:
              controller.selectedConversation?.assistantMembershipId ?? '',
          agentId: selectedAgentId,
          modelId: assistantModel,
          reasoningEffort: assistantReasoningEffort,
          profileRevision: 0,
          loading: false,
          saving: false,
        ),
        busy: false,
        error: '',
      ),
    );
  }

  ConversationProjection get _rootProjection => ConversationProjection(
    authority: ConversationAuthority.canonicalConversation,
    conversationId: controller.selectedConversationId,
    membershipId: controller.selectedConversation?.assistantMembershipId ?? '',
  );

  CanonicalConversationProjection get canonical {
    final selected = controller.selectedConversation;
    final memberships = <String, ClientConversationMembership>{
      for (final membership in selected?.memberships ?? const [])
        membership.id: membership,
    };
    return CanonicalConversationProjection(
      conversationId: controller.selectedConversationId,
      conversation: selected,
      canonicalEvents: controller.events,
      recentParticipantAgentIds: controller.recentParticipantAgentIds,
      events: [
        for (final event in controller.events)
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
                  kind: _partKind(part.kind),
                  content: part.content,
                  collapsed: part.kind != ConversationEventPartKind.text,
                ),
            ],
            finalized: event.finalized,
            sendStateLabel: event.finalized ? 'finalized' : 'streaming',
          ),
      ],
      hasEarlier:
          selected != null && selected.eventCount > controller.events.length,
      assistantModel: assistantModel,
      assistantReasoningEffort: assistantReasoningEffort,
      failureStage: controller.failureStage,
      failureRef: controller.failureRef,
      failureRecovery: controller.failureRecovery,
      failureCopyBlob: controller.failureCopyBlob,
      phase: controller.loading
          ? PresentationPhase.loading
          : controller.failureCode.isNotEmpty
          ? PresentationPhase.failed
          : PresentationPhase.ready,
      dispatchPending: controller.dispatchPending,
      notice: controller.failureCode.isEmpty
          ? null
          : PresentationNotice(
              id: 'canonical-conversation',
              title: 'Conversation',
              message: controller.failureCode,
              severity: PresentationNoticeSeverity.error,
              reasonCode: controller.failureCode,
              reference: controller.failureRef,
              recovery: controller.failureRecovery,
              copyText: controller.failureCopyBlob,
            ),
    );
  }

  PersistentTurnProjection get turns => PersistentTurnProjection(
    conversationId: controller.selectedConversationId,
    memberships: [
      for (final turn in _turns.values)
        if (turn.conversationId == controller.selectedConversationId)
          _turnProjection(turn),
    ],
  );

  ComposerProjection get composer {
    final conversationId = controller.selectedConversationId;
    return ComposerProjection(
      conversationId: conversationId.isEmpty ? '' : 'group:$conversationId',
      draft: controller.draft,
      inputEnabled:
          controller.selectedConversation?.localOwnerMembership != null &&
          !controller.sending,
      sendLabel: controller.dispatchPending ? 'Steer' : 'Send',
    );
  }

  ConversationAttachmentsProjection get attachments {
    final conversationId = controller.selectedConversationId;
    return ConversationAttachmentsProjection(
      conversationId: conversationId.isEmpty ? '' : 'group:$conversationId',
      attachments: [
        for (final attachment in composerAttachments)
          ConversationAttachmentProjection(
            id: attachment.id,
            displayName: attachment.name,
            mediaKind: attachment.mediaType,
            localPath: attachment.path,
            stateLabel: 'ready',
          ),
      ],
      acceptsImages: assistantSupportsImageAttachments,
    );
  }

  String _agentLabel(String agentId) {
    for (final target in targets) {
      if (target.target == agentId || target.id == agentId) return target.label;
    }
    return agentId;
  }

  String _participantRole(String membershipId) =>
      controller.selectedConversation?.assistantMembershipId == membershipId
      ? 'assistant'
      : 'member';

  void _handleControllerChange(ApplicationChange _) {
    if (_closed) return;
    controllerChangeRevision += 1;
    final nextRendererState = _readControllerRendererState();
    final invalidatesRenderer = nextRendererState != _controllerRendererState;
    _controllerRendererState = nextRendererState;
    _publish(invalidatesRenderer: invalidatesRenderer);
    unawaited(_synchronizeTurns());
  }

  Object _readControllerRendererState() => (
    controller.selectedConversationId,
    controller.selectedConversation,
    controller.events,
    controller.recentParticipantAgentIds,
    controller.archivedConversations,
    controller.loading,
    controller.sending,
    controller.failureStage,
    controller.failureCode,
    controller.failureComponent,
    controller.failureRetryable,
    controller.failureRecovery,
    controller.failureRef,
    controller.liveTurns,
    controller.dispatchPending,
  );

  void _publish({bool invalidatesRenderer = true}) {
    if (_closed) return;
    if (_publishing) {
      _schedulePublish(invalidatesRenderer: invalidatesRenderer);
      return;
    }
    _publishing = true;
    try {
      _changes.add(invalidatesRenderer);
    } finally {
      _publishing = false;
    }
  }

  void _schedulePublish({bool invalidatesRenderer = true}) {
    if (_closed) return;
    _scheduledRendererInvalidation |= invalidatesRenderer;
    if (_publishScheduled) return;
    _publishScheduled = true;
    scheduleMicrotask(() {
      final shouldInvalidateRenderer = _scheduledRendererInvalidation;
      _publishScheduled = false;
      _scheduledRendererInvalidation = false;
      _publish(invalidatesRenderer: shouldInvalidateRenderer);
    });
  }

  Future<void> _replacePersistentGateway() async {
    await _detachAllTurns();
    if (!_closed) await _synchronizeTurns();
  }

  Future<void> _synchronizeTurns() async {
    if (_closed) return;
    if (_syncingTurns) {
      _turnSyncRequested = true;
      return;
    }
    _syncingTurns = true;
    try {
      do {
        _turnSyncRequested = false;
        await _synchronizeTurnsOnce();
      } while (_turnSyncRequested && !_closed);
    } finally {
      _syncingTurns = false;
    }
  }

  Future<void> _synchronizeTurnsOnce() async {
    final conversationId = controller.selectedConversationId.trim();
    final gateway = _persistentGateway;
    if (conversationId.isEmpty || gateway == null) {
      await _detachAllTurns();
      return;
    }
    if (_turns.values.any((turn) => turn.conversationId != conversationId)) {
      await _detachAllTurns();
    }
    List<Map<String, dynamic>> discovered = const [];
    try {
      discovered = await gateway.activeTurns(
        agentId: '',
        conversationId: conversationId,
      );
    } on Object {
      // Observer discovery failure is a detach condition, not a turn failure.
    }
    if (_closed || controller.selectedConversationId.trim() != conversationId) {
      return;
    }
    final byHandle = <String, Map<String, dynamic>>{};
    for (final raw in <Map<String, dynamic>>[
      ...controller.liveTurns,
      ...discovered,
    ]) {
      final handle = (raw['turnHandle'] ?? '').toString().trim();
      if (handle.isNotEmpty) byHandle[handle] = raw;
    }
    var attachedTurn = false;
    for (final entry in byHandle.entries) {
      if (_turnSubscriptions.containsKey(entry.key)) continue;
      final retained = _turns[entry.key];
      if (retained?.settling == true) continue;
      final turn =
          retained ?? _resolveTurn(conversationId, entry.key, entry.value);
      if (turn == null) continue;
      _turns[entry.key] = turn;
      _attachTurn(gateway, turn);
      attachedTurn = true;
    }
    if (attachedTurn) _publish();
  }

  _FixtureTurn? _resolveTurn(
    String conversationId,
    String handle,
    Map<String, dynamic> raw,
  ) {
    final membershipId = (raw['membershipId'] ?? '').toString().trim();
    final projectedAgent = (raw['agent'] ?? raw['agentId'] ?? '')
        .toString()
        .trim();
    final conversation = controller.selectedConversation;
    if (conversation == null || membershipId.isEmpty) return null;
    for (final membership in conversation.activeAgentMemberships) {
      if (membership.id != membershipId) continue;
      final agentId = membership.principal.agentId.trim();
      if (agentId.isEmpty ||
          (projectedAgent.isNotEmpty && projectedAgent != agentId)) {
        return null;
      }
      final label = membership.principal.displayName.trim();
      return _FixtureTurn(
        handle: handle,
        conversationId: conversationId,
        membershipId: membershipId,
        agentId: agentId,
        label: label.isEmpty ? _agentLabel(agentId) : label,
        role: _participantRole(membershipId),
      );
    }
    return null;
  }

  void _attachTurn(
    PersistentAgentConversationGateway gateway,
    _FixtureTurn turn,
  ) {
    turn.observing = true;
    _turnSubscriptions[turn.handle] = gateway
        .attachActiveTurn(
          turnHandle: turn.handle,
          conversationId: turn.conversationId,
          afterCursor: turn.cursor,
        )
        .listen(
          (event) {
            if (_closed ||
                controller.selectedConversationId.trim() !=
                    turn.conversationId) {
              return;
            }
            final cursor = event.payload['cursor'];
            if (cursor is int && cursor > turn.cursor) turn.cursor = cursor;
            _turnStates.applyDelta(
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
            if (persistentTurnEventIsTerminal(event)) {
              unawaited(_finishTurn(turn.handle));
            }
          },
          onDone: () => unawaited(_finishTurn(turn.handle)),
          onError: (Object _) => unawaited(_recoverObserver(turn.handle)),
          cancelOnError: false,
        );
  }

  Future<void> _finishTurn(String handle) async {
    final turn = _turns[handle];
    if (turn == null || turn.settling) return;
    turn
      ..settling = true
      ..observing = false;
    final subscription = _turnSubscriptions.remove(handle);
    unawaited(subscription?.cancel());
    final durable = await _reloadSelectedForHandoff(turn);
    if (_closed) return;
    final selected =
        controller.selectedConversationId.trim() == turn.conversationId;
    if (selected && durable) {
      _surfacePersistedFailure(turn);
      _removeTurn(turn);
    } else {
      turn.settling = false;
    }
    if (_turnSubscriptions.isEmpty) controller.settleLiveDispatch();
    _publish();
  }

  Future<bool> _reloadSelectedForHandoff(_FixtureTurn turn) async {
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
    ];
    for (final delay in retryDelays) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_closed ||
          controller.selectedConversationId.trim() != turn.conversationId) {
        return false;
      }
      if (await controller.reloadSelected() && _durablySettled(turn)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _recoverObserver(String handle) async {
    final turn = _turns[handle];
    if (turn == null || turn.settling) return;
    turn
      ..settling = true
      ..observing = false;
    final subscription = _turnSubscriptions.remove(handle);
    unawaited(subscription?.cancel());
    final reloaded = await controller.reloadSelected();
    if (_closed) return;
    if (controller.selectedConversationId.trim() != turn.conversationId) {
      _removeTurn(turn);
    } else if (reloaded && _durablySettled(turn)) {
      _surfacePersistedFailure(turn);
      _removeTurn(turn);
    } else {
      Map<String, dynamic>? active;
      try {
        final discovered = await _persistentGateway?.activeTurns(
          agentId: '',
          conversationId: turn.conversationId,
        );
        if (discovered != null) {
          for (final raw in discovered) {
            if ((raw['turnHandle'] ?? '').toString().trim() == handle) {
              active = raw;
              break;
            }
          }
        }
      } on Object {
        active = null;
      }
      if (!_closed &&
          controller.selectedConversationId.trim() == turn.conversationId &&
          active != null &&
          _persistentGateway != null) {
        turn.settling = false;
        _attachTurn(_persistentGateway!, turn);
      } else {
        _removeTurn(turn);
      }
    }
    if (_turnSubscriptions.isEmpty) controller.settleLiveDispatch();
    _publish();
  }

  bool _durablySettled(_FixtureTurn turn) => controller.events.any(
    (event) => event.finalized && event.correlationId.trim() == turn.handle,
  );

  void _surfacePersistedFailure(_FixtureTurn turn) {
    for (final event in controller.events.reversed) {
      if (!event.finalized || event.correlationId.trim() != turn.handle) {
        continue;
      }
      for (final part in event.parts.reversed) {
        if (part.kind != ConversationEventPartKind.diagnostic) continue;
        final failure = persistentTurnDiagnosticFailure(part.content);
        if (failure == null) continue;
        controller.surfaceFailure(
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

  MembershipTurnProjection _turnProjection(_FixtureTurn turn) {
    final state = _turnStates.projectionFor(turn.scopeKey);
    var phase = _fixtureTurnPhase(
      state.turnState.phase,
      controller.failureCode,
    );
    if (phase == PersistentTurnPhase.idle && turn.observing) {
      phase = PersistentTurnPhase.running;
    }
    return MembershipTurnProjection(
      membershipId: turn.membershipId,
      agentLabel: turn.label,
      phase: phase,
      inputEnabled:
          state.turnState.inputEnabled ?? phase != PersistentTurnPhase.waiting,
      liveParts: _fixtureMessageParts(state.messages),
      messages: state.messages,
      turnHandle: turn.handle,
      participantAgentId: turn.agentId,
      participantRole: turn.role,
      cancelEnabled:
          state.turnState.cancelEnabled ??
          state.turnState.active || turn.observing,
      failureReasonCode: phase == PersistentTurnPhase.failed
          ? controller.failureCode
          : '',
    );
  }

  _FixtureTurn? _turnForMembership(String membershipId) {
    final matches = _turns.values.where(
      (turn) => turn.membershipId == membershipId && !turn.settling,
    );
    return matches.length == 1 ? matches.single : null;
  }

  void _removeTurn(_FixtureTurn turn) {
    _turns.remove(turn.handle);
    _turnStates.removeScope(turn.scopeKey);
  }

  Future<void> _detachAllTurns() async {
    final hadTurns = _turns.isNotEmpty || _turnSubscriptions.isNotEmpty;
    final subscriptions = _turnSubscriptions.values.toList(growable: false);
    _turnSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    for (final turn in _turns.values) {
      _turnStates.removeScope(turn.scopeKey);
    }
    _turns.clear();
    if (hadTurns) _publish();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await _detachAllTurns();
    _turnStates.dispose();
    if (!_changes.hasListener) _changes.stream.listen(null);
    await _changes.close();
    await _effects.close();
  }
}

/// Drop-in test harness with the retired renderer arguments, translated into
/// the current semantic surface before the production widget is constructed.
class CanonicalGroupConversationPaneFixture extends StatefulWidget {
  const CanonicalGroupConversationPaneFixture({
    super.key,
    required this.controller,
    required this.targets,
    required this.onCopyText,
    this.onOpenAgentConversations,
    this.framed = true,
    this.flywheelGateway,
    this.persistentGateway,
    this.onOpenAdaptiveFlywheel,
    this.composerAttachments = const <ConversationAttachment>[],
    this.onPickComposerImages,
    this.onClearComposerImages,
    this.assistantSupportsImageAttachments = false,
  });

  final ClientConversationController controller;
  final List<TargetCandidate> targets;
  final Future<void> Function(String) onCopyText;
  final ValueChanged<String>? onOpenAgentConversations;
  final bool framed;
  final AdaptiveFlywheelGateway? flywheelGateway;
  final PersistentAgentConversationGateway? persistentGateway;
  final Future<void> Function(String? revisionDigest)? onOpenAdaptiveFlywheel;
  final List<ConversationAttachment> composerAttachments;
  final VoidCallback? onPickComposerImages;
  final VoidCallback? onClearComposerImages;
  final bool assistantSupportsImageAttachments;

  @override
  State<CanonicalGroupConversationPaneFixture> createState() =>
      _CanonicalGroupConversationPaneFixtureState();
}

class _CanonicalGroupConversationPaneFixtureState
    extends State<CanonicalGroupConversationPaneFixture> {
  late CanonicalGroupBindingFixture _fixture;
  late StreamSubscription<bool> _changes;
  String _profileMembershipId = '';
  String _strategyConversationId = '';
  String _strategyRevision = '';
  int _strategyGeneration = 0;
  int _observedControllerChangeRevision = 0;
  bool _strategySyncing = false;
  bool _strategySyncRequested = false;

  @override
  void initState() {
    super.initState();
    _fixture = _newFixture();
    _changes = _listenForChanges();
    unawaited(_reloadAssistantProfile());
    unawaited(_synchronizeStrategyProjection());
  }

  StreamSubscription<bool> _listenForChanges() =>
      _fixture.changes.listen((invalidatesRenderer) {
        if (invalidatesRenderer && mounted) setState(() {});
        unawaited(_reloadAssistantProfile());
        if (_observedControllerChangeRevision !=
            _fixture.controllerChangeRevision) {
          _observedControllerChangeRevision = _fixture.controllerChangeRevision;
          unawaited(_synchronizeStrategyProjection());
        }
      });

  CanonicalGroupBindingFixture _newFixture() => CanonicalGroupBindingFixture(
    controller: widget.controller,
    targets: widget.targets,
    persistentGateway: widget.persistentGateway,
    onPickComposerImages: widget.onPickComposerImages,
    onClearComposerImages: widget.onClearComposerImages,
    onCopyText: widget.onCopyText,
    assistantSupportsImageAttachments: widget.assistantSupportsImageAttachments,
    composerAttachments: widget.composerAttachments,
  );

  @override
  void didUpdateWidget(
    covariant CanonicalGroupConversationPaneFixture oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      unawaited(_changes.cancel());
      unawaited(_fixture.close());
      _fixture = _newFixture();
      _changes = _listenForChanges();
      _profileMembershipId = '';
      _strategyConversationId = '';
      _strategyRevision = '';
      _observedControllerChangeRevision = _fixture.controllerChangeRevision;
      unawaited(_reloadAssistantProfile());
      unawaited(_synchronizeStrategyProjection());
      return;
    }
    _fixture
      ..targets = widget.targets
      ..persistentGateway = widget.persistentGateway
      ..onPickComposerImages = widget.onPickComposerImages
      ..onClearComposerImages = widget.onClearComposerImages
      ..onCopyText = widget.onCopyText
      ..assistantSupportsImageAttachments =
          widget.assistantSupportsImageAttachments
      ..composerAttachments = widget.composerAttachments;
    if (!identical(oldWidget.flywheelGateway, widget.flywheelGateway)) {
      _strategyConversationId = '';
      _strategyRevision = '';
      unawaited(_synchronizeStrategyProjection(force: true));
    }
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    unawaited(_fixture.close());
    super.dispose();
  }

  Future<void> _reloadAssistantProfile({bool force = false}) async {
    final membershipId =
        widget.controller.selectedConversation?.assistantMembershipId.trim() ??
        '';
    if (!force && membershipId == _profileMembershipId) return;
    _profileMembershipId = membershipId;
    Map<String, dynamic> profile = const <String, dynamic>{};
    if (membershipId.isNotEmpty) {
      try {
        profile =
            await widget.controller.membershipProfile(membershipId) ??
            const <String, dynamic>{};
      } on Object {
        profile = const <String, dynamic>{};
      }
    }
    if (!mounted || membershipId != _profileMembershipId) return;
    setState(() {
      _fixture.assistantModel = (profile['preferredModel'] ?? '').toString();
      _fixture.assistantReasoningEffort =
          (profile['preferredReasoningEffort'] ?? '').toString();
    });
  }

  Future<void> _synchronizeStrategyProjection({bool force = false}) async {
    if (_strategySyncing) {
      _strategySyncRequested = true;
      return;
    }
    _strategySyncing = true;
    try {
      var forceNext = force;
      do {
        _strategySyncRequested = false;
        final attemptedConversationId =
            widget.controller.selectedConversationId;
        final attemptedRevision =
            widget.controller.selectedConversation?.strategyRevision ?? '';
        final attemptedGateway = widget.flywheelGateway;
        await _synchronizeStrategyProjectionOnce(force: forceNext);
        forceNext = false;
        if (!_strategySyncRequested || !mounted) break;
        final currentConversationId = widget.controller.selectedConversationId;
        final currentRevision =
            widget.controller.selectedConversation?.strategyRevision ?? '';
        if (currentConversationId == attemptedConversationId &&
            currentRevision == attemptedRevision &&
            identical(widget.flywheelGateway, attemptedGateway)) {
          break;
        }
      } while (mounted);
    } finally {
      _strategySyncing = false;
    }
  }

  Future<void> _synchronizeStrategyProjectionOnce({bool force = false}) async {
    final conversation = widget.controller.selectedConversation;
    final conversationId = conversation?.id.trim() ?? '';
    final revision = conversation?.strategyRevision.trim() ?? '';
    if (!force &&
        conversationId == _strategyConversationId &&
        revision == _strategyRevision) {
      return;
    }
    final generation = ++_strategyGeneration;
    final gateway = widget.flywheelGateway;
    if (gateway == null ||
        conversation == null ||
        !conversation.group ||
        revision.isEmpty) {
      _strategyConversationId = conversationId;
      _strategyRevision = revision;
      if (_fixture.strategyProfiles.isNotEmpty) {
        _fixture.strategyProfiles = const [];
        _fixture._schedulePublish();
      }
      return;
    }
    try {
      final definitions = adaptiveFlywheelMaps(
        await gateway.execute({'action': 'strategy.definition.list'}),
      ).map(AdaptiveFlywheelDefinition.fromJson);
      if (!definitions.any(
        (definition) =>
            definition.authorized && definition.revisionDigest == revision,
      )) {
        _strategyConversationId = conversationId;
        _strategyRevision = revision;
        return;
      }
      final inspection = AdaptiveFlywheelInspection.fromJson(
        adaptiveFlywheelStringMap(
          await gateway.execute({
            'action': 'strategy.definition.inspect',
            'revisionDigest': revision,
          }),
        ),
      );
      if (!mounted ||
          generation != _strategyGeneration ||
          widget.controller.selectedConversationId != conversationId ||
          !inspection.authorized) {
        return;
      }
      _strategyConversationId = conversationId;
      _strategyRevision = revision;
      _fixture.strategyProfiles =
          List<AdaptiveFlywheelAssignmentProjection>.unmodifiable([
            for (final slot in inspection.slots.where(
              (slot) => slot.kind == 'actor',
            ))
              for (final binding in inspection.bindings[slot.id] ?? const [])
                if (binding.valueId.trim().isNotEmpty)
                  AdaptiveFlywheelAssignmentProjection(
                    slotId: binding.slotId,
                    ordinal: binding.ordinal,
                    agentId: binding.valueId.trim(),
                    modelId: binding.model.trim(),
                    reasoningEffort: binding.reasoningEffort.trim(),
                    revision: binding.revision,
                  ),
          ]);
      _fixture._schedulePublish();
    } on Object {
      // Keep the persisted revision visible and retry on the next semantic
      // change. A transient inspection failure is not durable state.
    }
  }

  @override
  Widget build(BuildContext context) => CanonicalGroupConversationPane(
    conversation: _fixture.conversation,
    agents: _fixture.agents,
    canonical: _fixture.canonical,
    turns: _fixture.turns,
    composer: _fixture.composer,
    attachments: _fixture.attachments,
    onOpenAgentConversations: widget.onOpenAgentConversations,
    onOpenAdaptiveFlywheel: (revision) async {
      await widget.onOpenAdaptiveFlywheel?.call(revision);
      await _reloadAssistantProfile(force: true);
    },
    onPickComposerImages: widget.onPickComposerImages,
    onClearComposerImages: widget.onClearComposerImages,
    framed: widget.framed,
  );
}

final class _ConversationIntents implements IntentSink<ConversationIntent> {
  const _ConversationIntents(this.fixture);

  final CanonicalGroupBindingFixture fixture;

  @override
  void send(ConversationIntent intent) {
    final controller = fixture.controller;
    switch (intent) {
      case RefreshConversationCatalog():
        unawaited(controller.refresh());
      case LoadMoreConversationSessions():
        break;
      case SelectConversationSession(:final sessionId) ||
          SelectCanonicalConversation(conversationId: final sessionId):
        unawaited(controller.selectConversation(sessionId));
      case ClearCanonicalConversationSelection():
        controller.clearSelection();
      case CreateCanonicalConversationGroup(:final title, :final members):
        unawaited(_createGroup(title, members, intent));
      case StartConversationSession():
        controller.clearSelection();
      case LoadEarlierConversationEvents():
        unawaited(controller.reloadSelected());
      case PostConversationMessage(:final content, :final dispatchCanonical):
        unawaited(_post(content, dispatchCanonical, intent));
      case UpdateConversationDraft(:final draft):
        controller.updateDraft(draft);
      case AddConversationAttachment():
        fixture.onPickComposerImages?.call();
      case PasteConversationAttachment():
        fixture.onPickComposerImages?.call();
      case StageConversationAttachments(attachments: final attachments) ||
          ReplaceConversationAttachments(attachments: final attachments):
        fixture.composerAttachments = attachments;
      case SetConversationAttachmentStatus():
        break;
      case ClearConversationAttachments():
        fixture.composerAttachments = const [];
        fixture.onClearComposerImages?.call();
      case SelectConversationModel():
        break;
      case SelectConversationReasoningEffort():
        break;
      case SelectConversationLicoProfile():
        break;
      case RetryConversationPermission():
        break;
      case DismissConversationPermission():
        break;
      case AuthorizeConversationRuntime():
        break;
      case CopyConversationFailure():
        break;
      case CopyConversationText(:final text):
        unawaited(fixture.onCopyText?.call(text));
      case RemoveConversationAttachment(:final attachmentId):
        fixture.composerAttachments = fixture.composerAttachments
            .where((item) => item.id != attachmentId)
            .toList(growable: false);
      case RetryConversationDispatch(:final membershipId) ||
          RetryCanonicalConversationMessage(eventId: final membershipId):
        unawaited(controller.retryMessage(membershipId));
      case DismissConversationFailure():
        break;
      case InterruptConversationTurn(:final membershipId):
        unawaited(_cancel(membershipId));
      case DeleteCanonicalConversationMessage(:final eventId):
        unawaited(controller.deleteMessage(eventId));
      case RefreshCanonicalAssistantThread():
        unawaited(controller.refreshSelectedAssistantThread());
      case RefreshCanonicalAssistantProfile():
        break;
      case SurfaceConversationFailure(:final stage, :final reasonCode):
        controller.surfaceFailure(stage, reasonCode);
      case EnsureCanonicalAgentMembership(:final agentId, :final displayName):
        unawaited(
          controller.ensureSelectedAgentMembership(
            agentId: agentId,
            displayName: displayName,
          ),
        );
      case SetCanonicalAssistantMembership(:final membershipId):
        unawaited(controller.setSelectedAssistantMembership(membershipId));
      case SetCanonicalStrategyRevision(:final revision):
        unawaited(controller.setSelectedStrategyRevision(revision));
      case SetCanonicalConversationPinned(:final conversationId, :final pinned):
        unawaited(controller.setPinned(conversationId, pinned));
      case SetCanonicalConversationSurfaceAttached():
        break;
      case SetConversationTabActive():
        break;
      case ArchiveConversation(:final conversationId):
        unawaited(controller.archiveConversation(conversationId));
      case RestoreConversation(:final conversationId):
        unawaited(controller.restoreArchived(conversationId));
      case BackupAllNativeConversations() ||
          BackupNativeConversationsByExactKeyword():
        break;
    }
  }

  Future<void> _createGroup(
    String title,
    List<ClientConversationGroupMemberDraft> members,
    ConversationIntent intent,
  ) async {
    final created = await fixture.controller.createGroup(
      title: title,
      members: members,
    );
    if (created) {
      fixture._effects.add(
        CanonicalConversationGroupCreated(
          fixture.controller.selectedConversationId,
          trace: intent.trace,
        ),
      );
      return;
    }
    fixture._effects.add(
      ConversationActionRejected(
        conversationId: fixture.controller.selectedConversationId,
        stage: 'canonical-create',
        reasonCode: fixture.controller.failureCode.isEmpty
            ? 'conversation_operation_failed'
            : fixture.controller.failureCode,
        trace: intent.trace,
      ),
    );
  }

  Future<void> _post(
    String content,
    bool dispatchCanonical,
    ConversationIntent intent,
  ) async {
    final attachments = fixture.composerAttachments;
    if (attachments.isNotEmpty && !fixture.assistantSupportsImageAttachments) {
      fixture.controller.surfaceFailure(
        'attachment',
        'attachment_transport_unsupported',
      );
      fixture._effects.add(
        ConversationActionRejected(
          conversationId: fixture.controller.selectedConversationId,
          stage: 'canonical-send',
          reasonCode: 'attachment_transport_unsupported',
          trace: intent.trace,
        ),
      );
      return;
    }
    final posted = await fixture.controller.postMessage(
      content,
      dispatch: dispatchCanonical,
      attachments: attachments,
    );
    if (posted) fixture.onClearComposerImages?.call();
  }

  Future<void> _cancel(String membershipId) async {
    final gateway = fixture.persistentGateway;
    if (gateway == null) return;
    final turn = fixture._turnForMembership(membershipId);
    if (turn == null) return;
    await gateway.cancelActiveTurn(
      turnHandle: turn.handle,
      conversationId: turn.conversationId,
    );
  }
}

final class _FixtureTurn {
  _FixtureTurn({
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
  bool observing = false;
  bool settling = false;

  String get scopeKey => 'group:$conversationId:$handle';
}

final class _ProjectionSource<T> implements ProjectionSource<T> {
  const _ProjectionSource(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

final class _ConversationEffectBus implements EffectSource<ConversationEffect> {
  final StreamController<ConversationEffect> _controller =
      StreamController<ConversationEffect>.broadcast(sync: true);

  @override
  Stream<ConversationEffect> get effects => _controller.stream;

  void add(ConversationEffect effect) => _controller.add(effect);

  Future<void> close() => _controller.close();
}

final class _EmptyEffects<T> implements EffectSource<T> {
  const _EmptyEffects();

  @override
  Stream<T> get effects => const Stream.empty();
}

final class _IgnoredAgentsIntents implements IntentSink<AgentsIntent> {
  const _IgnoredAgentsIntents();

  @override
  void send(AgentsIntent intent) {}
}

ConversationPartKind _partKind(ConversationEventPartKind kind) =>
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

PersistentTurnPhase _fixtureTurnPhase(
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

List<ConversationPartProjection> _fixtureMessageParts(
  Iterable<AgentConversationMessage> messages,
) {
  final result = <ConversationPartProjection>[];
  void append(AgentConversationMessage message) {
    result.add(
      ConversationPartProjection(
        id: message.stableIdentity.isEmpty
            ? message.id
            : message.stableIdentity,
        kind: _fixtureNativePartKind(message.kind),
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

ConversationPartKind _fixtureNativePartKind(
  AgentConversationMessageKind kind,
) => switch (kind) {
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
