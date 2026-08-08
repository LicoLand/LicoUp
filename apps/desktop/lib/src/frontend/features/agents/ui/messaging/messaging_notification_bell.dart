import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
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

/// The messaging chrome-band notification bell: a badge when tab activity,
/// Gateway lifecycle, or operation feedback is present. New operation notices
/// auto-open the panel, which is pinned to the window's top-right corner.
class MessagingNotificationBell extends StatefulWidget {
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
  State<MessagingNotificationBell> createState() =>
      _MessagingNotificationBellState();
}

class _MessagingNotificationBellState extends State<MessagingNotificationBell> {
  final GlobalKey<MessagingHoverPopoverState> _popoverKey =
      GlobalKey<MessagingHoverPopoverState>();
  int _seenOperationRevision = 0;
  LlmGatewayNoticeKind? _seenGatewayNotice;

  @override
  void initState() {
    super.initState();
    _seenOperationRevision =
        widget.controller.messagingNotificationCenter.revision;
    _seenGatewayNotice = widget.controller.llmGatewayLifecycleController.notice;
    widget.controller.messagingNotificationCenter.addListener(
      _onNotificationSourcesChanged,
    );
    widget.controller.llmGatewayLifecycleController.addListener(
      _onNotificationSourcesChanged,
    );
  }

  @override
  void didUpdateWidget(covariant MessagingNotificationBell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.messagingNotificationCenter.removeListener(
      _onNotificationSourcesChanged,
    );
    oldWidget.controller.llmGatewayLifecycleController.removeListener(
      _onNotificationSourcesChanged,
    );
    widget.controller.messagingNotificationCenter.addListener(
      _onNotificationSourcesChanged,
    );
    widget.controller.llmGatewayLifecycleController.addListener(
      _onNotificationSourcesChanged,
    );
  }

  @override
  void dispose() {
    widget.controller.messagingNotificationCenter.removeListener(
      _onNotificationSourcesChanged,
    );
    widget.controller.llmGatewayLifecycleController.removeListener(
      _onNotificationSourcesChanged,
    );
    super.dispose();
  }

  void _onNotificationSourcesChanged() {
    if (!mounted) return;
    final center = widget.controller.messagingNotificationCenter;
    final gatewayNotice =
        widget.controller.llmGatewayLifecycleController.notice;
    final operationArrived = center.revision > _seenOperationRevision;
    final gatewayArrived =
        gatewayNotice != null && gatewayNotice != _seenGatewayNotice;
    if (operationArrived) {
      _seenOperationRevision = center.revision;
    }
    if (gatewayArrived) {
      _seenGatewayNotice = gatewayNotice;
    }
    if (operationArrived || gatewayArrived) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _popoverKey.currentState?.openPinned();
      });
    }
    setState(() {});
  }

  List<(TargetCandidate, AgentConversationTabActivity)> _activeAgents() {
    return [
      for (final target in widget.controller.scannedTargets)
        if (target.isConversationAgent &&
            widget.controller.conversationTabActivityFor(target.target) !=
                AgentConversationTabActivity.none)
          (target, widget.controller.conversationTabActivityFor(target.target)),
    ];
  }

  Future<void> _openConversation(
    TargetCandidate agent,
    VoidCallback closePopover,
  ) async {
    closePopover();
    widget.controller.selectSection(ClientSection.agents);
    widget.onCloseAuxChromePanel?.call();
    final sessions = sortConversationSessionsByUpdatedAt(
      widget.controller.conversationSessionsByAgent[agent.target] ??
          widget.controller.conversationSessionsByAgent[agent.target] ??
          const [],
    );
    if (widget.controller.selectedConversationAgentId != agent.target) {
      await widget.controller.selectConversationAgent(agent.target);
    }
    if (sessions.isNotEmpty) {
      widget.controller.selectConversationSession(sessions.first.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final active = _activeAgents();
    final gatewayNotice =
        widget.controller.llmGatewayLifecycleController.notice;
    final operationNotices =
        widget.controller.messagingNotificationCenter.items;
    final badgeColor =
        gatewayNotice != null ||
            widget.controller.messagingNotificationCenter.hasWarningOrFailure ||
            active.any(
              (entry) => entry.$2 == AgentConversationTabActivity.needsApproval,
            )
        ? colors.warning
        : active.isNotEmpty || operationNotices.isNotEmpty
        ? colors.accent
        : null;
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return MessagingHoverPopover(
      key: _popoverKey,
      popoverKey: const Key('messaging-notification-bell-panel'),
      width: 300,
      maxHeight: 360,
      borderRadius: menuRadius,
      anchorToWindowTopRight: true,
      windowTopInset: MessagingDesktopMetrics.topBandExtent + 4,
      windowEdgeInset: 10,
      cardBuilder: (context, close) {
        return active.isEmpty &&
                gatewayNotice == null &&
                operationNotices.isEmpty
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
                        controller:
                            widget.controller.llmGatewayLifecycleController,
                      ),
                    for (final notice in operationNotices)
                      _MessagingOperationNotificationRow(
                        key: ValueKey<String>(
                          'messaging-operation-notification-${notice.id}',
                        ),
                        item: notice,
                        onDismiss: () => widget
                            .controller
                            .messagingNotificationCenter
                            .dismiss(notice.id),
                      ),
                    for (final (agent, activity) in active)
                      _MessagingNotificationRow(
                        key: ValueKey<String>(
                          'messaging-notification-item-${agent.target}',
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

/// Operation-feedback row for the chrome notification center.
final class _MessagingOperationNotificationRow extends StatelessWidget {
  const _MessagingOperationNotificationRow({
    super.key,
    required this.item,
    required this.onDismiss,
  });

  final MessagingNotificationItem item;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final message = item.messageForLocale(chinese: chinese);
    final iconColor = switch (item.tone) {
      MessagingNotificationTone.failure ||
      MessagingNotificationTone.warning => colors.warning,
      MessagingNotificationTone.success => colors.accent,
      MessagingNotificationTone.info => colors.textMuted,
    };
    final icon = switch (item.tone) {
      MessagingNotificationTone.failure ||
      MessagingNotificationTone.warning => Icons.warning_amber_rounded,
      MessagingNotificationTone.success => Icons.check_circle_outline_rounded,
      MessagingNotificationTone.info => Icons.info_outline_rounded,
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: Padding(
        key: Key('messaging-operation-notification-item-${item.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: Key('messaging-operation-notification-dismiss-${item.id}'),
              tooltip: chinese ? '关闭' : 'Dismiss',
              onPressed: onDismiss,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: Icon(
                Icons.close_rounded,
                size: 16,
                color: colors.textMuted,
              ),
            ),
          ],
        ),
      ),
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
