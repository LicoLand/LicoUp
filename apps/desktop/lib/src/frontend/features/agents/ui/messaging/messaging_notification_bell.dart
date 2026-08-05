import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The messaging chrome-band notification bell: a badge dot whenever any
/// conversation agent reports tab activity (amber = needs approval, blue =
/// work finished), and a hover card listing the active agents. Selecting an
/// item jumps to the agents destination and opens that agent's most recent
/// conversation. Reads all state from the shared controller — no duplicated
/// activity bookkeeping.
class MessagingNotificationBell extends StatelessWidget {
  const MessagingNotificationBell({
    super.key,
    required this.controller,
    this.onCloseAuxChromePanel,
  });

  final ClientController controller;

  /// Invoked when a notification opens a conversation so an auxiliary chrome
  /// panel (for example the messaging profile page) closes alongside the
  /// destination switch.
  final VoidCallback? onCloseAuxChromePanel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _MessagingNotificationBellBody(
        controller: controller,
        onCloseAuxChromePanel: onCloseAuxChromePanel,
      ),
    );
  }
}

class _MessagingNotificationBellBody extends StatelessWidget {
  const _MessagingNotificationBellBody({
    required this.controller,
    this.onCloseAuxChromePanel,
  });

  final ClientController controller;
  final VoidCallback? onCloseAuxChromePanel;

  List<(TargetCandidate, AgentConversationTabActivity)> _activeAgents() {
    return [
      for (final target in controller.scannedTargets)
        if (target.isConversationAgent &&
            controller.conversationTabActivityFor(target.id) !=
                AgentConversationTabActivity.none)
          (target, controller.conversationTabActivityFor(target.id)),
    ];
  }

  Future<void> _openConversation(
    TargetCandidate agent,
    VoidCallback closePopover,
  ) async {
    closePopover();
    controller.selectSection(ClientSection.agents);
    onCloseAuxChromePanel?.call();
    final sessions = sortConversationSessionsByUpdatedAt(
      controller.conversationSessionsByAgent[agent.id] ??
          controller.conversationSessionsByAgent[agent.target] ??
          const [],
    );
    await controller.selectConversationAgent(agent.id);
    if (sessions.isNotEmpty) {
      controller.selectConversationSession(sessions.first.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final active = _activeAgents();
    final gatewayNotice = controller.llmGatewayLifecycleController.notice;
    final badgeColor =
        gatewayNotice != null ||
            active.any(
              (entry) => entry.$2 == AgentConversationTabActivity.needsApproval,
            )
        ? colors.warning
        : active.isNotEmpty
        ? colors.accent
        : null;
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      popoverKey: const Key('messaging-notification-bell-panel'),
      width: 300,
      maxHeight: 360,
      borderRadius: menuRadius,
      cardBuilder: (context, close) {
        return active.isEmpty && gatewayNotice == null
            ? Padding(
                key: const Key('messaging-notification-empty'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                child: Text(
                  strings.noNotifications,
                  style: TextStyle(color: colors.textMuted, fontSize: 12.5),
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (gatewayNotice != null)
                      LlmGatewayNotificationRow(
                        controller: controller.llmGatewayLifecycleController,
                      ),
                    for (final (agent, activity) in active)
                      _MessagingNotificationRow(
                        key: ValueKey<String>(
                          'messaging-notification-item-${agent.id}',
                        ),
                        agent: agent,
                        activity: activity,
                        onTap: () => unawaited(_openConversation(agent, close)),
                      ),
                  ],
                ),
              );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return Tooltip(
              message: strings.notifications,
              waitDuration: const Duration(milliseconds: 400),
              child: InkWell(
                key: const Key('messaging-notification-bell'),
                onTap: toggle,
                customBorder: const CircleBorder(),
                hoverColor: MessagingDesktopMetrics.chromeControlHover(
                  isDark: colors.isDark,
                ),
                child: SizedBox.square(
                  dimension: 32,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.notifications_none_rounded,
                        size: 19,
                        color: MessagingDesktopMetrics.chromeIconMuted(),
                      ),
                      if (badgeColor != null)
                        Positioned(
                          top: 7,
                          right: 7,
                          child: Container(
                            key: const Key('messaging-notification-bell-badge'),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: badgeColor,
                              border: Border.all(
                                color: colors.background,
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
    );
  }
}

/// Actionable Gateway lifecycle entry mounted inside the real notification
/// menu rather than floating over application content.
final class LlmGatewayNotificationRow extends StatelessWidget {
  const LlmGatewayNotificationRow({super.key, required this.controller});

  final LlmGatewayLifecycleController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final notice = controller.notice;
    if (notice == null) return const SizedBox.shrink();
    final colors = context.licoColors;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final message = switch (notice) {
      LlmGatewayNoticeKind.initializationFailed =>
        chinese ? 'LLM Gateway 本地服务启动失败。' : 'LLM Gateway failed to start.',
      LlmGatewayNoticeKind.unexpectedExit =>
        chinese ? 'LLM Gateway 已意外停止。' : 'LLM Gateway stopped unexpectedly.',
      LlmGatewayNoticeKind.monitorUnavailable =>
        chinese ? '暂时无法确认网关运行状态。' : 'Gateway status is unavailable.',
      LlmGatewayNoticeKind.restartFailed =>
        chinese ? 'LLM Gateway 重启失败。' : 'LLM Gateway failed to restart.',
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: Padding(
        key: const Key('llm-gateway-notification-item'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: colors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('llm-gateway-restart-action'),
              onPressed: controller.busy
                  ? null
                  : () => unawaited(controller.restart()),
              child: Text(
                controller.busy
                    ? chinese
                          ? '重启中…'
                          : 'Restarting…'
                    : chinese
                    ? '重启'
                    : 'Restart',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessagingNotificationRow extends StatelessWidget {
  const _MessagingNotificationRow({
    super.key,
    required this.agent,
    required this.activity,
    required this.onTap,
  });

  final TargetCandidate agent;
  final AgentConversationTabActivity activity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final statusColor = switch (activity) {
      AgentConversationTabActivity.needsApproval => colors.warning,
      AgentConversationTabActivity.workFinished => colors.accent,
      AgentConversationTabActivity.none => colors.textMuted,
    };
    final statusText = switch (activity) {
      AgentConversationTabActivity.needsApproval =>
        strings.agentTabNeedsApproval,
      AgentConversationTabActivity.workFinished => strings.agentTabWorkFinished,
      AgentConversationTabActivity.none => '',
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              AgentBrandIcon(
                target: agent,
                size: 24,
                iconSize: 16,
                selected: false,
                detected: agent.status == 'detected' || agent.configured,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  agentConversationTargetDisplayName(agent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                statusText,
                maxLines: 1,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
