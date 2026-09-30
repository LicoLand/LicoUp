import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/assistant_configuration_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

/// The conversation composer re-parented into the Desktop bottom bar. Sends
/// through the same conversation intents as the in-workspace composer; the
/// Desktop shell hides the workspace's internal composer while this is
/// hosted. When [expanded] is true (the left pane is collapsed), the
/// composer carries the Assistant and Adaptive Flywheel capsules in a row
/// that pops in above the field, and the canonical pane suppresses its own
/// copies through `LayoutExternalComposerScope.hostedCapsules`.
final class DockConversationComposer extends StatefulWidget {
  const DockConversationComposer({
    super.key,
    required this.agents,
    required this.conversation,
    required this.expanded,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final bool expanded;

  @override
  State<DockConversationComposer> createState() =>
      _DockConversationComposerState();
}

final class _DockConversationComposerState
    extends State<DockConversationComposer> {
  /// Session-scoped assistant participation, mirroring the in-pane capsule's
  /// per-conversation toggle so the docked composer's sends honor it.
  final Map<String, bool> _assistantActiveByConversation = <String, bool>{};

  /// The runtime-backed plane port this dock reads.
  ///
  /// Bound from the surrounding container once and kept for the dock's life:
  /// remounting the dock reuses the same port instance, so it can neither open
  /// a second source nor revive a withdrawn plane.
  ConversationSourcePort? _boundPort;
  final List<StreamSubscription<Object?>> _planeReads =
      <StreamSubscription<Object?>>[];
  ComposerProjection? _composer;
  PersistentTurnProjection? _turns;
  ConversationAttachmentsProjection? _attachments;
  ConversationProjection? _root;
  CanonicalConversationProjection? _canonical;

  ConversationBinding get conversation => widget.conversation;
  AgentsBinding get agents => widget.agents;

  @override
  void dispose() {
    _unbindPlanes();
    super.dispose();
  }

  void _bindPlanes(ConversationSourcePort port) {
    if (identical(_boundPort, port)) return;
    _unbindPlanes();
    _boundPort = port;
    _composer = port.composer.visibleValue;
    _turns = port.persistentTurns.visibleValue;
    _attachments = port.attachments.visibleValue;
    _root = port.projection.visibleValue;
    _canonical = port.canonicalEvents.visibleValue;
    _planeReads
      ..add(
        port.composer.reads.listen(
          (read) => _applyPlane(() => _composer = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.persistentTurns.reads.listen(
          (read) => _applyPlane(() => _turns = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.attachments.reads.listen(
          (read) => _applyPlane(() => _attachments = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.projection.reads.listen(
          (read) => _applyPlane(() => _root = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.canonicalEvents.reads.listen(
          (read) => _applyPlane(() => _canonical = _visiblePlaneValue(read)),
        ),
      );
  }

  void _unbindPlanes() {
    for (final subscription in _planeReads) {
      unawaited(subscription.cancel());
    }
    _planeReads.clear();
    _boundPort = null;
  }

  void _applyPlane(VoidCallback mutate) {
    if (!mounted) return;
    setState(mutate);
  }

  static T? _visiblePlaneValue<T>(ConversationPlaneRead<T> read) =>
      read is ConversationPlaneVisible<T> ? read.value : null;

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

  Future<void> _openAssistantConfiguration() async {
    await showAssistantConfigurationDialog(
      context,
      conversation: widget.conversation,
      agents: widget.agents,
    );
    if (!mounted) return;
    widget.conversation.intents.send(const RefreshCanonicalAssistantProfile());
  }

  @override
  Widget build(BuildContext context) {
    // The dock reads the conversation planes the runtime admitted, never the
    // producer's raw projections: a withdrawn plane stays invisible here, and
    // the agents catalog it enriches itself with comes from its own source.
    _bindPlanes(conversationSourcePortOf(context));
    final composer = _composer;
    if (composer == null) {
      return const SizedBox.shrink();
    }
    return AsyncRegion<AgentsProjection, IntentSink<AgentsIntent>>(
      source: agentsCatalogProjectionProvider,
      actions: agents.intents,
      data: (context, agentsProjection, _) => _buildComposer(
        context,
        composer: composer,
        turns: _turns,
        attachments: _attachments,
        root: _root,
        canonical: _canonical,
        agentsProjection: agentsProjection,
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context, {
    required ComposerProjection composer,
    required PersistentTurnProjection? turns,
    required ConversationAttachmentsProjection? attachments,
    required ConversationProjection? root,
    required CanonicalConversationProjection? canonical,
    required AgentsProjection agentsProjection,
  }) {
    final strings = LicoStrings.of(context);
    final memberships =
        turns?.memberships ?? const <MembershipTurnProjection>[];
    final turn = memberships.isEmpty ? null : memberships.first;
    final turnActive =
        turn?.phase == PersistentTurnPhase.running ||
        turn?.phase == PersistentTurnPhase.waiting;

    final authority = root?.authority;
    final canonicalConversation =
        authority == ConversationAuthority.canonicalConversation
        ? canonical?.conversation
        : null;

    final String targetLabel;
    final bool enabled;
    final bool busy;
    final Future<bool> Function(String) onSend;
    final Future<void> Function()? onCancel;
    final VoidCallback? onSlashNewConversation;
    final List<String> modelOptions;
    final String selectedModel;
    final String defaultModel;
    final List<String> reasoningEffortOptions;
    final String selectedReasoningEffort;
    final String defaultReasoningEffort;
    final List<TargetCandidate> mentionTargets;
    final Map<String, String> mentionLabels;

    if (canonicalConversation != null && attachments != null) {
      final group = canonicalConversation;
      mentionLabels = <String, String>{
        for (final membership in group.activeAgentMemberships)
          membership.principal.agentId: membership.principal.displayName,
      };
      mentionTargets = agentsProjection.targetDetails
          .where((target) => mentionLabels.containsKey(target.target))
          .toList(growable: false);
      targetLabel = group.title.trim().isNotEmpty
          ? group.title.trim()
          : strings.groupConversation;
      enabled =
          group.localOwnerMembership != null &&
          memberships.every((membership) => membership.inputEnabled);
      busy = canonical!.sending || turnActive;
      onSend = (content) => _sendCanonical(
        conversation: group,
        composer: composer,
        attachments: attachments,
        content: content,
      );
      final cancellable = memberships
          .where((membership) => membership.cancelEnabled)
          .toList(growable: false);
      onCancel = cancellable.length == 1
          ? () async => conversation.intents.send(
              InterruptConversationTurn(
                canonical.conversationId,
                cancellable.single.membershipId,
              ),
            )
          : null;
      onSlashNewConversation = null;
      modelOptions = const <String>[];
      selectedModel = '';
      defaultModel = '';
      reasoningEffortOptions = const <String>[];
      selectedReasoningEffort = '';
      defaultReasoningEffort = '';
    } else if (authority != null &&
        authority != ConversationAuthority.canonicalConversation) {
      TargetCandidate? selectedTarget;
      for (final target in agentsProjection.targetDetails) {
        if (target.id == agentsProjection.selectedAgentId ||
            target.target == agentsProjection.selectedAgentId) {
          selectedTarget = target;
          break;
        }
      }
      targetLabel = selectedTarget == null
          ? ''
          : agentConversationTargetDisplayName(selectedTarget);
      enabled =
          selectedTarget != null &&
          composer.inputEnabled &&
          (turn?.inputEnabled ?? true);
      busy = turnActive;
      onSend = (content) async {
        conversation.intents.send(
          PostConversationMessage(
            conversationId: composer.conversationId,
            content: content,
            addressedMembershipIds: [
              if (turn?.membershipId.trim().isNotEmpty == true)
                turn!.membershipId,
            ],
            dispatchCanonical: false,
          ),
        );
        return true;
      };
      onCancel = turn?.cancelEnabled == true
          ? () async => conversation.intents.send(
              InterruptConversationTurn(
                composer.conversationId,
                turn!.membershipId,
              ),
            )
          : null;
      onSlashNewConversation = selectedTarget == null
          ? null
          : () => conversation.intents.send(const StartConversationSession());
      modelOptions = composer.modelOptions;
      selectedModel = composer.selectedModel;
      defaultModel = composer.defaultModel;
      reasoningEffortOptions = composer.reasoningEffortOptions;
      selectedReasoningEffort = composer.selectedReasoningEffort;
      defaultReasoningEffort = composer.defaultReasoningEffort;
      mentionTargets = const <TargetCandidate>[];
      mentionLabels = const <String, String>{};
    } else {
      // The conversation identity or its attachment transport is not visible:
      // the admitted draft stays readable, but the dock neither fabricates an
      // identity nor sends through a plane the runtime has not authorized.
      targetLabel = '';
      enabled = false;
      busy = false;
      onSend = (_) async => false;
      onCancel = null;
      onSlashNewConversation = null;
      modelOptions = const <String>[];
      selectedModel = '';
      defaultModel = '';
      reasoningEffortOptions = const <String>[];
      selectedReasoningEffort = '';
      defaultReasoningEffort = '';
      mentionTargets = const <TargetCandidate>[];
      mentionLabels = const <String, String>{};
    }

    final composerWidget = RuntimeMessageComposer(
      // Same keying rule as the in-workspace composer: a conversation switch
      // starts a fresh composer state seeded from that conversation's draft.
      key: ValueKey<String>('dock-composer-${composer.conversationId}'),
      targetLabel: targetLabel,
      initialDraft: composer.draft,
      hasAttachments: attachments?.attachments.isNotEmpty ?? false,
      busy: busy,
      enabled: enabled,
      cancelEnabled: onCancel != null,
      modelOptions: modelOptions,
      selectedModel: selectedModel,
      reasoningEffortOptions: reasoningEffortOptions,
      selectedReasoningEffort: selectedReasoningEffort,
      onModelChanged: (model) =>
          conversation.intents.send(SelectConversationModel(model)),
      onReasoningEffortChanged: (effort) =>
          conversation.intents.send(SelectConversationReasoningEffort(effort)),
      onDraftChanged: (draft) => conversation.intents.send(
        UpdateConversationDraft(composer.conversationId, draft),
      ),
      onSend: onSend,
      onSlashNewConversation: onSlashNewConversation,
      onCancel: onCancel,
      defaultModel: defaultModel,
      defaultReasoningEffort: defaultReasoningEffort,
      showRuntimeSettings: false,
      // Resting (left pane open): a compact single-row capsule pinned to the
      // icon strip's height. Expanded (left collapsed): the floating capsule
      // grows upward with its lines.
      floatingMatteCapsule: widget.expanded,
      fixedHeight: widget.expanded ? null : DesktopDesktopMetrics.dockBarHeight,
      // The Desktop bottom bar positions the composer; the capsule must sit
      // flush on the bar's grid.
      outerPadding: EdgeInsets.zero,
      onPasteImage: (attachments?.acceptsImages ?? false)
          ? () async {
              conversation.intents.send(
                PasteConversationAttachment(composer.conversationId),
              );
              return true;
            }
          : null,
      mentionTargets: mentionTargets,
      mentionLabels: mentionLabels,
    );
    final group = canonicalConversation;
    // The capsule row decorates the composer with canonical plane content; an
    // invisible plane only drops the decoration, never the admitted input.
    if (!widget.expanded ||
        group == null ||
        canonical == null ||
        turns == null) {
      return composerWidget;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DockComposerCapsuleRow(
          key: ValueKey<String>('dock-composer-capsules-${group.id}'),
          conversation: group,
          canonical: canonical,
          turns: turns,
          agentsProjection: agentsProjection,
          assistantActive: _assistantActive(group),
          onToggleAssistant: () => _toggleAssistant(group),
          onEditAssistant: () => unawaited(_openAssistantConfiguration()),
          onOpenFlywheel: (revision) => unawaited(
            showAdaptiveFlywheelDialog(
              context,
              conversation: widget.conversation,
              agents: widget.agents,
              initialRevision: revision ?? '',
            ),
          ),
        ),
        const SizedBox(height: 6),
        composerWidget,
      ],
    );
  }

  Future<bool> _sendCanonical({
    required ClientConversation conversation,
    required ComposerProjection composer,
    required ConversationAttachmentsProjection attachments,
    required String content,
  }) async {
    if (attachments.attachments.isNotEmpty && !attachments.acceptsImages) {
      this.conversation.intents.send(
        SurfaceConversationFailure(
          stage: 'send',
          reasonCode: 'attachment_transport_unsupported',
          conversationId: conversation.id,
        ),
      );
      return false;
    }
    this.conversation.intents.send(
      PostConversationMessage(
        conversationId: composer.conversationId,
        content: content,
        addressedMembershipIds: [
          for (final membership in conversation.activeAgentMemberships)
            membership.id,
        ],
        dispatchCanonical: conversation.assistantMembership != null,
        suppressAssistant: !_assistantActive(conversation),
      ),
    );
    return true;
  }
}

/// The expanded dock composer's capsule row: the Assistant identity capsule
/// and the Adaptive Flywheel capsule, popping in above the field with a short
/// rise-and-fade when the row appears.
final class _DockComposerCapsuleRow extends StatelessWidget {
  const _DockComposerCapsuleRow({
    super.key,
    required this.conversation,
    required this.canonical,
    required this.turns,
    required this.agentsProjection,
    required this.assistantActive,
    required this.onToggleAssistant,
    required this.onEditAssistant,
    required this.onOpenFlywheel,
  });

  final ClientConversation conversation;
  final CanonicalConversationProjection canonical;
  final PersistentTurnProjection turns;
  final AgentsProjection agentsProjection;
  final bool assistantActive;
  final VoidCallback onToggleAssistant;
  final VoidCallback onEditAssistant;
  final ValueChanged<String?> onOpenFlywheel;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final allTargets = agentsProjection.targetDetails;
    final participantTargets = resolveCanonicalGroupParticipantTargets(
      conversation,
      allTargets,
    );
    final membership = conversation.assistantMembership;
    TargetCandidate? assistantTarget;
    if (membership != null) {
      for (final target
          in participantTargets.isEmpty ? allTargets : participantTargets) {
        if (target.target == membership.principal.agentId) {
          assistantTarget = target;
          break;
        }
      }
    }
    final assistantLabel = membership == null
        ? strings.assistantNeedsConfigurationStatus
        : canonicalGroupAssistantCapsuleLabel(
            membership,
            assistantTarget ??
                TargetCandidate(
                  target: membership.principal.agentId,
                  label: membership.principal.displayName,
                  kind: 'agent',
                  status: TargetCandidateStatus.unavailable,
                  configured: false,
                  confidence: 0,
                  adapterStatus: 'runtime-unavailable',
                ),
          );
    final status = canonicalGroupAssistantStatus(
      conversation: conversation,
      assistantActive: assistantActive,
      canonical: canonical,
      turns: turns,
    );
    final revision = conversation.strategyRevision.trim();
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: LicoMotion.medium,
      curve: LicoMotion.decelerate,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: child,
        ),
      ),
      child: Row(
        children: [
          AssistantToggleButton(
            active: assistantActive,
            configured: membership != null,
            label: assistantLabel,
            status: status,
            onTap: onToggleAssistant,
            onEdit: onEditAssistant,
          ),
          const SizedBox(width: 8),
          GroupStrategyPickerCapsule(
            selectedRevision: revision.isEmpty ? null : revision,
            onOpen: onOpenFlywheel,
          ),
        ],
      ),
    );
  }
}
