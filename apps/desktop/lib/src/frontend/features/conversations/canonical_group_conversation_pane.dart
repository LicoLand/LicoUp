import 'dart:async';
import 'dart:convert';
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
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Future<void> showCreateCanonicalGroupConversationDialog({
  required BuildContext context,
  required ClientConversationController controller,
  required List<TargetCandidate> targets,
}) async {
  final candidates = targets
      .where((target) => target.isConversationAgent && target.canRelayRuntime)
      .toList(growable: false);
  await showDialog<void>(
    context: context,
    builder: (context) => _CreateCanonicalGroupConversationDialog(
      controller: controller,
      candidates: candidates,
    ),
  );
}

class _CreateCanonicalGroupConversationDialog extends StatefulWidget {
  const _CreateCanonicalGroupConversationDialog({
    required this.controller,
    required this.candidates,
  });

  final ClientConversationController controller;
  final List<TargetCandidate> candidates;

  @override
  State<_CreateCanonicalGroupConversationDialog> createState() =>
      _CreateCanonicalGroupConversationDialogState();
}

class _CreateCanonicalGroupConversationDialogState
    extends State<_CreateCanonicalGroupConversationDialog> {
  final _title = TextEditingController();
  final _selected = <String>{};
  var _creating = false;
  var _failureCode = '';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final canCreate =
        !_creating && _title.text.trim().isNotEmpty && _selected.isNotEmpty;
    return AlertDialog(
      key: const Key('canonical-group-create-dialog'),
      title: Text(strings.newGroupConversation),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('canonical-group-title-field'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: strings.groupConversationName,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            Text(
              strings.selectGroupConversationAgents,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (widget.candidates.isEmpty)
              Text(
                strings.groupConversationNeedsAgent,
                style: TextStyle(color: context.licoColors.error),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final checked = _selected.contains(candidate.target);
                    return CheckboxListTile(
                      key: ValueKey<String>(
                        'canonical-group-member-${candidate.target}',
                      ),
                      value: checked,
                      title: Text(
                        agentConversationTargetDisplayName(candidate),
                      ),
                      secondary: MessagingAgentAvatar(
                        target: candidate,
                        size: 32,
                        iconSize: 18,
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      onChanged: (value) => setState(() {
                        value == true
                            ? _selected.add(candidate.target)
                            : _selected.remove(candidate.target);
                      }),
                    );
                  },
                ),
              ),
            if (_failureCode.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                key: const Key('canonical-group-create-failure'),
                strings.groupConversationFailure('create', _failureCode),
                style: TextStyle(color: context.licoColors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const Key('canonical-group-create-confirm'),
          onPressed: canCreate ? _create : null,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.surfaceLow.withValues(alpha: 0.5);
              }
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return colors.primaryStrong;
              }
              return colors.primary;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.disabled)
                  ? colors.textDisabled
                  : colors.textOnPrimary;
            }),
          ),
          child: _creating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.createGroupConversation),
        ),
      ],
    );
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _failureCode = '';
    });
    final members = [
      for (final candidate in widget.candidates)
        if (_selected.contains(candidate.target))
          ClientConversationGroupMemberDraft(
            agentId: candidate.target,
            displayName: agentConversationTargetDisplayName(candidate),
          ),
    ];
    final created = await widget.controller.createGroup(
      title: _title.text,
      members: members,
    );
    if (!mounted) return;
    if (created) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _creating = false;
        _failureCode = widget.controller.failureCode.isEmpty
            ? 'conversation_operation_failed'
            : widget.controller.failureCode;
      });
    }
  }
}

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

  Future<_GroupStrategyProjection?> _inspectStrategy(
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
    return _GroupStrategyProjection(
      revision: revisionDigest,
      agentIds: Set<String>.unmodifiable(agentIds),
      runtimeProfiles: Map<String, AgentParticipantRuntimeProfile>.unmodifiable(
        runtimeProfiles,
      ),
    );
  }

  void _applyStrategyProjection(_GroupStrategyProjection projection) {
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
    return _CanonicalGroupFailureCapsule(
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
    var membership = _agentMembership(conversation, target);
    if (membership == null) {
      final joined = await widget.controller.ensureSelectedAgentMembership(
        agentId: target.target,
        displayName: agentConversationTargetDisplayName(target),
      );
      if (!mounted || !joined) return;
      final refreshed = widget.controller.selectedConversation;
      if (refreshed == null) return;
      membership = _agentMembership(refreshed, target);
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
          _CanonicalGroupLoadingOrEmpty(loading: controller.loading),
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
      return _CanonicalGroupLoadingOrEmpty(loading: controller.loading);
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
      composerFlywheel: _GroupStrategyPickerCapsule(
        label: _assistantStatusLabel(strings, conversation),
        strategies: _authorizedStrategies,
        selectedRevision: _strategyRevision,
        onSelected: (revision) => unawaited(_selectStrategy(revision)),
        onCleared: () => unawaited(_exitStrategyMode()),
        onOpen: widget.onOpenAdaptiveFlywheel == null
            ? null
            : (revision) => unawaited(_openAdaptiveFlywheel(revision)),
      ),
      composerLeading: _AssistantToggleButton(
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
                    child: _CanonicalGroupRosterReveal(
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

class CanonicalGroupConversationSidebar extends StatelessWidget {
  const CanonicalGroupConversationSidebar({
    super.key,
    required this.conversations,
    required this.selectedConversationId,
    required this.onSelect,
    required this.onCreate,
  });

  final List<ClientConversationSummary> conversations;
  final String selectedConversationId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 42,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 13,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      strings.groupConversation,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('canonical-group-sidebar-create'),
                    tooltip: strings.newGroupConversation,
                    onPressed: onCreate,
                    icon: const Icon(Icons.add_rounded, size: 17),
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          for (final conversation in conversations.take(3))
            _CanonicalGroupSidebarRow(
              conversation: conversation,
              selected: conversation.id == selectedConversationId,
              onTap: () => onSelect(conversation.id),
            ),
          if (conversations.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  strings.noGroupConversationsYet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 10.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CanonicalGroupSidebarRow extends StatelessWidget {
  const _CanonicalGroupSidebarRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
  });

  final ClientConversationSummary conversation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.floating),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? colors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(LicoRadius.floating),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.groups_2_rounded,
                  size: 20,
                  color: selected
                      ? colors.textOnPrimary
                      : ConversationVisualTokens.groupIdentityMark(colors),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? colors.textOnPrimary : colors.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        strings.groupConversationMemberCount(
                          conversation.membershipCount,
                        ),
                        style: TextStyle(
                          color: selected
                              ? colors.textOnPrimary.withAlpha(180)
                              : colors.textMuted,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CanonicalGroupConversationHeader extends StatelessWidget {
  const CanonicalGroupConversationHeader({
    super.key,
    required this.conversation,
    required this.rosterVisible,
    required this.onToggleRoster,
  });

  final ClientConversation conversation;
  final bool rosterVisible;
  final VoidCallback onToggleRoster;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = conversation.title.trim().isEmpty
        ? strings.groupConversation
        : conversation.title.trim();
    final identity = Row(
      children: [
        Container(
          key: const Key('canonical-group-header-avatar'),
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: ConversationVisualTokens.circularIdentityWellFill(colors),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.groups_2_rounded,
            color: ConversationVisualTokens.groupIdentityMark(colors),
            size: 21,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (conversation.pinned) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.push_pin_rounded,
                      size: 13,
                      color: colors.textMuted,
                    ),
                  ],
                ],
              ),
              Text(
                strings.groupConversationMemberCount(
                  conversation.activeMemberships.length,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    );
    final rosterToggle = _CanonicalGroupRosterToggleButton(
      rosterVisible: rosterVisible,
      onPressed: onToggleRoster,
    );
    if (isMobileClientPlatform(context)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(child: identity),
            rosterToggle,
          ],
        ),
      );
    }
    final identityRadius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    final controlRadius = BorderRadius.circular(999);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetH,
        MessagingDesktopMetrics.conversationHeaderCapsuleInsetV,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: MessagingConversationOverlayGlass(
                borderRadius: identityRadius,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadH,
                    vertical:
                        MessagingDesktopMetrics.conversationHeaderCapsulePadV,
                  ),
                  child: identity,
                ),
              ),
            ),
            const SizedBox(
              width: MessagingDesktopMetrics.conversationHeaderCapsuleButtonGap,
            ),
            AspectRatio(
              aspectRatio: 1,
              child: MessagingConversationOverlayGlass(
                key: const Key('canonical-group-roster-toggle-capsule'),
                borderRadius: controlRadius,
                child: Center(child: rosterToggle),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _CanonicalGroupRosterToggleButton extends StatelessWidget {
  const _CanonicalGroupRosterToggleButton({
    required this.rosterVisible,
    required this.onPressed,
  });

  final bool rosterVisible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return LicoIconButton(
      key: const Key('canonical-group-roster-toggle'),
      tooltip: rosterVisible
          ? strings.collapseAgentsSidebar
          : strings.expandAgentsSidebar,
      onPressed: onPressed,
      size: LicoIconButtonSize.large,
      shape: LicoIconButtonShape.circle,
      tone: LicoIconButtonTone.ghost,
      icon: AnimatedSwitcher(
        duration: context.motion(LicoMotion.short),
        switchInCurve: LicoMotion.standard,
        switchOutCurve: LicoMotion.standard,
        child: Icon(
          rosterVisible
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          key: ValueKey<bool>(rosterVisible),
        ),
      ),
    );
  }
}

final class _CanonicalGroupRosterReveal extends StatefulWidget {
  const _CanonicalGroupRosterReveal({
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  State<_CanonicalGroupRosterReveal> createState() =>
      _CanonicalGroupRosterRevealState();
}

final class _CanonicalGroupRosterRevealState
    extends State<_CanonicalGroupRosterReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _reveal;
  late bool _renderChild;

  @override
  void initState() {
    super.initState();
    _renderChild = widget.visible;
    _controller = AnimationController(
      vsync: this,
      duration: LicoMotion.medium,
      value: widget.visible ? 1 : 0,
    );
    _reveal = CurvedAnimation(
      parent: _controller,
      curve: LicoMotion.decelerate,
      reverseCurve: LicoMotion.accelerate,
    );
  }

  @override
  void didUpdateWidget(covariant _CanonicalGroupRosterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    _syncVisibility();
  }

  void _syncVisibility() {
    final duration = context.motion(LicoMotion.medium);
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (widget.visible) {
      if (!_renderChild) {
        setState(() => _renderChild = true);
      }
      if (duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
      return;
    }
    if (duration == Duration.zero) {
      _controller.value = 0;
      if (_renderChild) {
        setState(() => _renderChild = false);
      }
      return;
    }
    _controller.reverse().whenCompleteOrCancel(() {
      if (!mounted || widget.visible || !_controller.isDismissed) return;
      setState(() => _renderChild = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_renderChild) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final reveal = _reveal.value;
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: Align(
              key: const Key('canonical-group-roster-alignment'),
              alignment: Alignment.lerp(
                Alignment.topCenter,
                Alignment.center,
                reveal,
              )!,
              child: ClipRect(
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: reveal,
                  child: Opacity(opacity: reveal, child: child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class CanonicalGroupRoster extends StatelessWidget {
  const CanonicalGroupRoster({
    super.key,
    required this.conversation,
    required this.targets,
    required this.onMentionAgent,
    this.onOpenAgentConversations,
    this.onBoundaryOverscroll,
  });

  final ClientConversation conversation;
  final List<TargetCandidate> targets;
  final ValueChanged<TargetCandidate> onMentionAgent;
  final ValueChanged<TargetCandidate>? onOpenAgentConversations;
  final ValueChanged<double>? onBoundaryOverscroll;

  Future<void> _showAgentMenu({
    required BuildContext context,
    required TargetCandidate target,
    required String label,
    required Offset globalPosition,
  }) async {
    final strings = LicoStrings.of(context);
    final action = await showMessagingGlassMenu<_CanonicalGroupRosterAction>(
      context: context,
      globalPosition: globalPosition,
      menuKey: Key('canonical-group-roster-menu-${target.target}'),
      actions: [
        MessagingGlassMenuAction(
          value: _CanonicalGroupRosterAction.mention,
          label: strings.mentionAgent(label),
          leading: const Icon(Icons.alternate_email_rounded, size: 17),
        ),
        if (onOpenAgentConversations != null)
          MessagingGlassMenuAction(
            value: _CanonicalGroupRosterAction.openConversations,
            label: strings.openAgentConversations(label),
            leading: const Icon(Icons.forum_outlined, size: 17),
          ),
      ],
    );
    switch (action) {
      case _CanonicalGroupRosterAction.mention:
        onMentionAgent(target);
        break;
      case _CanonicalGroupRosterAction.openConversations:
        onOpenAgentConversations?.call(target);
        break;
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final membershipsByAgentId = {
      for (final membership in conversation.activeAgentMemberships)
        membership.principal.agentId: membership,
    };
    return SizedBox(
      key: const Key('canonical-group-roster'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: ScrollConfiguration(
        behavior: const _CanonicalGroupRosterScrollBehavior(),
        child: NotificationListener<OverscrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) {
              onBoundaryOverscroll?.call(notification.overscroll);
            }
            return false;
          },
          child: ListView.separated(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: MessagingDesktopMetrics.groupRosterContentInset,
              vertical: MessagingDesktopMetrics.groupRosterVerticalInset,
            ),
            itemCount: targets.length,
            separatorBuilder: (_, _) => const SizedBox(
              height: MessagingDesktopMetrics.groupRosterMemberGap,
            ),
            itemBuilder: (context, index) {
              final target = targets[index];
              final membership =
                  membershipsByAgentId[target.target] ??
                  membershipsByAgentId[target.id];
              final membershipLabel =
                  membership?.principal.displayName.trim() ?? '';
              final fullLabel = membershipLabel.isEmpty
                  ? agentConversationTargetDisplayName(target)
                  : membershipLabel;
              final compactLabel = agentConversationTargetCompactDisplayName(
                target,
              );
              return Tooltip(
                message: fullLabel,
                waitDuration: LicoMotion.tooltipWait,
                child: Column(
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        key: Key(
                          'canonical-group-roster-agent-${target.target}',
                        ),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onMentionAgent(target),
                        onDoubleTap: onOpenAgentConversations == null
                            ? null
                            : () => onOpenAgentConversations!(target),
                        onSecondaryTapDown: (details) => _showAgentMenu(
                          context: context,
                          target: target,
                          label: compactLabel,
                          globalPosition: details.globalPosition,
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            MessagingAgentAvatar(
                              target: target,
                              size: 42,
                              iconSize: 24,
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: target.canRelayRuntime
                                      ? colors.success
                                      : colors.textDisabled,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colors.surface,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      compactLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 9,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _CanonicalGroupRosterAction { mention, openConversations }

final class _CanonicalGroupRosterScrollBehavior extends MaterialScrollBehavior {
  const _CanonicalGroupRosterScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => Scrollbar(
    key: const Key('canonical-group-roster-scrollbar'),
    controller: details.controller,
    thickness: MessagingDesktopMetrics.groupRosterScrollbarThickness,
    radius: const Radius.circular(1),
    interactive: true,
    child: child,
  );
}

/// Detached group-member capsule, centered in the right transcript band and
/// styled with the same glass and width as the header visibility control.
class CanonicalGroupRosterSurface extends StatelessWidget {
  const CanonicalGroupRosterSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius,
    );
    return SizedBox(
      key: const Key('canonical-group-roster-surface'),
      width: MessagingDesktopMetrics.groupRosterExtent,
      child: MessagingConversationOverlayGlass(
        key: const Key('canonical-group-roster-glass'),
        borderRadius: radius,
        child: child,
      ),
    );
  }
}

List<TargetCandidate> resolveCanonicalGroupParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
) {
  final resolved = <TargetCandidate>[];
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId.trim();
    TargetCandidate? target;
    for (final candidate in targets) {
      if (candidate.target == agentId || candidate.id == agentId) {
        target = candidate;
        break;
      }
    }
    resolved.add(
      target ??
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: 'detected',
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
    );
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

List<TargetCandidate> resolveCanonicalGroupOrderedParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
  List<String> orderedAgentIds,
) {
  if (orderedAgentIds.isEmpty) return const [];
  final targetByAgentId = {
    for (final target in targets) target.target: target,
    for (final target in targets) target.id: target,
  };
  final membershipByAgentId = {
    for (final membership in conversation.activeAgentMemberships)
      membership.principal.agentId: membership,
  };
  final resolved = <TargetCandidate>[];
  for (final agentId in orderedAgentIds) {
    final target = targetByAgentId[agentId];
    if (target != null) {
      resolved.add(target);
    } else {
      final membership = membershipByAgentId[agentId];
      if (membership != null) {
        resolved.add(
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: 'detected',
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
        );
      }
    }
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

ClientConversationMembership? _agentMembership(
  ClientConversation conversation,
  TargetCandidate target,
) {
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId;
    if (agentId == target.target || agentId == target.id) return membership;
  }
  return null;
}

AgentConversationSession canonicalGroupConversationSession(
  ClientConversation conversation,
  List<ClientConversationEvent> events,
  LicoStrings strings,
) {
  final memberships = {
    for (final membership in conversation.memberships)
      membership.id: membership,
  };
  final membershipsByPrincipal = {
    for (final membership in conversation.memberships)
      membership.principal.id: membership,
  };
  final messages = <AgentConversationMessage>[];
  for (final event in events) {
    final author = memberships[event.authorMembershipId];
    if (event.kind != ConversationEventKind.message) {
      final presentation = _canonicalGroupEventPresentation(
        event,
        memberships: memberships,
        membershipsByPrincipal: membershipsByPrincipal,
        strings: strings,
      );
      messages.add(
        AgentConversationMessage(
          id: event.id,
          role: 'event',
          text: presentation.detail,
          createdAt: _iso(event.createdAtUnixMs),
          layer: AgentConversationSemanticLayer.execution,
          cardType: event.kind.wireName,
          cardTitle: presentation.title,
          stableIdentity: event.id,
        ),
      );
      continue;
    }
    final user = author?.principal.kind == ConversationPrincipalKind.human;
    final participantRole = user
        ? ''
        : (author != null && author.id == conversation.assistantMembershipId
              ? 'assistant'
              : 'member');
    final textChunks = <String>[];
    var textCreatedAt = event.createdAtUnixMs;
    var textFlush = 0;
    void flushText() {
      if (textChunks.isEmpty) return;
      messages.add(
        AgentConversationMessage(
          id: textFlush == 0 ? event.id : '${event.id}:text:$textFlush',
          role: user ? 'user' : 'assistant',
          text: textChunks.join(),
          createdAt: _iso(textCreatedAt),
          layer: AgentConversationSemanticLayer.thread,
          stableIdentity: event.id,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
        ),
      );
      textChunks.clear();
      textFlush += 1;
    }

    for (final eventPart in event.parts) {
      if (eventPart.kind == ConversationEventPartKind.text) {
        if (textChunks.isEmpty && eventPart.createdAtUnixMs != 0) {
          textCreatedAt = eventPart.createdAtUnixMs;
        }
        textChunks.add(eventPart.content);
        continue;
      }
      flushText();
      final presentation = _canonicalGroupPartPresentation(eventPart);
      messages.add(
        AgentConversationMessage(
          id: eventPart.id.isEmpty
              ? '${event.id}:${eventPart.ordinal}'
              : eventPart.id,
          role: user ? 'user' : presentation.cardType,
          text: presentation.text,
          createdAt: _iso(
            eventPart.createdAtUnixMs == 0
                ? event.createdAtUnixMs
                : eventPart.createdAtUnixMs,
          ),
          layer: AgentConversationSemanticLayer.execution,
          cardType: presentation.cardType,
          cardTitle: presentation.cardTitle,
          stableIdentity: event.id,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
        ),
      );
    }
    flushText();
  }
  return AgentConversationSession(
    id: conversation.id,
    agentId: conversation.activeAgentMemberships.isEmpty
        ? ''
        : conversation.activeAgentMemberships.first.principal.agentId,
    title: conversation.title,
    createdAt: _iso(conversation.createdAtUnixMs),
    updatedAt: _iso(conversation.updatedAtUnixMs),
    messages: List<AgentConversationMessage>.unmodifiable(messages),
    nativeSessionId: conversation.id,
    adapterId: 'canonical-conversation',
    sourceKind: 'canonical-conversation',
    sourceClient: 'licoup',
    sourceClientLabel: 'LicoUp',
    native: false,
    readOnly: false,
    messageCount: conversation.eventCount,
    sourceMessageCount: conversation.eventCount,
    historyTruncated: conversation.eventCount > events.length,
  );
}

({String cardType, String cardTitle, String text})
_canonicalGroupPartPresentation(ClientConversationEventPart eventPart) {
  if (eventPart.kind == ConversationEventPartKind.metadata) {
    try {
      final decoded = jsonDecode(eventPart.content);
      if (decoded is Map && decoded['lifecycle'] != null) {
        final stage = decoded['lifecycle'].toString().trim();
        if (const {
          'submitted',
          'accepted',
          'processing',
          'responding',
          'completed',
          'failed',
        }.contains(stage)) {
          return (
            cardType: 'lifecycle',
            cardTitle: 'lifecycle.$stage',
            text: stage,
          );
        }
      }
    } catch (_) {}
  }
  final cardType = switch (eventPart.kind) {
    ConversationEventPartKind.text => '',
    ConversationEventPartKind.reasoning => 'reasoning',
    ConversationEventPartKind.toolCall => 'tool-call',
    ConversationEventPartKind.toolResult => 'tool-result',
    ConversationEventPartKind.artifact => 'artifact',
    ConversationEventPartKind.diagnostic => 'diagnostic',
    ConversationEventPartKind.metadata => 'metadata',
    ConversationEventPartKind.unknown => 'event',
  };
  return (cardType: cardType, cardTitle: '', text: eventPart.content);
}

({String title, String detail}) _canonicalGroupEventPresentation(
  ClientConversationEvent event, {
  required Map<String, ClientConversationMembership> memberships,
  required Map<String, ClientConversationMembership> membershipsByPrincipal,
  required LicoStrings strings,
}) {
  final membershipEvent = event.kind == ConversationEventKind.membershipChanged;
  final title = membershipEvent
      ? strings.groupConversationMembershipChangeTitle
      : strings.groupConversationAvailabilityChangeTitle;
  final metadata = _canonicalGroupEventMetadata(event);
  if (metadata == null) {
    return (
      title: title,
      detail: strings.groupConversationEventDetailsUnavailable,
    );
  }
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  final membership =
      memberships[membershipId] ?? membershipsByPrincipal[principalId];
  final memberLabel = _canonicalGroupEventMemberLabel(
    metadata,
    membership: membership,
    strings: strings,
  );

  if (membershipEvent) {
    final change = (metadata['change'] ?? '').toString().trim();
    final detail = switch (change) {
      'joined' => strings.groupConversationMemberJoined(memberLabel),
      'left' => strings.groupConversationMemberLeft(memberLabel),
      'access-set' => strings.groupConversationMemberAccessSet(
        memberLabel,
        strings.groupConversationAccessLabel(
          (metadata['access'] ?? '').toString(),
        ),
      ),
      _ => strings.groupConversationMemberChangeUnknown(memberLabel),
    };
    return (title: title, detail: detail);
  }

  final availability = strings.groupConversationAvailabilityLabel(
    (metadata['availability'] ?? '').toString(),
  );
  return (
    title: title,
    detail: strings.groupConversationMemberAvailabilitySet(
      memberLabel,
      availability,
    ),
  );
}

Map<String, dynamic>? _canonicalGroupEventMetadata(
  ClientConversationEvent event,
) {
  for (final part in event.parts) {
    if (part.kind != ConversationEventPartKind.metadata ||
        part.content.trim().isEmpty) {
      continue;
    }
    try {
      final decoded = jsonDecode(part.content);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      continue;
    }
  }
  return null;
}

String _canonicalGroupEventMemberLabel(
  Map<String, dynamic> metadata, {
  required ClientConversationMembership? membership,
  required LicoStrings strings,
}) {
  final embedded = (metadata['displayName'] ?? '').toString().trim();
  if (embedded.isNotEmpty) return embedded;
  final principal = membership?.principal;
  final displayName = principal?.displayName.trim() ?? '';
  if (displayName.isNotEmpty) return displayName;
  final agentId = principal?.agentId.trim() ?? '';
  if (agentId.isNotEmpty) return agentId;
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  if (principalId.isNotEmpty) return principalId;
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  if (membershipId.isNotEmpty) return membershipId;
  return strings.groupConversationUnknownMember;
}

class _CanonicalGroupFailureCapsule extends StatelessWidget {
  const _CanonicalGroupFailureCapsule({
    required this.code,
    required this.failureRef,
    required this.copyBlob,
    required this.onCopy,
  });

  final String code;
  final String failureRef;
  final String copyBlob;
  final Future<void> Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    const radius =
        MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        key: const Key('canonical-group-failure'),
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: colors.error, width: 1.25),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  strings.groupConversationFailureCapsule(
                    failureRef.isEmpty ? code : failureRef,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.error,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              LicoIconButton(
                key: const Key('canonical-group-failure-copy'),
                icon: Icon(Icons.copy_outlined, color: colors.error),
                tooltip: strings.copyFailureReport,
                size: LicoIconButtonSize.small,
                shape: LicoIconButtonShape.concentric,
                radius: LicoRadius.nested(radius, 6),
                onPressed: () => unawaited(onCopy(copyBlob)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CanonicalGroupLoadingOrEmpty extends StatelessWidget {
  const _CanonicalGroupLoadingOrEmpty({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator()
          else
            Icon(Icons.groups_2_outlined, size: 30, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            loading
                ? strings.loadingNativeHistories
                : strings.groupConversation,
            style: TextStyle(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _iso(int unixMs) => unixMs <= 0
    ? ''
    : DateTime.fromMillisecondsSinceEpoch(
        unixMs,
        isUtc: true,
      ).toIso8601String();

final class _GroupStrategyProjection {
  const _GroupStrategyProjection({
    required this.revision,
    required this.agentIds,
    required this.runtimeProfiles,
  });

  final String revision;
  final Set<String> agentIds;
  final Map<String, AgentParticipantRuntimeProfile> runtimeProfiles;
}

final class _GroupStrategyPickerCapsule extends StatelessWidget {
  const _GroupStrategyPickerCapsule({
    required this.label,
    required this.strategies,
    required this.selectedRevision,
    required this.onSelected,
    required this.onCleared,
    this.onOpen,
  });

  final String label;
  final List<AdaptiveFlywheelDefinition> strategies;
  final String? selectedRevision;
  final ValueChanged<String> onSelected;
  final VoidCallback onCleared;
  final ValueChanged<String?>? onOpen;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      popoverKey: const Key('canonical-group-strategy-picker-panel'),
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -4),
      maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
      borderRadius: menuRadius,
      wrapInGlass: false,
      cardBuilder: (context, close) {
        return _GroupStrategyGlassOptionCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MessagingGlassMenuItem(
                key: const Key('canonical-group-strategy-option-none'),
                label: strings.automaticAdaptation,
                dense: true,
                selected: selectedRevision == null,
                leading: Icon(
                  Icons.account_tree_outlined,
                  size: 14,
                  color: context.licoColors.textMuted,
                ),
                onTap: () {
                  onCleared();
                  close();
                },
              ),
              if (strategies.isEmpty)
                MessagingGlassMenuItem(
                  label: strings.noAuthorizedStrategies,
                  dense: true,
                  enabled: false,
                )
              else
                for (final strategy in strategies)
                  _GroupStrategyGlassMenuItem(
                    key: Key(
                      'canonical-group-strategy-option-${strategy.revisionDigest}',
                    ),
                    label: strategy.name.trim().isEmpty
                        ? strategy.id
                        : strategy.name,
                    selected: strategy.revisionDigest == selectedRevision,
                    iconColor: context.licoColors.text,
                    accentColor: context.licoColors.accent,
                    editTooltip: strings.edit,
                    editKey: Key(
                      'canonical-group-strategy-edit-${strategy.revisionDigest}',
                    ),
                    onEdit: onOpen == null
                        ? null
                        : () {
                            close();
                            onOpen!(strategy.revisionDigest);
                          },
                    onTap: () {
                      onSelected(strategy.revisionDigest);
                      close();
                    },
                  ),
            ],
          ),
        );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return _GroupStrategyPickerTrigger(
              label: label,
              open: open,
              onTap: onOpen == null
                  ? toggle
                  : () {
                      close();
                      onOpen!(selectedRevision);
                    },
            );
          },
    );
  }
}

final class _GroupStrategyGlassOptionCard extends MessagingGlassOptionCard {
  const _GroupStrategyGlassOptionCard({required super.child})
    : super(
        constraints: const BoxConstraints(
          minWidth: 156,
          maxWidth: 240,
          maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
      );
}

final class _GroupStrategyGlassMenuItem extends MessagingGlassMenuItem {
  _GroupStrategyGlassMenuItem({
    super.key,
    required super.label,
    required bool selected,
    required Color iconColor,
    required Color accentColor,
    required String editTooltip,
    required Key editKey,
    required VoidCallback? onEdit,
    required VoidCallback onTap,
  }) : super(
         selected: selected && onEdit == null,
         dense: true,
         leading: Icon(Icons.account_tree_outlined, size: 14, color: iconColor),
         trailing: onEdit == null
             ? null
             : _GroupStrategyOptionTrailing(
                 selected: selected,
                 accentColor: accentColor,
                 editTooltip: editTooltip,
                 editKey: editKey,
                 onEdit: onEdit,
               ),
         onTap: onTap,
       );
}

final class _GroupStrategyOptionTrailing extends StatelessWidget {
  const _GroupStrategyOptionTrailing({
    required this.selected,
    required this.accentColor,
    required this.editTooltip,
    required this.editKey,
    required this.onEdit,
  });

  final bool selected;
  final Color accentColor;
  final String editTooltip;
  final Key editKey;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected) ...[
          Icon(Icons.check_rounded, size: 15, color: accentColor),
          const SizedBox(width: 3),
        ],
        LicoIconButton(
          key: editKey,
          icon: const Icon(Icons.edit_outlined),
          tooltip: editTooltip,
          size: LicoIconButtonSize.small,
          onPressed: onEdit,
        ),
      ],
    );
  }
}

final class _GroupStrategyPickerTrigger extends StatelessWidget {
  const _GroupStrategyPickerTrigger({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Semantics(
      button: true,
      label: strings.automaticAdaptation,
      child: AppleGlassSurface(
        borderRadius: kComposerCapsuleBorderRadius,
        fillAlpha: colors.isDark ? 22 : 10,
        child: InkWell(
          key: const Key('canonical-group-strategy-picker'),
          onTap: onTap,
          borderRadius: kComposerCapsuleBorderRadius,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 15,
                  color: colors.primaryStrong,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text.withAlpha(235),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.08,
                      height: 1.15,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 15,
                  color: colors.textMuted.withAlpha(160),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _AssistantToggleButton extends StatelessWidget {
  const _AssistantToggleButton({
    required this.active,
    required this.configured,
    required this.onTap,
  });

  final bool active;
  final bool configured;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final enabled = active && configured;
    final tooltip = !configured
        ? strings.configureAssistantTooltip
        : enabled
        ? strings.assistantActiveTooltip
        : strings.assistantPausedTooltip;
    return SizedBox.square(
      key: const Key('canonical-group-assistant-control'),
      dimension: 40,
      child: Tooltip(
        message: tooltip,
        waitDuration: LicoMotion.tooltipWait,
        child: Semantics(
          button: true,
          toggled: enabled,
          label: tooltip,
          child: Material(
            color: enabled ? colors.accent : colors.surfaceRaised,
            shape: CircleBorder(
              side: BorderSide(
                color: enabled ? colors.accent : colors.line,
                width: 1,
              ),
            ),
            child: InkWell(
              key: const Key('canonical-group-assistant-toggle'),
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Center(
                child: AssistantSparklesIcon(
                  color: enabled ? colors.textOnAccent : colors.textMuted,
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
