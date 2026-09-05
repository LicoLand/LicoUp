import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Test-only bridge that keeps existing controller fixtures while production
/// renderers accept semantic bindings exclusively.
class AgentConversationWorkspaceFixture extends StatefulWidget {
  const AgentConversationWorkspaceFixture({
    super.key,
    required this.controller,
    required this.targets,
    required this.scanning,
    required this.adding,
    required this.onAddTarget,
    this.onSearch,
    this.allowManualTargetActions = true,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final VoidCallback? onSearch;
  final bool allowManualTargetActions;

  @override
  State<AgentConversationWorkspaceFixture> createState() =>
      _AgentConversationWorkspaceFixtureState();
}

class _AgentConversationWorkspaceFixtureState
    extends State<AgentConversationWorkspaceFixture> {
  late final AgentsFeatureComposition _agents;
  late final ConversationFeatureComposition _conversation;
  late final MobileRelayFeatureComposition _relay;

  @override
  void initState() {
    super.initState();
    _agents = AgentsFeatureComposition(widget.controller);
    _conversation = ConversationFeatureComposition(widget.controller);
    _relay = MobileRelayFeatureComposition(
      relay: widget.controller.mobileRelayController,
      secureMesh: widget.controller.secureMeshController,
      homeLayout: widget.controller.mobileHomeLayoutController,
      readMobileRuntime: () => widget.controller.mobileClientRuntimePlatform,
    );
  }

  @override
  void didUpdateWidget(covariant AgentConversationWorkspaceFixture oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      identical(oldWidget.controller, widget.controller),
      'AgentConversationWorkspaceFixture does not replace its controller.',
    );
  }

  @override
  void dispose() {
    unawaited(
      Future.wait<void>([
        _agents.close(),
        _conversation.close(),
        _relay.dispose(),
      ]),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = _conversation.binding;
    return AgentConversationWorkspace(
      agents: AgentsBinding(
        projection: _FixtureAgentsProjectionSource(
          delegate: _agents.binding.projection,
          targets: widget.targets,
          scanning: widget.scanning,
          adding: widget.adding,
        ),
        intents: _agents.binding.intents,
        effects: _agents.binding.effects,
      ),
      conversation: ConversationBinding(
        projection: conversation.projection,
        nativeCatalog: conversation.nativeCatalog,
        canonicalEvents: conversation.canonicalEvents,
        persistentTurns: _FixturePersistentTurnsProjectionSource(
          delegate: conversation.persistentTurns,
          controller: widget.controller,
        ),
        composer: conversation.composer,
        attachments: conversation.attachments,
        tabActivity: conversation.tabActivity,
        notifications: conversation.notifications,
        archive: conversation.archive,
        intents: conversation.intents,
        effects: conversation.effects,
      ),
      relay: _relay.binding,
      onAddTarget: widget.onAddTarget,
      onSearch: widget.onSearch,
      allowManualTargetActions: widget.allowManualTargetActions,
    );
  }
}

/// Preserves legacy fixture seeding without making the renderer consume the
/// controller mirror. Production still projects only ConversationStateHolder.
final class _FixturePersistentTurnsProjectionSource
    implements ProjectionSource<PersistentTurnProjection> {
  const _FixturePersistentTurnsProjectionSource({
    required ProjectionSource<PersistentTurnProjection> delegate,
    required ClientController controller,
  }) : _delegate = delegate,
       _controller = controller;

  final ProjectionSource<PersistentTurnProjection> _delegate;
  final ClientController _controller;

  @override
  PersistentTurnProjection get current => _overlay(_delegate.current);

  @override
  Stream<ProjectionUpdate<PersistentTurnProjection>> get changes =>
      _delegate.changes.map(
        (update) => ProjectionUpdate<PersistentTurnProjection>(
          _overlay(update.value),
          trace: update.trace,
        ),
      );

  PersistentTurnProjection _overlay(PersistentTurnProjection source) {
    if (source.memberships.isNotEmpty) return source;
    final scopeKey = _controller.conversationComposerScopeKey;
    final messages =
        _controller.liveConversationMessagesByScope[scopeKey] ?? const [];
    if (messages.isEmpty) return source;
    final agentId = _controller.selectedConversationAgentId;
    return PersistentTurnProjection(
      conversationId: scopeKey,
      memberships: [
        MembershipTurnProjection(
          membershipId: agentId,
          agentLabel: _controller.selectedConversationAgent?.label ?? agentId,
          phase: _controller.isSendingConversationMessage
              ? PersistentTurnPhase.running
              : PersistentTurnPhase.completed,
          inputEnabled: !_controller.isSendingConversationMessage,
          liveParts: const [],
          messages: messages,
          participantAgentId: agentId,
          cancelEnabled: _controller.isSendingConversationMessage,
        ),
      ],
    );
  }
}

final class _FixtureAgentsProjectionSource
    implements ProjectionSource<AgentsProjection> {
  const _FixtureAgentsProjectionSource({
    required ProjectionSource<AgentsProjection> delegate,
    required List<TargetCandidate> targets,
    required bool scanning,
    required bool adding,
  }) : _delegate = delegate,
       _targets = targets,
       _scanning = scanning,
       _adding = adding;

  final ProjectionSource<AgentsProjection> _delegate;
  final List<TargetCandidate> _targets;
  final bool _scanning;
  final bool _adding;

  @override
  AgentsProjection get current => _overlay(_delegate.current);

  @override
  Stream<ProjectionUpdate<AgentsProjection>> get changes =>
      _delegate.changes.map(
        (update) => ProjectionUpdate<AgentsProjection>(
          _overlay(update.value),
          trace: update.trace,
        ),
      );

  AgentsProjection _overlay(AgentsProjection source) => AgentsProjection(
    targets: [
      for (final target in _targets)
        AgentTargetProjection(
          id: target.target,
          displayName: target.label.trim().isEmpty
              ? target.target
              : target.label,
          available: target.status != 'not-detected',
          pinned: false,
          capabilityLabel: target.conversationSendGateReason.isEmpty
              ? target.status
              : target.conversationSendGateReason,
        ),
    ],
    selectedAgentId: source.selectedAgentId,
    workingDirectoryLabel: source.workingDirectoryLabel,
    phase: _scanning ? PresentationPhase.loading : source.phase,
    targetDetails: _targets,
    mobileRuntime: source.mobileRuntime,
    scanning: _scanning,
    adding: _adding,
    notice: source.notice,
  );
}
