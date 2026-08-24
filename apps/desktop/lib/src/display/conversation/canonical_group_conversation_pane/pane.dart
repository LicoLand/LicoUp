import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_turn_process_state.dart';
import 'package:licoup/src/application/features/agents/conversation/persistent_turn_process_observer.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
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
  final Map<String, ConversationTurnProcessState> _processByHandle = {};
  final Set<String> _finishingHandles = {};
  String _attachedConversationId = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onConversationChanged);
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
    _detachLiveTurns();
    _messageScrollController.dispose();
    super.dispose();
  }

  void _onConversationChanged() {
    if (!mounted) return;
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
    final subagents = _processByHandle.values
        .where((state) => state.participantRole.trim() != 'assistant')
        .map((state) => state.participantAgentId.trim())
        .where((agentId) => agentId.isNotEmpty)
        .toSet();
    if (subagents.isNotEmpty) {
      return strings.assistantCoordinatingStatus(subagents.length);
    }
    final assistantWorking =
        _processByHandle.values.any(
          (state) => state.participantRole.trim() == 'assistant',
        ) ||
        widget.controller.dispatchPending;
    return assistantWorking
        ? strings.assistantWorkingAloneStatus
        : strings.assistantReadyStatus;
  }

  List<AgentConversationMessage> get _liveMessages =>
      List<AgentConversationMessage>.unmodifiable([
        for (final state in _processByHandle.values)
          ...state.projectedMessages(includeUser: false),
      ]);

  Widget _groupFailureCapsule(ClientConversationController controller) {
    return CanonicalGroupFailureCapsule(
      code: controller.failureCode,
      failureRef: controller.failureRef,
      copyBlob: controller.failureCopyBlob,
      onCopy: widget.onCopyText,
    );
  }

  bool get _turnActive =>
      _turnSubscriptions.isNotEmpty ||
      _processByHandle.isNotEmpty ||
      widget.controller.dispatchPending;

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
    _turnSubscriptions.clear();
    _processByHandle.clear();
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
    var authoritativeSnapshot = false;
    try {
      final discovered = await gateway.activeTurns(
        agentId: '',
        conversationId: conversationId,
        waitForChange: waitForChange && turns.isEmpty
            ? const Duration(seconds: 2)
            : Duration.zero,
      );
      authoritativeSnapshot = true;
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
    final liveHandles = <String>{};
    for (final turn in turns) {
      final handle = (turn['turnHandle'] ?? '').toString().trim();
      final participant = _activeTurnParticipant(turn);
      if (handle.isEmpty || participant == null) continue;
      liveHandles.add(handle);
      if (_turnSubscriptions.containsKey(handle)) continue;
      _ensureLiveProcess(
        handle: handle,
        agentId: participant.agentId,
        participantLabel: participant.label,
        participantRole: participant.role,
        userText: '',
      );
      _listenTurn(
        gateway,
        handle: handle,
        conversationId: (turn['conversationId'] ?? conversationId)
            .toString()
            .trim(),
        agentId: participant.agentId,
        participantLabel: participant.label,
        participantRole: participant.role,
        // `highWater` is the host's cursor, not this observer's cursor. A new
        // pane has seen no process frames and must rebuild from canonical
        // cursor zero; the transport owns cursor-safe reconnects thereafter.
        afterCursor: 0,
      );
    }
    if (authoritativeSnapshot) {
      final stale = _turnSubscriptions.keys
          .where((handle) => !liveHandles.contains(handle))
          .toList(growable: false);
      for (final handle in stale) {
        unawaited(_turnSubscriptions.remove(handle)?.cancel());
        _processByHandle.remove(handle);
      }
    }
    if (mounted) setState(() {});
  }

  void _ensureLiveProcess({
    required String handle,
    required String agentId,
    required String participantLabel,
    required String participantRole,
    required String userText,
  }) {
    final existing = _processByHandle[handle];
    if (existing != null) {
      existing.recordParticipant(
        participantAgentId: agentId,
        participantLabel: participantLabel,
        participantRole: participantRole,
      );
      return;
    }
    final state = ConversationTurnProcessState(
      turnId: 'live-$handle',
      userText: userText,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    state.recordParticipant(
      participantAgentId: agentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    _processByHandle[handle] = state;
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
    _ensureLiveProcess(
      handle: handle,
      agentId: agentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
      userText: '',
    );
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
            final state = _processByHandle[handle];
            if (state == null) return;
            final terminal = applyPersistentTurnProcessEvent(
              state: state,
              event: event,
              agentId: agentId,
              participantLabel: participantLabel,
              participantRole: participantRole,
            );
            if (mounted) setState(() {});
            if (terminal) {
              unawaited(_finishTurn(handle));
            }
          },
          onDone: () => unawaited(_finishTurn(handle)),
          onError: (Object _) => unawaited(_handleTurnObserverFailure(handle)),
          cancelOnError: false,
        );
  }

  Future<void> _handleTurnObserverFailure(String handle) async {
    if (!_finishingHandles.add(handle)) return;
    final subscription = _turnSubscriptions.remove(handle);
    if (subscription != null) unawaited(subscription.cancel());
    try {
      // Reload the durable Conversation before changing its live projection.
      // Observer loss is detach and carries no lifecycle or failure authority.
      await widget.controller.reloadSelected();
      if (!mounted) return;
      _surfacePersistedDispatchFailure();
      _processByHandle.remove(handle);
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
    unawaited(_turnSubscriptions.remove(handle)?.cancel());
    _processByHandle.remove(handle);
    if (mounted) setState(() {});
    try {
      await widget.controller.reloadSelected();
      if (!mounted) return;
      if (widget.controller.dispatchPending) {
        await _attachLiveTurns(waitForChange: true);
        if (!mounted) return;
        if (_turnSubscriptions.isNotEmpty || _processByHandle.isNotEmpty) {
          return;
        }
      }
      _surfacePersistedDispatchFailure();
      widget.controller.settleLiveDispatch();
      if (mounted) setState(() {});
    } finally {
      _finishingHandles.remove(handle);
    }
  }

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
    for (final turn in widget.controller.liveTurns) {
      final handle = (turn['turnHandle'] ?? '').toString().trim();
      final participant = _activeTurnParticipant(turn);
      if (handle.isEmpty || participant == null) continue;
      _ensureLiveProcess(
        handle: handle,
        agentId: participant.agentId,
        participantLabel: participant.label,
        participantRole: participant.role,
        userText: text,
      );
    }
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
    final session = canonicalGroupConversationSession(
      conversation,
      controller.events,
      strings,
    );
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
