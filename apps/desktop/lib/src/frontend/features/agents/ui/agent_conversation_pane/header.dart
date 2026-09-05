import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_connection_chips.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_layout_metrics.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';

class ConversationPaneHeader extends StatelessWidget {
  const ConversationPaneHeader({
    super.key,
    required this.state,
    required this.actions,
    this.strategy = const AgentsPresentationStrategy.console(),
  });

  final AgentConversationHeaderState state;
  final AgentConversationHeaderActions actions;

  /// Layout-owned presentation strategy. The messaging header variant lands
  /// with the messaging feature step; every style currently renders the
  /// shared console header.
  final AgentsPresentationStrategy strategy;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final sessionTitle = state.session?.title ?? '';
    final headerTitle = historySessionDisplayTitle(
      sessionTitle,
      fallback: agentConversationTargetDisplayName(state.target),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobileClient = isMobileClientPlatform(context);
        final consoleIdentity = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: mobileClient
              ? const <Widget>[]
              : [
                  if (state.showSidebarToggle) ...[
                    AgentsSidebarCollapseControl(
                      key: const Key('agents-workspace-sidebar-collapse'),
                      expanded: !state.historyCollapsed,
                      tooltip: state.historyCollapsed
                          ? state.expandHistoryTooltip
                          : state.collapseHistoryTooltip,
                      onPressed: actions.onToggleHistory,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  ...conversationConnectionChipChildren(
                    target: state.target,
                    opencodeServeState: state.opencodeServeState,
                    showParity: true,
                  ),
                ],
        );
        final identity = switch (strategy.messageStyle) {
          AgentsMessageStyle.documentTranscript => consoleIdentity,
          // The messaging header variant lands with the messaging feature
          // step; until then it falls back to the shared console header.
          AgentsMessageStyle.participantFlow => consoleIdentity,
        };

        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: identity,
        );
        if (mobileClient) {
          return content;
        }
        return SizedBox(height: conversationHeaderHeight, child: content);
      },
    );
  }
}

class AgentsSidebarCollapseControl extends StatelessWidget {
  const AgentsSidebarCollapseControl({
    super.key,
    required this.expanded,
    required this.tooltip,
    required this.onPressed,
  });

  final bool expanded;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return LicoIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      size: LicoIconButtonSize.large,
      tone: LicoIconButtonTone.outlined,
      icon: expanded
          ? const Icon(Icons.view_sidebar_outlined)
          : Transform.scale(
              scaleX: -1,
              child: const Icon(Icons.view_sidebar_outlined),
            ),
    );
  }
}
