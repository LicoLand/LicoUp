import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/header.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/projection.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/reveal.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/roster.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane/support.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';

class CanonicalGroupConversationPane extends StatefulWidget {
  const CanonicalGroupConversationPane({
    super.key,
    required this.controller,
    required this.targets,
    required this.onCopyText,
    this.onOpenAgentConversations,
    this.framed = true,
    this.flywheelGateway,
    this.persistentGateway,
    this.onOpenAdaptiveFlywheel,
  });

  final ClientConversationController controller;
  final List<TargetCandidate> targets;
  final Future<void> Function(String) onCopyText;
  final ValueChanged<String>? onOpenAgentConversations;
  final bool framed;
  final AdaptiveFlywheelGateway? flywheelGateway;
  final PersistentAgentConversationGateway? persistentGateway;
  final Future<void> Function(String? revisionDigest)? onOpenAdaptiveFlywheel;

  @override
  State<CanonicalGroupConversationPane> createState() =>
      _CanonicalGroupConversationPaneState();
}

class _CanonicalGroupConversationPaneState
    extends State<CanonicalGroupConversationPane> {
  bool _rosterVisible = true;
  final ScrollController _messageScrollController = ScrollController();
  List<AdaptiveFlywheelDefinition> _authorizedStrategies = const [];
  String? _strategyRevision;
  Map<String, AgentParticipantRuntimeProfile> _strategyRuntimeProfiles =
      const {};
  final Map<String, bool> _assistantActiveByConversation = {};
  String _strategyProjectionConversationId = '';
  String _strategyProjectionRevision = '';
  int _strategyProjectionGeneration = 0;
  final Map<String, StreamSubscription<AgentDispatchEvent>> _turnSubscriptions =
      {};
  final Set<String> _visibleTurnHandles = <String>{};
  final Map<String, int> _turnCursorByHandle = <String, int>{};
  final Map<String, String> _participantAgentIdByHandle = {};
  final Map<String, String> _participantRoleByHandle = {};
  final Set<String> _finishingHandles = {};
  String _attachedConversationId = '';

  /// Shared 32 ms-coalesced turn projection channel, identical to the 1:1
  /// live path: every PersistentTurn event becomes a generated
  /// [ConversationDeltaEvent] and lands in this holder, which publishes at most
  /// once per display interval. The pane renders from its projections and keeps
  /// no per-chunk projection state of its own.
  final ConversationStateHolder _turnStates = ConversationStateHolder();

  AgentConversationSession? _cachedSession;
  ClientConversation? _cachedSessionConversation;
  List<ClientConversationEvent>? _cachedSessionEvents;
  String _cachedSessionLocale = '';
  List<AgentConversationMessage>? _cachedLiveMessages;
  List<List<AgentConversationMessage>>? _cachedLiveParts;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onConversationChanged);
    _turnStates.addListener(_onTurnProjectionChanged);
    unawaited(_loadAuthorizedStrategies());
    if (widget.controller.selectedConversation != null) {
      unawaited(_ensureConversationHost());
      unawaited(_attachLiveTurns());
    }
  }

  @override
  void didUpdateWidget(covariant CanonicalGroupConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onConversationChanged);
      widget.controller.addListener(_onConversationChanged);
      unawaited(_syncStrategyFromConversation(force: true));
    }
    if (oldWidget.flywheelGateway != widget.flywheelGateway) {
      unawaited(_loadAuthorizedStrategies());
    }
    if ((oldWidget.persistentGateway != widget.persistentGateway ||
            oldWidget.controller != widget.controller) &&
        widget.controller.selectedConversation != null) {
      unawaited(_ensureConversationHost());
      unawaited(_attachLiveTurns());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onConversationChanged);
    _turnStates.removeListener(_onTurnProjectionChanged);
    _detachLiveTurns();
    _turnStates.dispose();
    _messageScrollController.dispose();
    super.dispose();
  }

  /// One holder publish per 32 ms window (or an immediate terminal publish)
  /// drives exactly one pane rebuild; streamed chunks no longer repaint at
  /// frame rate.
  void _onTurnProjectionChanged() {
    if (mounted) setState(() {});
  }

  String _scopeKeyFor(String handle) => '$_attachedConversationId\u0000$handle';

  void _onConversationChanged() {
    if (!mounted) return;
    _pruneDurablySettledLiveTurns();
    setState(() {});
    unawaited(_syncStrategyFromConversation());
    final conversationId = widget.controller.selectedConversationId;
    if (widget.controller.selectedConversation == null) {
      return;
    }
    if (conversationId != _attachedConversationId) {
      unawaited(_ensureConversationHost());
      unawaited(_attachLiveTurns());
    }
  }

  Future<void> _loadAuthorizedStrategies() async {
    final gateway = widget.flywheelGateway;
    if (gateway == null) {
      if (!mounted) return;
      setState(() {
        _authorizedStrategies = const [];
        _clearStrategyFields();
      });
      return;
    }
    try {
      final definitions =
          adaptiveFlywheelMaps(
                await gateway.execute({'action': 'strategy.definition.list'}),
              )
              .map(AdaptiveFlywheelDefinition.fromJson)
              .where((definition) {
                return definition.authorized &&
                    definition.revisionDigest.isNotEmpty;
              })
              .toList(growable: false);
      if (!mounted) return;
      setState(() => _authorizedStrategies = definitions);
      await _syncStrategyFromConversation(force: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _authorizedStrategies = const []);
    }
  }

  void _clearStrategyFields() {
    _strategyRevision = null;
    _strategyRuntimeProfiles = const {};
  }

  Future<void> _exitStrategyMode() async {
    final conversationId = widget.controller.selectedConversationId;
    final cleared = await widget.controller.setSelectedStrategyRevision(null);
    if (!mounted ||
        !cleared ||
        widget.controller.selectedConversationId != conversationId) {
      return;
    }
    _strategyProjectionConversationId = conversationId;
    _strategyProjectionRevision = '';
    _strategyProjectionGeneration += 1;
    setState(_clearStrategyFields);
  }

  Future<void> _openAdaptiveFlywheel(String? revisionDigest) async {
    final open = widget.onOpenAdaptiveFlywheel;
    if (open == null) return;
    await open(revisionDigest);
    if (!mounted) return;
    await _loadAuthorizedStrategies();
  }

  Future<void> _selectStrategy(String revisionDigest) async {
    final controller = widget.controller;
    final gateway = widget.flywheelGateway;
    final conversation = controller.selectedConversation;
    final conversationId = conversation?.id ?? '';
    if (conversationId.isEmpty || revisionDigest.isEmpty || gateway == null) {
      return;
    }
    final strategies = List<AdaptiveFlywheelDefinition>.unmodifiable(
      _authorizedStrategies,
    );
    final agentLabels = <String, String>{
      for (final target in widget.targets)
        if (target.target.trim().isNotEmpty)
          target.target: agentConversationTargetDisplayName(target),
      for (final target in widget.targets)
        if (target.id.trim().isNotEmpty)
          target.id: agentConversationTargetDisplayName(target),
      for (final membership in conversation!.activeAgentMemberships)
        if (membership.principal.agentId.trim().isNotEmpty)
          membership.principal.agentId:
              membership.principal.displayName.trim().isEmpty
              ? membership.principal.agentId
              : membership.principal.displayName,
    };

    // The user's click is the durable state transition. Persist it before
    // inspection and membership reconciliation so navigation cannot dispose
    // the pane and cancel the selection before it reaches the Conversation.
    final persisted = await controller.setSelectedStrategyRevision(
      revisionDigest,
    );
    if (!persisted) return;
    if (!mounted ||
        controller.selectedConversationId != conversationId ||
        controller.selectedConversation?.strategyRevision.trim() !=
            revisionDigest) {
      return;
    }
    _applyPersistedStrategySelection(revisionDigest);
    try {
      final projection = await _inspectStrategy(
        revisionDigest,
        gatewayOverride: gateway,
        strategiesOverride: strategies,
      );
      if (projection == null) return;
      for (final agentId in projection.agentIds) {
        if (controller.selectedConversationId != conversationId ||
            controller.selectedConversation?.strategyRevision.trim() !=
                revisionDigest) {
          return;
        }
        await controller.ensureSelectedAgentMembership(
          agentId: agentId,
          displayName: agentLabels[agentId] ?? agentId,
        );
      }
      if (!mounted ||
          controller.selectedConversationId != conversationId ||
          controller.selectedConversation?.strategyRevision.trim() !=
              revisionDigest) {
        return;
      }
      _strategyProjectionConversationId = conversationId;
      _strategyProjectionRevision = revisionDigest;
      _strategyProjectionGeneration += 1;
      _applyStrategyProjection(projection);
    } on AdaptiveFlywheelFailure {
      return;
    }
  }

  Future<void> _syncStrategyFromConversation({bool force = false}) async {
    final conversation = widget.controller.selectedConversation;
    final conversationId = conversation?.id ?? '';
    final revision = conversation?.strategyRevision.trim() ?? '';
    if (!force &&
        conversationId == _strategyProjectionConversationId &&
        revision == _strategyProjectionRevision) {
      return;
    }
    final generation = ++_strategyProjectionGeneration;
    if (conversation == null || !conversation.group || revision.isEmpty) {
      if (!mounted) return;
      _strategyProjectionConversationId = conversationId;
      _strategyProjectionRevision = revision;
      setState(_clearStrategyFields);
      return;
    }
    _applyPersistedStrategySelection(revision);
    try {
      final projection = await _inspectStrategy(revision);
      if (!mounted ||
          generation != _strategyProjectionGeneration ||
          widget.controller.selectedConversationId != conversationId ||
          widget.controller.selectedConversation?.strategyRevision.trim() !=
              revision) {
        return;
      }
      _strategyProjectionConversationId = conversationId;
      _strategyProjectionRevision = revision;
      if (projection == null) {
        return;
      }
      _applyStrategyProjection(projection);
    } on AdaptiveFlywheelFailure {
      return;
    }
  }

  void _applyPersistedStrategySelection(String revision) {
    setState(() {
      if (_strategyRevision != revision) {
        _strategyRuntimeProfiles = const {};
      }
      _strategyRevision = revision;
    });
  }

  Future<GroupStrategyProjection?> _inspectStrategy(
    String revisionDigest, {
    AdaptiveFlywheelGateway? gatewayOverride,
    List<AdaptiveFlywheelDefinition>? strategiesOverride,
  }) async {
    final gateway = gatewayOverride ?? widget.flywheelGateway;
    if (gateway == null) return null;
    final strategies = strategiesOverride ?? _authorizedStrategies;
    AdaptiveFlywheelDefinition? selected;
    for (final definition in strategies) {
      if (definition.revisionDigest == revisionDigest) {
        selected = definition;
        break;
      }
    }
    if (selected == null) return null;
    final inspection = AdaptiveFlywheelInspection.fromJson(
      adaptiveFlywheelStringMap(
        await gateway.execute({
          'action': 'strategy.definition.inspect',
          'revisionDigest': revisionDigest,
        }),
      ),
    );
    if (!inspection.authorized) return null;
    final agentIds = <String>{};
    final runtimeProfiles = <String, AgentParticipantRuntimeProfile>{};
    for (final slot in inspection.slots.where((slot) => slot.kind == 'actor')) {
      for (final binding in inspection.bindings[slot.id] ?? const []) {
        final agentId = binding.valueId.trim();
        if (agentId.isEmpty) continue;
        agentIds.add(agentId);
        runtimeProfiles[agentId] = AgentParticipantRuntimeProfile(
          model: binding.model,
          reasoningEffort: binding.reasoningEffort,
        );
      }
    }
    return GroupStrategyProjection(
      revision: revisionDigest,
      agentIds: Set<String>.unmodifiable(agentIds),
      runtimeProfiles: Map<String, AgentParticipantRuntimeProfile>.unmodifiable(
        runtimeProfiles,
      ),
    );
  }

  void _applyStrategyProjection(GroupStrategyProjection projection) {
    setState(() {
      _strategyRevision = projection.revision;
      _strategyRuntimeProfiles = projection.runtimeProfiles;
    });
  }

  bool _assistantActive(ClientConversation conversation) =>
      _assistantActiveByConversation[conversation.id] ??
      conversation.assistantMembership != null;

  void _toggleAssistant(ClientConversation conversation) {
    setState(() {
      _assistantActiveByConversation[conversation.id] = !_assistantActive(
        conversation,
      );
    });
  }

  String _assistantStatusLabel(
    LicoStrings strings,
    ClientConversation conversation,
  ) {
    if (conversation.assistantMembership == null) {
      return strings.assistantNeedsConfigurationStatus;
    }
    if (!_assistantActive(conversation)) return strings.assistantPausedStatus;
    final subagents = _participantRoleByHandle.entries
        .where((entry) => _turnSubscriptions.containsKey(entry.key))
        .where((entry) => entry.value.trim() != 'assistant')
        .map((entry) => _participantAgentIdByHandle[entry.key]?.trim() ?? '')
        .where((agentId) => agentId.isNotEmpty)
        .toSet();
    if (subagents.isNotEmpty) {
      return strings.assistantCoordinatingStatus(subagents.length);
    }
    final assistantWorking =
        _turnSubscriptions.keys.any(
          (handle) => _participantRoleByHandle[handle]?.trim() == 'assistant',
        ) ||
        widget.controller.dispatchPending;
    return assistantWorking
        ? strings.assistantWorkingAloneStatus
        : strings.assistantReadyStatus;
  }

  /// Live turn projections in attach order. Each scope's list is memoized by
  /// the shared holder, so unchanged turns keep identical lists and the
  /// message-list timeline cache only ever sees one changed entry.
  List<AgentConversationMessage> get _liveMessages {
    if (_visibleTurnHandles.isEmpty) {
      _cachedLiveParts = null;
      _cachedLiveMessages = List<AgentConversationMessage>.empty(
        growable: false,
      );
      return _cachedLiveMessages!;
    }
    final parts = <List<AgentConversationMessage>>[
      for (final handle in _visibleTurnHandles)
        _turnStates.projectionFor(_scopeKeyFor(handle)).messages,
    ];
    final previousParts = _cachedLiveParts;
    final previousMerged = _cachedLiveMessages;
    if (previousParts != null &&
        previousMerged != null &&
        previousParts.length == parts.length) {
      var unchanged = true;
      for (var index = 0; index < parts.length; index += 1) {
        if (!identical(previousParts[index], parts[index])) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return previousMerged;
    }
    final merged = List<AgentConversationMessage>.unmodifiable([
      for (final part in parts) ...part,
    ]);
    _cachedLiveParts = parts;
    _cachedLiveMessages = merged;
    return merged;
  }

  /// Canonical projection with identity caching. Only event references and the
  /// conversation identity enter the cache key: a rebuild that republishes the
  /// same event list reuses the session and every message object, so the
  /// message-list timeline cache keeps its in-place tail-swap fast path instead
  /// of rebuilding the timeline on every streamed chunk.
  AgentConversationSession _canonicalSession(
    ClientConversation conversation,
    LicoStrings strings,
  ) {
    final events = widget.controller.events;
    final cached = _cachedSession;
    if (cached != null &&
        identical(_cachedSessionConversation, conversation) &&
        identical(_cachedSessionEvents, events) &&
        _cachedSessionLocale == strings.locale.languageCode) {
      return cached;
    }
    final session = canonicalGroupConversationSession(
      conversation,
      events,
      strings,
    );
    _cachedSession = session;
    _cachedSessionConversation = conversation;
    _cachedSessionEvents = events;
    _cachedSessionLocale = strings.locale.languageCode;
    return session;
  }

  Widget _groupFailureCapsule(ClientConversationController controller) {
    return CanonicalGroupFailureCapsule(
      code: controller.failureCode,
      failureRef: controller.failureRef,
      copyBlob: controller.failureCopyBlob,
      onCopy: widget.onCopyText,
    );
  }

  bool get _turnActive =>
      _turnSubscriptions.isNotEmpty || widget.controller.dispatchPending;

  Future<void> _ensureConversationHost() async {
    final gateway = widget.persistentGateway;
    final conversationId = widget.controller.selectedConversationId;
    if (gateway == null || conversationId.isEmpty) {
      return;
    }
    try {
      await gateway.ensureRuntime(conversationId: conversationId);
    } on Object {
      // Persist does not depend on the host; dispatch will surface a code.
    }
  }

  void _detachLiveTurns() {
    for (final subscription in _turnSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    for (final handle in _visibleTurnHandles) {
      _turnStates.removeScope(_scopeKeyFor(handle));
    }
    _turnSubscriptions.clear();
    _visibleTurnHandles.clear();
    _turnCursorByHandle.clear();
    _participantAgentIdByHandle.clear();
    _participantRoleByHandle.clear();
    _finishingHandles.clear();
    _attachedConversationId = '';
  }

  Future<void> _attachLiveTurns({
    bool waitForChange = false,
    List<Map<String, dynamic>> postedTurns = const [],
  }) async {
    final gateway = widget.persistentGateway;
    final conversationId = widget.controller.selectedConversationId;
    if (gateway == null || conversationId.isEmpty) {
      _detachLiveTurns();
      if (mounted) setState(() {});
      return;
    }
    if (_attachedConversationId != conversationId) {
      _detachLiveTurns();
      _attachedConversationId = conversationId;
    }
    List<Map<String, dynamic>> turns = List<Map<String, dynamic>>.from(
      postedTurns,
    );
    try {
      final discovered = await gateway.activeTurns(
        agentId: '',
        conversationId: conversationId,
        waitForChange: waitForChange && turns.isEmpty
            ? const Duration(seconds: 2)
            : Duration.zero,
      );
      if (discovered.isNotEmpty) {
        turns = _mergeLiveTurns(turns, discovered);
      }
    } on Object {
      // Keep returned handles and existing observers when discovery is down.
    }
    if (!mounted ||
        widget.controller.selectedConversationId != conversationId) {
      return;
    }
    for (final turn in turns) {
      final handle = (turn['turnHandle'] ?? '').toString().trim();
      if (handle.isEmpty) continue;
      if (_turnSubscriptions.containsKey(handle)) continue;
      final participant = _activeTurnParticipant(turn);
      if (participant == null) continue;
      _listenTurn(
        gateway,
        handle: handle,
        conversationId: (turn['conversationId'] ?? conversationId)
            .toString()
            .trim(),
        agentId: participant.agentId,
        participantLabel: participant.label,
        participantRole: participant.role,
        // New panes replay from zero. A detached observer resumes after the
        // last frame already applied to its retained live projection.
        afterCursor: _turnCursorByHandle[handle] ?? 0,
      );
    }
    // Discovery is additive. Only the attached stream's terminal/error owns
    // detachment; a transient active-turn snapshot must never cancel work.
    if (mounted) setState(() {});
  }

  void _listenTurn(
    PersistentAgentConversationGateway gateway, {
    required String handle,
    required String conversationId,
    required String agentId,
    required String participantLabel,
    required String participantRole,
    required int afterCursor,
  }) {
    _visibleTurnHandles.add(handle);
    _participantAgentIdByHandle[handle] = agentId;
    _participantRoleByHandle[handle] = participantRole;
    final scopeKey = _scopeKeyFor(handle);
    _turnSubscriptions[handle] = gateway
        .attachActiveTurn(
          turnHandle: handle,
          conversationId: conversationId,
          afterCursor: afterCursor,
        )
        .listen(
          (event) {
            if (!mounted ||
                widget.controller.selectedConversationId != conversationId) {
              return;
            }
            final terminal = persistentTurnEventIsTerminal(event);
            final cursor = event.payload['cursor'];
            if (cursor is int && cursor > (_turnCursorByHandle[handle] ?? 0)) {
              _turnCursorByHandle[handle] = cursor;
            }
            // One generated delta enters the shared holder; the holder owns
            // the blackboard mutation, the 32 ms publish coalescing, and the
            // immediate terminal publish. The scope's turn id is pinned to the
            // dispatch handle because one attach stream always serves one turn,
            // and individual frames may carry heterogeneous native turn ids.
            _turnStates.applyDelta(
              ConversationDeltaEvent(<String, dynamic>{
                'event': event.kind,
                'sessionId': event.sessionId,
                'turnId': 'live-$handle',
                'turnHandle': handle,
                'payload': event.payload,
              }),
              scopeKey: scopeKey,
              participantAgentId: agentId,
              participantLabel: participantLabel,
              participantRole: participantRole,
            );
            if (terminal) {
              unawaited(_finishTurn(handle));
            }
          },
          onDone: () => unawaited(_finishTurn(handle)),
          onError: (Object _) => unawaited(_handleTurnObserverFailure(handle)),
          cancelOnError: false,
        );
  }

  void _removeLiveTurn(String handle) {
    _visibleTurnHandles.remove(handle);
    _turnCursorByHandle.remove(handle);
    _turnStates.removeScope(_scopeKeyFor(handle));
    _participantAgentIdByHandle.remove(handle);
    _participantRoleByHandle.remove(handle);
  }

  Future<void> _handleTurnObserverFailure(String handle) async {
    if (!_finishingHandles.add(handle)) return;
    final conversationId = widget.controller.selectedConversationId;
    final subscription = _turnSubscriptions.remove(handle);
    if (subscription != null) unawaited(subscription.cancel());
    try {
      // Reload the durable Conversation before changing its live projection.
      // Observer loss is detach and carries no lifecycle or failure authority.
      final reloaded = await widget.controller.reloadSelected();
      if (!mounted ||
          widget.controller.selectedConversationId != conversationId) {
        return;
      }
      if (reloaded) _pruneDurablySettledLiveTurns();
      await _attachLiveTurns(waitForChange: true);
      if (!mounted) return;
      if (reloaded) _surfacePersistedDispatchFailure();
      if (_turnSubscriptions.isEmpty) {
        widget.controller.settleLiveDispatch();
      }
      if (mounted) setState(() {});
    } finally {
      _finishingHandles.remove(handle);
    }
  }

  Future<void> _finishTurn(String handle) async {
    if (!_finishingHandles.add(handle)) return;
    final subscription = _turnSubscriptions.remove(handle);
    if (subscription != null) unawaited(subscription.cancel());
    try {
      final reloaded = await _reloadSelectedForHandoff(handle);
      if (!mounted) return;
      if (reloaded) _removeLiveTurn(handle);
      if (widget.controller.dispatchPending) {
        await _attachLiveTurns(waitForChange: true);
        if (!mounted) return;
        if (_turnSubscriptions.isNotEmpty) {
          return;
        }
      }
      if (reloaded) _surfacePersistedDispatchFailure();
      widget.controller.settleLiveDispatch();
      if (mounted) setState(() {});
    } finally {
      _finishingHandles.remove(handle);
    }
  }

  Future<bool> _reloadSelectedForHandoff(String handle) async {
    final conversationId = widget.controller.selectedConversationId;
    for (final delay in const <Duration>[
      Duration.zero,
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
    ]) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (!mounted ||
          widget.controller.selectedConversationId != conversationId) {
        return false;
      }
      final reloaded = await widget.controller.reloadSelected();
      if (!mounted ||
          widget.controller.selectedConversationId != conversationId) {
        return false;
      }
      if (reloaded && _durablySettled(handle)) return true;
    }
    return false;
  }

  void _pruneDurablySettledLiveTurns() {
    if (_visibleTurnHandles.isEmpty) return;
    final settledHandles = widget.controller.events
        .where(
          (event) => event.finalized && event.correlationId.trim().isNotEmpty,
        )
        .map((event) => event.correlationId.trim())
        .toSet();
    if (settledHandles.isEmpty) return;
    final settledLiveHandles = _visibleTurnHandles
        .where(
          (handle) =>
              !_turnSubscriptions.containsKey(handle) &&
              settledHandles.contains(handle),
        )
        .toList(growable: false);
    for (final handle in settledLiveHandles) {
      _removeLiveTurn(handle);
    }
  }

  bool _durablySettled(String handle) => widget.controller.events.any(
    (event) => event.finalized && event.correlationId.trim() == handle,
  );

  void _surfacePersistedDispatchFailure() {
    if (widget.controller.failureCode.isNotEmpty) return;
    if (widget.controller.events.isEmpty) return;
    final event = widget.controller.events.last;
    for (final part in event.parts.reversed) {
      if (part.kind != ConversationEventPartKind.diagnostic) continue;
      final code = persistentTurnDiagnosticFailureCode(part.content);
      if (code == null) continue;
      widget.controller.surfaceFailure('turn', code);
      return;
    }
  }

  Future<bool> _sendComposerMessage(String text) async {
    final conversation = widget.controller.selectedConversation;
    final posted = await widget.controller.postMessage(
      text,
      dispatch:
          conversation != null &&
          conversation.assistantMembership != null &&
          _assistantActive(conversation),
    );
    if (!posted) return false;
    if (mounted) setState(() {});
    unawaited(_attachLiveTurns(postedTurns: widget.controller.liveTurns));
    return true;
  }

  List<Map<String, dynamic>> _mergeLiveTurns(
    List<Map<String, dynamic>> posted,
    List<Map<String, dynamic>> discovered,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    for (final turn in [...posted, ...discovered]) {
      final handle = (turn['turnHandle'] ?? '').toString().trim();
      if (handle.isEmpty) continue;
      merged[handle] = turn;
    }
    return merged.values.toList(growable: false);
  }

  ({String agentId, String label, String role})? _activeTurnParticipant(
    Map<String, dynamic> turn,
  ) {
    final membershipId = (turn['membershipId'] ?? '').toString().trim();
    final projectedAgent = (turn['agent'] ?? turn['agentId'] ?? '')
        .toString()
        .trim();
    final conversation = widget.controller.selectedConversation;
    if (conversation == null || membershipId.isEmpty) return null;
    for (final membership in conversation.activeAgentMemberships) {
      if (membership.id != membershipId) continue;
      final agentId = membership.principal.agentId.trim();
      if (agentId.isEmpty ||
          (projectedAgent.isNotEmpty && projectedAgent != agentId)) {
        return null;
      }
      final label = membership.principal.displayName.trim();
      return (
        agentId: agentId,
        label: label.isEmpty ? agentId : label,
        role: membership.id == conversation.assistantMembershipId
            ? 'assistant'
            : 'member',
      );
    }
    return null;
  }

  void _continueConversationScroll(double overscroll) {
    if (!_messageScrollController.hasClients || overscroll == 0) return;
    final position = _messageScrollController.position;
    _messageScrollController.jumpTo(
      (position.pixels - overscroll).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  Future<void> _mentionAgent(
    ClientConversation conversation,
    TargetCandidate target,
  ) async {
    var membership = canonicalGroupAgentMembership(conversation, target);
    if (membership == null) {
      final joined = await widget.controller.ensureSelectedAgentMembership(
        agentId: target.target,
        displayName: agentConversationTargetDisplayName(target),
      );
      if (!mounted || !joined) return;
      final refreshed = widget.controller.selectedConversation;
      if (refreshed == null) return;
      membership = canonicalGroupAgentMembership(refreshed, target);
      if (membership == null) return;
    }
    final label = membership.principal.displayName.trim().isEmpty
        ? agentConversationTargetDisplayName(target)
        : membership.principal.displayName.trim();
    final draft = widget.controller.draft;
    final separator = draft.isEmpty || RegExp(r'\s$').hasMatch(draft)
        ? ''
        : ' ';
    widget.controller.updateDraft('$draft$separator@$label ');
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final controller = widget.controller;
    final conversation = controller.selectedConversation;
    if (conversation == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          CanonicalGroupLoadingOrEmpty(loading: controller.loading),
          if (controller.failureCode.isNotEmpty)
            Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
                child: _groupFailureCapsule(controller),
              ),
            ),
        ],
      );
    }
    final participantTargets = resolveCanonicalGroupParticipantTargets(
      conversation,
      widget.targets,
    );
    if (participantTargets.isEmpty) {
      return CanonicalGroupLoadingOrEmpty(loading: controller.loading);
    }
    final rosterTargets = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      [...participantTargets, ...widget.targets],
      controller.recentParticipantAgentIds,
    );
    final session = _canonicalSession(conversation, strings);
    final primaryTarget = participantTargets.first;
    final state = AgentConversationPaneState(
      target: primaryTarget,
      session: session,
      liveMessages: _liveMessages,
      recentSessions: const [],
      loading: controller.loading,
      turnActive: _turnActive,
      composerBusy: controller.sending || _turnActive,
      preparingNewConversation: false,
      composerEnabled: conversation.localOwnerMembership != null,
      sendGateReasonCode: '',
      composerDraft: controller.draft,
      conversationLabel: conversation.title.trim().isEmpty
          ? strings.groupConversation
          : conversation.title.trim(),
      modelOptions: const [],
      selectedModel: '',
      defaultModel: '',
      reasoningEffortOptions: const [],
      selectedReasoningEffort: '',
      participantTargets: participantTargets,
      composerMentionLabels: {
        for (final membership in conversation.activeAgentMemberships)
          membership.principal.agentId:
              membership.principal.displayName.trim().isEmpty
              ? agentConversationTargetDisplayName(
                  participantTargets.firstWhere(
                    (target) => target.target == membership.principal.agentId,
                  ),
                )
              : membership.principal.displayName.trim(),
      },
      participantConversationIds: {
        for (final membership in conversation.activeAgentMemberships)
          membership.principal.agentId: conversation.id,
      },
      participantRuntimeProfiles: _strategyRuntimeProfiles,
      composerFlywheel: GroupStrategyPickerCapsule(
        label: _assistantStatusLabel(strings, conversation),
        strategies: _authorizedStrategies,
        selectedRevision: _strategyRevision,
        onSelected: (revision) => unawaited(_selectStrategy(revision)),
        onCleared: () => unawaited(_exitStrategyMode()),
        onOpen: widget.onOpenAdaptiveFlywheel == null
            ? null
            : (revision) => unawaited(_openAdaptiveFlywheel(revision)),
      ),
      composerLeading: AssistantToggleButton(
        active: _assistantActive(conversation),
        configured: conversation.assistantMembership != null,
        onTap: conversation.assistantMembership == null
            ? () => unawaited(_openAdaptiveFlywheel(_strategyRevision))
            : () => _toggleAssistant(conversation),
      ),
    );
    final actions = AgentConversationPaneActions(
      onModelChanged: (_) {},
      onReasoningEffortChanged: (_) {},
      onDraftChanged: controller.updateDraft,
      onSend: _sendComposerMessage,
      onSelectSession: (_) {},
      onCopyText: widget.onCopyText,
    );
    final pane = AgentConversationActivePane(
      key: const Key('canonical-group-conversation-pane'),
      state: state,
      actions: actions,
      header: CanonicalGroupConversationHeader(
        conversation: conversation,
        rosterVisible: _rosterVisible,
        onToggleRoster: () => setState(() => _rosterVisible = !_rosterVisible),
      ),
      framed: false,
      messageScrollController: _messageScrollController,
    );
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final rosterFloats =
        !isMobileClientPlatform(context) &&
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
    final conversationBody = rosterFloats
        ? LayoutBuilder(
            builder: (context, constraints) {
              final topInset =
                  MessagingDesktopMetrics.conversationHeaderOverlayExtent +
                  MessagingDesktopMetrics.groupRosterHeaderGap;
              final bottomInset =
                  MessagingDesktopMetrics.conversationComposerOverlayExtent +
                  MessagingDesktopMetrics.groupRosterComposerGap;
              final visibleExtent =
                  constraints.maxHeight - topInset - bottomInset;
              if (visibleExtent <
                  MessagingDesktopMetrics.groupRosterMinimumVisibleExtent) {
                return pane;
              }
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.none,
                children: [
                  pane,
                  Positioned(
                    right:
                        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
                    top: topInset,
                    bottom: bottomInset,
                    width: MessagingDesktopMetrics.groupRosterExtent,
                    child: CanonicalGroupRosterReveal(
                      visible: _rosterVisible,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: math.min(
                            visibleExtent,
                            MessagingDesktopMetrics.groupRosterMaxVisibleExtent,
                          ),
                        ),
                        child: CanonicalGroupRosterSurface(
                          child: CanonicalGroupRoster(
                            conversation: conversation,
                            targets: rosterTargets,
                            onMentionAgent: (target) =>
                                unawaited(_mentionAgent(conversation, target)),
                            onOpenAgentConversations:
                                widget.onOpenAgentConversations == null
                                ? null
                                : (target) => widget.onOpenAgentConversations!(
                                    target.id,
                                  ),
                            onBoundaryOverscroll: _continueConversationScroll,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: pane),
              if (_rosterVisible)
                CanonicalGroupRoster(
                  conversation: conversation,
                  targets: rosterTargets,
                  onMentionAgent: (target) =>
                      unawaited(_mentionAgent(conversation, target)),
                  onOpenAgentConversations:
                      widget.onOpenAgentConversations == null
                      ? null
                      : (target) => widget.onOpenAgentConversations!(target.id),
                  onBoundaryOverscroll: _continueConversationScroll,
                ),
            ],
          );
    final body = Stack(
      fit: StackFit.expand,
      children: [
        conversationBody,
        if (controller.failureCode.isNotEmpty)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                top:
                    MessagingDesktopMetrics.conversationHeaderOverlayExtent +
                    MessagingDesktopMetrics.conversationFailureAlertGap,
                left: MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
                right: MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
              ),
              child: _groupFailureCapsule(controller),
            ),
          ),
      ],
    );
    return widget.framed ? PanelFrame(child: body) : body;
  }
}
