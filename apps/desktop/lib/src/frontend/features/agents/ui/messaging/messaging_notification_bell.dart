import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_intent.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The messaging chrome-band notification center.
///
/// The renderer owns only popover visibility. Gateway lifecycle, operation
/// feedback, native Agent activity, and their auto-reveal revisions arrive as
/// immutable chrome projection facts.
class MessagingNotificationBell extends StatefulWidget {
  const MessagingNotificationBell({
    super.key,
    required this.chrome,
    this.onCloseAuxChromePanel,
  });

  final ChromeBinding chrome;
  final VoidCallback? onCloseAuxChromePanel;

  @override
  State<MessagingNotificationBell> createState() =>
      _MessagingNotificationBellState();
}

class _MessagingNotificationBellState extends State<MessagingNotificationBell> {
  final GlobalKey<MessagingHoverPopoverState> _popoverKey =
      GlobalKey<MessagingHoverPopoverState>();
  late int _seenOperationAutoRevealRevision;
  late int _seenGatewayAutoRevealRevision;

  @override
  void initState() {
    super.initState();
    _resetSeenRevisions();
  }

  @override
  void didUpdateWidget(covariant MessagingNotificationBell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chrome.projection, widget.chrome.projection)) {
      _resetSeenRevisions();
    }
  }

  void _resetSeenRevisions() {
    final projection = widget.chrome.projection.current;
    _seenOperationAutoRevealRevision = projection.operationAutoRevealRevision;
    _seenGatewayAutoRevealRevision = projection.gatewayAutoRevealRevision;
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<ChromeProjection, ChromeProjection>(
      source: widget.chrome.projection,
      select: (projection) => projection,
      builder: (context, projection) => _buildBell(context, projection),
    );
  }

  Widget _buildBell(BuildContext context, ChromeProjection projection) {
    _revealNewNotifications(projection);
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final gateway = projection.gatewayNotification;
    final operationNotices = projection.operationNotifications.isNotEmpty
        ? projection.operationNotifications
        : [
            for (final notice in projection.notifications)
              ChromeOperationNotificationProjection(
                id: notice.id,
                messageChinese: notice.message,
                messageEnglish: notice.message,
                severity: notice.severity,
                reasonCode: notice.reasonCode,
              ),
          ];
    final agentNotices = projection.agentNotifications;
    final warning =
        gateway?.kind == ChromeGatewayNoticeKind.recoveryFailed ||
        operationNotices.any(
          (notice) =>
              notice.severity == PresentationNoticeSeverity.warning ||
              notice.severity == PresentationNoticeSeverity.error,
        ) ||
        agentNotices.any(
          (notice) =>
              notice.activity == AgentConversationTabActivity.needsApproval,
        );
    final hasNotifications =
        gateway != null ||
        operationNotices.isNotEmpty ||
        agentNotices.isNotEmpty;
    final badgeColor = warning
        ? colors.warning
        : hasNotifications
        ? colors.accent
        : null;

    return MessagingHoverPopover(
      key: _popoverKey,
      popoverKey: const Key('messaging-notification-bell-panel'),
      width: 300,
      maxHeight: 360,
      borderRadius: BorderRadius.circular(AppleControlMetrics.menuCornerRadius),
      anchorToWindowTopRight: true,
      windowTopInset: MessagingDesktopMetrics.topBandExtent + 4,
      windowEdgeInset: 10,
      cardBuilder: (context, close) => !hasNotifications
          ? Padding(
              key: const Key('messaging-notification-empty'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
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
                  if (gateway != null)
                    _GatewayNotificationRow(
                      projection: gateway,
                      onRecover: () => widget.chrome.intents.send(
                        const RecoverChromeGateway(),
                      ),
                    ),
                  for (final notice in operationNotices)
                    _OperationNotificationRow(
                      key: ValueKey<String>(
                        'messaging-operation-notification-${notice.id}',
                      ),
                      projection: notice,
                      onDismiss: () => widget.chrome.intents.send(
                        DismissChromeNotification(notice.id),
                      ),
                    ),
                  for (final notice in agentNotices)
                    _AgentNotificationRow(
                      key: ValueKey<String>(
                        'messaging-notification-item-${notice.target.id}',
                      ),
                      projection: notice,
                      onTap: () {
                        close();
                        widget.onCloseAuxChromePanel?.call();
                        final session = notice.session;
                        widget.chrome.intents.send(
                          OpenChromeAgentConversation(
                            agentId: notice.target.id,
                            sessionId: session?.id ?? '',
                            nativeSessionId: session?.nativeSessionId ?? '',
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
      triggerBuilder:
          (context, {required open, required toggle, required close}) =>
              Tooltip(
                message: strings.notifications,
                waitDuration: LicoMotion.tooltipWait,
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
                              key: const Key(
                                'messaging-notification-bell-badge',
                              ),
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
              ),
    );
  }

  void _revealNewNotifications(ChromeProjection projection) {
    final operationArrived =
        projection.operationAutoRevealRevision >
        _seenOperationAutoRevealRevision;
    final gatewayArrived =
        projection.gatewayAutoRevealRevision > _seenGatewayAutoRevealRevision;
    _seenOperationAutoRevealRevision = projection.operationAutoRevealRevision;
    _seenGatewayAutoRevealRevision = projection.gatewayAutoRevealRevision;
    if (!operationArrived && !gatewayArrived) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _popoverKey.currentState?.openPinned();
    });
  }
}

final class _OperationNotificationRow extends StatelessWidget {
  const _OperationNotificationRow({
    super.key,
    required this.projection,
    required this.onDismiss,
  });

  final ChromeOperationNotificationProjection projection;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final message = chinese
        ? projection.messageChinese
        : projection.messageEnglish;
    final iconColor = switch (projection.severity) {
      PresentationNoticeSeverity.warning ||
      PresentationNoticeSeverity.error => colors.warning,
      PresentationNoticeSeverity.success => colors.accent,
      PresentationNoticeSeverity.information => colors.textMuted,
    };
    final icon = switch (projection.severity) {
      PresentationNoticeSeverity.warning ||
      PresentationNoticeSeverity.error => Icons.warning_amber_rounded,
      PresentationNoticeSeverity.success => Icons.check_circle_outline_rounded,
      PresentationNoticeSeverity.information => Icons.info_outline_rounded,
    };
    return Semantics(
      liveRegion: true,
      label: message,
      child: Padding(
        key: Key('messaging-operation-notification-item-${projection.id}'),
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
              key: Key(
                'messaging-operation-notification-dismiss-${projection.id}',
              ),
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

final class _GatewayNotificationRow extends StatelessWidget {
  const _GatewayNotificationRow({
    required this.projection,
    required this.onRecover,
  });

  final ChromeGatewayNotificationProjection projection;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final recovering = projection.kind == ChromeGatewayNoticeKind.recovering;
    final message = recovering
        ? (chinese
              ? 'LLM Gateway 正在自动恢复（${projection.recoveryAttempt}/${projection.maxRecoveryAttempts}）…'
              : 'Recovering LLM Gateway (${projection.recoveryAttempt}/${projection.maxRecoveryAttempts})…')
        : (chinese
              ? 'LLM Gateway 自动恢复失败，诊断已记录。'
              : 'LLM Gateway recovery failed. Diagnostics recorded.');
    return Semantics(
      liveRegion: true,
      label: message,
      child: Padding(
        key: const Key('llm-gateway-notification-item'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (recovering)
              SizedBox.square(
                key: const Key('llm-gateway-recovery-spinner'),
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              )
            else
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: colors.warning,
              ),
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
            if (!recovering) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const Key('llm-gateway-restart-action'),
                onPressed: projection.busy ? null : onRecover,
                child: Text(chinese ? '重试' : 'Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _AgentNotificationRow extends StatelessWidget {
  const _AgentNotificationRow({
    super.key,
    required this.projection,
    required this.onTap,
  });

  final ChromeAgentNotificationProjection projection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final statusColor = switch (projection.activity) {
      AgentConversationTabActivity.needsApproval => colors.warning,
      AgentConversationTabActivity.workFinished => colors.accent,
      AgentConversationTabActivity.none => colors.textMuted,
    };
    final statusText = switch (projection.activity) {
      AgentConversationTabActivity.needsApproval =>
        strings.agentTabNeedsApproval,
      AgentConversationTabActivity.workFinished => strings.agentTabWorkFinished,
      AgentConversationTabActivity.none => '',
    };
    final target = projection.target;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              AgentBrandIcon(
                target: target,
                size: 24,
                iconSize: 16,
                selected: false,
                detected:
                    target.status == TargetCandidateStatus.detected ||
                    target.configured,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  agentConversationTargetDisplayName(target),
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
