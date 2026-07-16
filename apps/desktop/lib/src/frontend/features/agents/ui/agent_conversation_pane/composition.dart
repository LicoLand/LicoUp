import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane/actions.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane/header.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_policy_controls.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';

class AgentConversationActivePane extends StatelessWidget {
  const AgentConversationActivePane({
    super.key,
    required this.controller,
    required this.target,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.framed = true,
    this.showSidebarToggle = true,
  });

  final ClientController controller;
  final TargetCandidate target;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool framed;
  final bool showSidebarToggle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.activeConversationListenable,
      builder: (context, _) => _ConversationPane(
        controller: controller,
        target: target,
        session: controller.selectedConversationSession,
        historyCollapsed: historyCollapsed,
        onToggleHistory: onToggleHistory,
        collapseHistoryTooltip: collapseHistoryTooltip,
        expandHistoryTooltip: expandHistoryTooltip,
        framed: framed,
        showSidebarToggle: showSidebarToggle,
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.controller,
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.framed = true,
    this.showSidebarToggle = true,
  });

  final ClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool framed;
  final bool showSidebarToggle;

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);
    final strings = LicoStrings.of(context);
    final orchestrationSelected =
        controller.selectedConversationIsOrchestration;
    final composerEnabled = orchestrationSelected
        ? controller.agentOrchestrationPolicyConfigured &&
              controller.orchestrationAvailableTargets.isNotEmpty
        : target.canRelayRuntime;
    final gateReasonCode = orchestrationSelected
        ? (!controller.agentOrchestrationPolicyConfigured
              ? 'orchestration_policy_required'
              : 'orchestration_targets_unavailable')
        : (controller.lastError.trim().isNotEmpty
              ? controller.lastError.trim()
              : target.conversationSendGateReason);
    final gateCopy = conversationParityDisclosureCopy(
      strings: strings,
      reasonCode: gateReasonCode,
      orchestration:
          orchestrationSelected &&
          !composerEnabled &&
          !controller.agentOrchestrationPolicyConfigured,
    );
    final disabledHint = composerEnabled ? '' : gateCopy.reasonLabel;
    final composer = RuntimeMessageComposer(
      targetLabel: target.label,
      initialDraft: controller.conversationComposerDraft,
      busy: controller.isSendingConversationMessage,
      enabled: composerEnabled,
      disabledHint: disabledHint,
      modelOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationModelOptions,
      selectedModel: orchestrationSelected
          ? ''
          : controller.selectedConversationModel,
      reasoningEffortOptions: orchestrationSelected
          ? const []
          : controller.selectedConversationReasoningEffortOptions,
      selectedReasoningEffort: orchestrationSelected
          ? ''
          : controller.selectedConversationReasoningEffort,
      onModelChanged: controller.selectConversationModel,
      onReasoningEffortChanged: controller.selectConversationReasoningEffort,
      onDraftChanged: controller.updateConversationComposerDraft,
      onSend: (text) => unawaited(controller.sendConversationMessage(text)),
    );
    final sendGate = composerEnabled
        ? null
        : ConversationParitySendGateBanner(
            copy: gateCopy,
            onUnblock: switch (gateCopy.unblockAction) {
              ConversationParityUnblockAction.rescanAgents => () => unawaited(
                controller.scanTargets(),
              ),
              ConversationParityUnblockAction.editPolicy => () => unawaited(
                showAgentOrchestrationPolicyEditor(context, controller),
              ),
              null => null,
            },
          );
    if (mobileClient) {
      return Column(
        children: [
          if (!orchestrationSelected)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConversationParityDisclosurePanel(
                  target: target,
                  compact: true,
                ),
              ),
            ),
          Expanded(
            child: AgentConversationMessageList(
              loading: controller.isLoadingConversations,
              session: session,
              target: target,
              turnActive: controller.isSendingConversationMessage,
              liveMessages: controller.selectedLiveConversationMessages,
            ),
          ),
          ?sendGate,
          MobileComposerSurface(child: composer),
        ],
      );
    }
    final content = Column(
      children: [
        ConversationPaneHeader(
          controller: controller,
          target: target,
          session: session,
          historyCollapsed: historyCollapsed,
          onToggleHistory: onToggleHistory,
          collapseHistoryTooltip: collapseHistoryTooltip,
          expandHistoryTooltip: expandHistoryTooltip,
          showSidebarToggle: showSidebarToggle,
        ),
        const Divider(height: 1),
        Expanded(
          child: AgentConversationMessageList(
            loading: controller.isLoadingConversations,
            session: session,
            target: target,
            turnActive: controller.isSendingConversationMessage,
            liveMessages: controller.selectedLiveConversationMessages,
          ),
        ),
        ?sendGate,
        const Divider(height: 1),
        composer,
      ],
    );
    if (!framed) {
      return content;
    }
    return PanelFrame(child: content);
  }
}
