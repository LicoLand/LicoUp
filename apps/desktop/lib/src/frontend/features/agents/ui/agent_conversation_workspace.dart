import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/future_client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_policy_controls.dart';
import 'package:flutter_client/src/frontend/shell/client_platform.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

part 'agent_conversation_event_card.dart';
part 'agent_conversation_runtime_settings.dart';

const double _conversationHeaderHeight = 64;
const double _conversationHistoryMinWidth = 260;

class AgentConversationWorkspace extends StatefulWidget {
  const AgentConversationWorkspace({
    super.key,
    required this.controller,
    required this.targets,
    required this.scanning,
    required this.adding,
    required this.onAddTarget,
    this.allowManualTargetActions = true,
    this.showTabs = true,
  });

  final FutureClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;
  final bool showTabs;

  @override
  State<AgentConversationWorkspace> createState() =>
      _AgentConversationWorkspaceState();
}

class _AgentConversationWorkspaceState
    extends State<AgentConversationWorkspace> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant AgentConversationWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobileClient =
        widget.controller.mobileClientRuntimePlatform ||
        isMobileClientPlatform(context);
    final showTabs = widget.showTabs && !mobileClient;
    final targets = widget.controller.orderedConversationTargets(
      widget.targets,
    );
    final body = _ConversationWorkspaceBody(
      controller: widget.controller,
      onAddTarget: widget.onAddTarget,
      allowManualTargetActions: widget.allowManualTargetActions,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTabs) ...[
          AgentConversationTabBar(
            targets: targets,
            selectedTargetId: widget.controller.selectedConversationAgentId,
            scanning: widget.scanning,
            adding: widget.adding,
            onSelect: (targetId) =>
                unawaited(widget.controller.selectConversationAgent(targetId)),
            onReorder: (oldIndex, newIndex) => unawaited(
              widget.controller.reorderConversationAgentTabs(
                targets,
                oldIndex,
                newIndex,
              ),
            ),
            onAddTarget: widget.onAddTarget,
            allowManualTargetActions: widget.allowManualTargetActions,
          ),
        ],
        Expanded(child: body),
      ],
    );
  }
}

class AgentConversationTabBar extends StatefulWidget {
  const AgentConversationTabBar({
    super.key,
    required this.targets,
    required this.selectedTargetId,
    required this.scanning,
    required this.adding,
    required this.onSelect,
    required this.onReorder,
    required this.onAddTarget,
    required this.allowManualTargetActions,
  });

  final List<TargetCandidate> targets;
  final String selectedTargetId;
  final bool scanning;
  final bool adding;
  final ValueChanged<String> onSelect;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;

  @override
  State<AgentConversationTabBar> createState() =>
      _AgentConversationTabBarState();
}

class _AgentConversationTabBarState extends State<AgentConversationTabBar> {
  static const double _wheelStep = 184;
  static const double _desktopTabMaxWidth = 172;
  static const double _desktopTabMinWidth = 104;
  static const double _mobileTabMaxWidth = 156;
  static const double _mobileTabMinWidth = 126;

  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) {
      return;
    }
    final deltaX = event.scrollDelta.dx;
    final deltaY = event.scrollDelta.dy;
    if (deltaX == 0 && deltaY == 0) {
      return;
    }
    final effectiveDeltaY = deltaX.abs() > deltaY.abs() ? -deltaX : deltaY;
    final position = _scrollController.position;
    final targetOffset = agentTabWheelTargetOffset(
      currentOffset: position.pixels,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      scrollDeltaY: effectiveDeltaY,
      step: _wheelStep,
    );
    if ((targetOffset - position.pixels).abs() < 0.5) {
      return;
    }
    unawaited(
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final mobileClient = isMobileClientPlatform(context);
    final content = SizedBox(
      height: mobileClient ? 54 : 42,
      child: Row(
        children: [
          Expanded(
            child: widget.targets.isEmpty
                ? _AgentTabsEmpty(
                    adding: widget.adding,
                    scanning: widget.scanning,
                    onAddTarget: widget.onAddTarget,
                    allowManualTargetActions: widget.allowManualTargetActions,
                  )
                : Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerSignal: _handlePointerSignal,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const horizontalPadding = 0.0;
                        final tabWidth = agentTabWidthFor(
                          availableWidth:
                              constraints.maxWidth - horizontalPadding * 2,
                          tabCount: widget.targets.length,
                          minWidth: mobileClient
                              ? _mobileTabMinWidth
                              : _desktopTabMinWidth,
                          maxWidth: mobileClient
                              ? _mobileTabMaxWidth
                              : _desktopTabMaxWidth,
                        );
                        final tabList = ReorderableListView(
                          scrollController: _scrollController,
                          physics: mobileClient
                              ? const BouncingScrollPhysics()
                              : const ClampingScrollPhysics(),
                          scrollDirection: Axis.horizontal,
                          buildDefaultDragHandles: false,
                          onReorderItem: widget.onReorder,
                          padding: EdgeInsets.symmetric(
                            horizontal: horizontalPadding,
                            vertical: mobileClient ? 3 : 2,
                          ),
                          proxyDecorator: (child, index, animation) {
                            return AnimatedBuilder(
                              animation: animation,
                              builder: (context, child) {
                                final elevation = Tween<double>(
                                  begin: 0,
                                  end: 8,
                                ).evaluate(animation);
                                return Material(
                                  color: Colors.transparent,
                                  elevation: elevation,
                                  child: child,
                                );
                              },
                              child: child,
                            );
                          },
                          children: [
                            for (
                              var index = 0;
                              index < widget.targets.length;
                              index++
                            )
                              if (isAgentOrchestrationTargetId(
                                widget.targets[index].target,
                              ))
                                SizedBox(
                                  key: ValueKey(
                                    'agent-tab-fixed-${widget.targets[index].target}',
                                  ),
                                  width: tabWidth,
                                  height: double.infinity,
                                  child: _AgentTab(
                                    key: ValueKey(
                                      'agent-tab-${widget.targets[index].target}',
                                    ),
                                    target: widget.targets[index],
                                    selected:
                                        widget.targets[index].target ==
                                        widget.selectedTargetId,
                                    onSelect: widget.onSelect,
                                  ),
                                )
                              else
                                ReorderableDelayedDragStartListener(
                                  key: ValueKey(
                                    'agent-tab-drag-${widget.targets[index].target}',
                                  ),
                                  index: index,
                                  child: SizedBox(
                                    width: tabWidth,
                                    height: double.infinity,
                                    child: _AgentTab(
                                      key: ValueKey(
                                        'agent-tab-${widget.targets[index].target}',
                                      ),
                                      target: widget.targets[index],
                                      selected:
                                          widget.targets[index].target ==
                                          widget.selectedTargetId,
                                      onSelect: widget.onSelect,
                                    ),
                                  ),
                                ),
                          ],
                        );
                        final scrollableTabs = ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context).copyWith(
                            dragDevices: {
                              PointerDeviceKind.mouse,
                              PointerDeviceKind.touch,
                              PointerDeviceKind.trackpad,
                              PointerDeviceKind.stylus,
                            },
                            scrollbars: false,
                          ),
                          child: tabList,
                        );
                        if (mobileClient) {
                          return scrollableTabs;
                        }
                        return RawScrollbar(
                          controller: _scrollController,
                          thumbVisibility: true,
                          trackVisibility: false,
                          interactive: false,
                          thickness: 2,
                          radius: const Radius.circular(999),
                          crossAxisMargin: 1,
                          mainAxisMargin: 72,
                          thumbColor: colors.textMuted.withAlpha(120),
                          scrollbarOrientation: ScrollbarOrientation.bottom,
                          child: scrollableTabs,
                        );
                      },
                    ),
                  ),
          ),
          if (widget.scanning)
            SizedBox(
              width: 42,
              height: double.infinity,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (mobileClient) {
      return content;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: content,
    );
  }
}

@visibleForTesting
double agentTabWheelTargetOffset({
  required double currentOffset,
  required double minScrollExtent,
  required double maxScrollExtent,
  required double scrollDeltaY,
  double step = 184,
}) {
  if (scrollDeltaY == 0) {
    return currentOffset.clamp(minScrollExtent, maxScrollExtent).toDouble();
  }
  final direction = scrollDeltaY < 0 ? 1 : -1;
  return (currentOffset + direction * step)
      .clamp(minScrollExtent, maxScrollExtent)
      .toDouble();
}

@visibleForTesting
double agentTabWidthFor({
  required double availableWidth,
  required int tabCount,
  required double minWidth,
  required double maxWidth,
}) {
  if (tabCount <= 0 || availableWidth <= 0) {
    return maxWidth;
  }
  return (availableWidth / tabCount).clamp(minWidth, maxWidth).toDouble();
}

class _AgentTabsEmpty extends StatelessWidget {
  const _AgentTabsEmpty({
    required this.adding,
    required this.scanning,
    required this.onAddTarget,
    required this.allowManualTargetActions,
  });

  final bool adding;
  final bool scanning;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              scanning
                  ? strings.scanningLocalAgents
                  : strings.noLocalAgentsFound,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (allowManualTargetActions)
            OutlinedButton.icon(
              onPressed: adding ? null : onAddTarget,
              icon: adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 18),
              label: Text(strings.addTarget),
            ),
        ],
      ),
    );
  }
}

class _AgentTab extends StatelessWidget {
  const _AgentTab({
    super.key,
    required this.target,
    required this.selected,
    required this.onSelect,
  });

  final TargetCandidate target;
  final bool selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final detected = target.status != 'not-detected';
    final mobileClient = isMobileClientPlatform(context);
    return Material(
      color: selected ? colors.background : Colors.transparent,
      child: InkWell(
        onTap: () => onSelect(target.target),
        hoverColor: colors.surfaceHigh.withAlpha(92),
        child: SizedBox.expand(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: mobileClient ? 10 : 14),
            decoration: BoxDecoration(
              color: selected ? colors.background : Colors.transparent,
              border: Border(
                top: BorderSide(
                  color: selected ? colors.primary : Colors.transparent,
                  width: selected ? 2 : 0,
                ),
                right: BorderSide(color: colors.line.withAlpha(150)),
              ),
            ),
            child: Row(
              children: [
                AgentBrandIcon(
                  target: target,
                  selected: selected,
                  detected: detected,
                  size: mobileClient ? 28 : 26,
                  iconSize: mobileClient ? 18 : 17,
                ),
                SizedBox(width: mobileClient ? 8 : 9),
                Expanded(
                  child: Text(
                    target.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                      color: selected ? colors.text : colors.textMuted,
                      fontSize: mobileClient ? 14 : 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: target.kind,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(target, colors),
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
}

class _ConversationWorkspaceBody extends StatefulWidget {
  const _ConversationWorkspaceBody({
    required this.controller,
    required this.onAddTarget,
    required this.allowManualTargetActions,
  });

  final FutureClientController controller;
  final VoidCallback onAddTarget;
  final bool allowManualTargetActions;

  @override
  State<_ConversationWorkspaceBody> createState() =>
      _ConversationWorkspaceBodyState();
}

class _ConversationWorkspaceBodyState
    extends State<_ConversationWorkspaceBody> {
  bool _historyCollapsed = false;

  void _toggleHistoryCollapsed() {
    setState(() => _historyCollapsed = !_historyCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final onAddTarget = widget.onAddTarget;
    final allowManualTargetActions = widget.allowManualTargetActions;
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final target = controller.selectedConversationAgent;
    final mobileClient = isMobileClientPlatform(context);
    if (target == null) {
      if (mobileClient) {
        return Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        color: colors.textMuted,
                        size: 26,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.selectAgentToView,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _MobileComposerSurface(
              child: _InactiveRuntimeMessageComposer(
                targetLabel: strings.agent,
                onVoiceHoldStart: controller.beginVoiceInputDraft,
                onVoiceHoldEnd: controller.endVoiceInputDraft,
              ),
            ),
          ],
        );
      }
      return PanelFrame(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.psychology_outlined,
                        color: colors.textMuted,
                        size: 28,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.selectAgentToView,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.textMuted),
                      ),
                      if (allowManualTargetActions) ...[
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: onAddTarget,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(strings.addTarget),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (mobileClient) ...[
              const Divider(height: 1),
              _InactiveRuntimeMessageComposer(
                targetLabel: strings.agent,
                onVoiceHoldStart: controller.beginVoiceInputDraft,
                onVoiceHoldEnd: controller.endVoiceInputDraft,
              ),
            ],
          ],
        ),
      );
    }

    final sessions = controller.selectedConversationSessions;
    final selectedSession = controller.selectedConversationSession;
    final selectedSessionId = selectedSession?.id ?? '';
    final historyItems = sessions
        .map(
          (session) => HistorySessionPanelItem(
            id: session.id,
            title: session.title,
            meta: _sessionUpdatedAtLabel(session),
            preview: _messagePreviewText(session.preview),
            active: session.id == selectedSessionId,
            canDelete: false,
            deleteLabel: strings.deleteNativeHistory,
          ),
        )
        .toList(growable: false);
    if (mobileClient) {
      return _ConversationPane(
        controller: controller,
        target: target,
        session: selectedSession,
        onVoiceHoldStart: controller.beginVoiceInputDraft,
        onVoiceHoldEnd: controller.endVoiceInputDraft,
        historyCollapsed: _historyCollapsed,
        onToggleHistory: _toggleHistoryCollapsed,
        collapseHistoryTooltip: strings.collapseHistoryConversations,
        expandHistoryTooltip: strings.expandHistoryConversations,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final chatPane = _ConversationPane(
          controller: controller,
          target: target,
          session: selectedSession,
          onVoiceHoldStart: controller.beginVoiceInputDraft,
          onVoiceHoldEnd: controller.endVoiceInputDraft,
          historyCollapsed: _historyCollapsed,
          onToggleHistory: _toggleHistoryCollapsed,
          collapseHistoryTooltip: strings.collapseHistoryConversations,
          expandHistoryTooltip: strings.expandHistoryConversations,
        );
        HistorySessionPanel historyPaneFor(
          double maxListHeight, {
          bool framed = true,
          double? headerHeight,
        }) {
          return HistorySessionPanel(
            title: strings.historyConversations,
            subtitle: '',
            loading: controller.isLoadingConversations,
            items: historyItems,
            onSelect: controller.selectConversationSession,
            emptyLabel: strings.noNativeHistories,
            loadingLabel: strings.loadingNativeHistories,
            maxListHeight: maxListHeight,
            framed: framed,
            showHeaderText: false,
            collapsible: false,
            collapsed: _historyCollapsed,
            collapseTooltip: strings.collapseHistoryConversations,
            expandTooltip: strings.expandHistoryConversations,
            headerHeight: headerHeight,
            hasMore: controller.selectedConversationSessionsHasMore,
            loadingMore: controller.isLoadingMoreSelectedConversationSessions,
            onLoadMore: () => unawaited(
              controller.loadMoreConversationSessions(
                controller.selectedConversationAgentId,
              ),
            ),
            loadMoreLabel: strings.scrollToLoadMoreHistories,
            loadingMoreLabel: strings.loadingMoreHistories,
            leading: _ArchiveAgentConversationsButton(
              busy: controller.isCollectingConversationArchive,
              tooltip: strings.archiveAgentConversations,
              onPressed: () =>
                  unawaited(controller.archiveSelectedConversationAgent()),
            ),
            trailing: _NewAgentConversationButton(
              enabled:
                  !controller.isLoadingConversations &&
                  !controller.isSendingConversationMessage,
              tooltip: strings.newConversation,
              onPressed: controller.startNewConversationSession,
            ),
          );
        }

        if (compact) {
          if (_historyCollapsed) {
            return chatPane;
          }
          final historyRatio = sessions.length > 1 ? 0.50 : 0.34;
          final historyMax = sessions.length > 1 ? 300.0 : 228.0;
          final historyMin = sessions.length > 1 ? 154.0 : 138.0;
          final historyHeight = (constraints.maxHeight * historyRatio).clamp(
            historyMin,
            historyMax,
          );
          final historyListHeight = (historyHeight - 58).clamp(72.0, 170.0);
          const minScrollableChatHeight = 220.0;
          final compactContentHeight =
              historyHeight + 8 + minScrollableChatHeight;
          if (constraints.maxHeight < compactContentHeight) {
            final scrollHistoryHeight = historyMax;
            final scrollHistoryListHeight = (scrollHistoryHeight - 58).clamp(
              72.0,
              240.0,
            );
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: scrollHistoryHeight,
                    child: historyPaneFor(scrollHistoryListHeight.toDouble()),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(height: minScrollableChatHeight, child: chatPane),
                ],
              ),
            );
          }
          return Column(
            children: [
              SizedBox(
                height: historyHeight,
                child: historyPaneFor(historyListHeight.toDouble()),
              ),
              const SizedBox(height: 8),
              Expanded(child: chatPane),
            ],
          );
        }

        final historyListHeight = (constraints.maxHeight - 58).clamp(
          180.0,
          520.0,
        );
        final embeddedChatPane = _ConversationPane(
          controller: controller,
          target: target,
          session: selectedSession,
          onVoiceHoldStart: controller.beginVoiceInputDraft,
          onVoiceHoldEnd: controller.endVoiceInputDraft,
          historyCollapsed: _historyCollapsed,
          onToggleHistory: _toggleHistoryCollapsed,
          collapseHistoryTooltip: strings.collapseHistoryConversations,
          expandHistoryTooltip: strings.expandHistoryConversations,
          framed: false,
        );
        return _ResizableConversationSplit(
          historyPane: historyPaneFor(
            historyListHeight.toDouble(),
            framed: false,
            headerHeight: _conversationHeaderHeight,
          ),
          chatPane: embeddedChatPane,
          initialHistoryWidth: _conversationHistoryMinWidth,
          historyCollapsed: _historyCollapsed,
        );
      },
    );
  }
}

class _ArchiveAgentConversationsButton extends StatelessWidget {
  const _ArchiveAgentConversationsButton({
    required this.busy,
    required this.tooltip,
    required this.onPressed,
  });

  final bool busy;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textMuted,
              ),
            )
          : const Icon(Icons.archive_outlined, size: 18),
    );
  }
}

class _NewAgentConversationButton extends StatelessWidget {
  const _NewAgentConversationButton({
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      color: colors.primary,
      disabledColor: colors.textMuted,
      hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
      style: IconButton.styleFrom(
        fixedSize: const Size(32, 32),
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: const Icon(Icons.add_comment_outlined, size: 18),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.controller,
    required this.target,
    required this.session,
    required this.onVoiceHoldStart,
    required this.onVoiceHoldEnd,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
    this.framed = true,
  });

  final FutureClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final VoidCallback onVoiceHoldStart;
  final VoidCallback onVoiceHoldEnd;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;
  final bool framed;

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
    final composer = _RuntimeMessageComposer(
      targetLabel: target.label,
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
      onSend: (text) => unawaited(controller.sendConversationMessage(text)),
      onVoiceHoldStart: onVoiceHoldStart,
      onVoiceHoldEnd: onVoiceHoldEnd,
    );
    final sendGate = composerEnabled
        ? null
        : ConversationParitySendGateBanner(
            copy: gateCopy,
            onUnblock: switch (gateCopy.unblockAction) {
              ConversationParityUnblockAction.rescanAgents =>
                () => unawaited(controller.scanTargets()),
              ConversationParityUnblockAction.editPolicy =>
                () => unawaited(
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
            child: _MessageList(
              loading: controller.isLoadingConversations,
              session: session,
              target: target,
            ),
          ),
          ?sendGate,
          _MobileComposerSurface(child: composer),
        ],
      );
    }
    final content = Column(
      children: [
        if (!mobileClient) ...[
          _ConversationHeader(
            controller: controller,
            target: target,
            session: session,
            historyCollapsed: historyCollapsed,
            onToggleHistory: onToggleHistory,
            collapseHistoryTooltip: collapseHistoryTooltip,
            expandHistoryTooltip: expandHistoryTooltip,
          ),
          const Divider(height: 1),
        ],
        Expanded(
          child: _MessageList(
            loading: controller.isLoadingConversations,
            session: session,
            target: target,
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

class _ResizableConversationSplit extends StatefulWidget {
  const _ResizableConversationSplit({
    required this.historyPane,
    required this.chatPane,
    required this.initialHistoryWidth,
    required this.historyCollapsed,
  });

  final Widget historyPane;
  final Widget chatPane;
  final double initialHistoryWidth;
  final bool historyCollapsed;

  @override
  State<_ResizableConversationSplit> createState() =>
      _ResizableConversationSplitState();
}

class _ResizableConversationSplitState
    extends State<_ResizableConversationSplit> {
  static const double _minChatWidth = 360;
  static const double _dividerWidth = 12;

  double? _historyWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxHistoryWidth =
            (constraints.maxWidth - _dividerWidth - _minChatWidth)
                .clamp(_conversationHistoryMinWidth, constraints.maxWidth)
                .toDouble();
        final historyWidth = (_historyWidth ?? widget.initialHistoryWidth)
            .clamp(_conversationHistoryMinWidth, maxHistoryWidth)
            .toDouble();
        return ColoredBox(
          key: const Key('conversation-split-page'),
          color: colors.surface,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.historyCollapsed)
                SizedBox(width: historyWidth, child: widget.historyPane),
              if (!widget.historyCollapsed)
                _ConversationSplitDivider(
                  width: _dividerWidth,
                  onDragDelta: (delta) {
                    setState(() {
                      _historyWidth = (historyWidth + delta)
                          .clamp(_conversationHistoryMinWidth, maxHistoryWidth)
                          .toDouble();
                    });
                  },
                ),
              Expanded(child: widget.chatPane),
            ],
          ),
        );
      },
    );
  }
}

class _ConversationSplitDivider extends StatelessWidget {
  const _ConversationSplitDivider({
    required this.width,
    required this.onDragDelta,
  });

  final double width;
  final ValueChanged<double> onDragDelta;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        key: const Key('conversation-split-divider'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDragDelta(details.delta.dx),
        child: SizedBox(
          width: width,
          child: Center(
            child: Container(
              width: 1,
              height: double.infinity,
              color: colors.line,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileComposerSurface extends StatelessWidget {
  const _MobileComposerSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: child,
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.controller,
    required this.target,
    required this.session,
    required this.historyCollapsed,
    required this.onToggleHistory,
    required this.collapseHistoryTooltip,
    required this.expandHistoryTooltip,
  });

  final FutureClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final bool historyCollapsed;
  final VoidCallback onToggleHistory;
  final String collapseHistoryTooltip;
  final String expandHistoryTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final sessionTitle = session?.title.trim();
    final headerTitle = sessionTitle == null || sessionTitle.isEmpty
        ? target.label
        : sessionTitle;
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobileClient = isMobileClientPlatform(context);
        final identity = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: mobileClient
              ? const <Widget>[]
              : [
                  IconButton(
                    tooltip: historyCollapsed
                        ? expandHistoryTooltip
                        : collapseHistoryTooltip,
                    onPressed: onToggleHistory,
                    color: colors.textMuted,
                    hoverColor: Color.lerp(
                      colors.surface,
                      colors.primary,
                      0.12,
                    ),
                    style: IconButton.styleFrom(
                      fixedSize: const Size(40, 40),
                      minimumSize: const Size(40, 40),
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    icon: _SidebarToggleGlyph(
                      expanded: !historyCollapsed,
                      color: colors.textMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
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
                  if (!controller.selectedConversationIsOrchestration) ...[
                    const SizedBox(width: 10),
                    ConversationParityDisclosurePanel(target: target),
                  ],
                  if (controller.selectedConversationIsOrchestration) ...[
                    const SizedBox(width: 12),
                    AgentOrchestrationPolicyHeaderControls(
                      controller: controller,
                    ),
                  ],
                ],
        );

        final content = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: identity,
        );
        if (mobileClient) {
          return content;
        }
        return SizedBox(height: _conversationHeaderHeight, child: content);
      },
    );
  }
}

class _SidebarToggleGlyph extends StatelessWidget {
  const _SidebarToggleGlyph({required this.expanded, required this.color});

  final bool expanded;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 22),
      painter: _SidebarToggleGlyphPainter(expanded: expanded, color: color),
    );
  }
}

class _SidebarToggleGlyphPainter extends CustomPainter {
  const _SidebarToggleGlyphPainter({
    required this.expanded,
    required this.color,
  });

  final bool expanded;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outerRect = Rect.fromLTWH(3, 4, size.width - 6, size.height - 8);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withAlpha(76)
      ..style = PaintingStyle.fill;
    final outer = RRect.fromRectAndRadius(
      outerRect,
      const Radius.circular(2.5),
    );
    canvas.drawRRect(outer, stroke);

    final panelWidth = outerRect.width * 0.4;
    final panelRect = expanded
        ? Rect.fromLTWH(
            outerRect.left,
            outerRect.top,
            panelWidth,
            outerRect.height,
          )
        : Rect.fromLTWH(
            outerRect.right - panelWidth,
            outerRect.top,
            panelWidth,
            outerRect.height,
          );
    canvas.drawRRect(
      RRect.fromRectAndRadius(panelRect.deflate(1.8), const Radius.circular(1)),
      fill,
    );
    final dividerX = expanded ? panelRect.right : panelRect.left;
    canvas.drawLine(
      Offset(dividerX, outerRect.top + 1.5),
      Offset(dividerX, outerRect.bottom - 1.5),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_SidebarToggleGlyphPainter oldDelegate) {
    return oldDelegate.expanded != expanded || oldDelegate.color != color;
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.loading,
    required this.session,
    required this.target,
  });

  final bool loading;
  final AgentConversationSession? session;
  final TargetCandidate target;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final messages = session?.messages ?? const <AgentConversationMessage>[];
    if (loading && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            strings.noMessagesInHistory,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return FutureBuilder<AgentRenderAdapter>(
      future: AgentRenderAdapterRegistry.instance.resolve(
        agentId: target.target,
        sourceClient: session?.sourceClient ?? '',
        sourceTool: session?.sourceTool ?? '',
        adapterId: session?.adapterId ?? '',
      ),
      builder: (context, snapshot) {
        final adapter = snapshot.data ?? AgentRenderAdapter.fallback();
        final sessionIdentity = [
          target.target,
          session?.id ?? '',
          session?.nativeSessionId ?? '',
        ].join('|');
        final sessionKey = sessionIdentity.hashCode
            .toUnsigned(32)
            .toRadixString(16);
        final timelineItems = _conversationTimelineItems(
          messages,
          sessionIdentity,
          historyTruncated: session?.historyTruncated ?? false,
          messageTreeTruncated: session?.messageTreeTruncated ?? false,
        ).reversed.toList(growable: false);
        final indexByStorageKey = <String, int>{
          for (var index = 0; index < timelineItems.length; index++)
            timelineItems[index].storageKey: index,
        };
        return ListView.builder(
          key: PageStorageKey<String>(
            'agent-conversation-message-list-$sessionKey',
          ),
          reverse: true,
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + adapter.assistantVerticalPadding,
          ),
          findChildIndexCallback: (key) {
            if (key case ValueKey<String>(:final value)) {
              return indexByStorageKey[value];
            }
            return null;
          },
          itemBuilder: (context, index) {
            final item = timelineItems[index];
            final content = switch (item) {
              _ConversationMessageTimelineItem(:final message) => _MessageBlock(
                message: message,
                adapter: adapter,
              ),
              _ConversationProcessTimelineItem(:final events) =>
                _ConversationProcessCard(events: events, adapter: adapter),
              _ConversationTruncationTimelineItem(
                :final historyTruncated,
                :final messageTreeTruncated,
              ) =>
                _ConversationTruncationNotice(
                  historyTruncated: historyTruncated,
                  messageTreeTruncated: messageTreeTruncated,
                ),
            };
            return Padding(
              key: ValueKey<String>(item.storageKey),
              padding: EdgeInsets.only(
                bottom: index + 1 < timelineItems.length
                    ? adapter.assistantVerticalPadding
                    : 0,
              ),
              child: content,
            );
          },
          itemCount: timelineItems.length,
        );
      },
    );
  }
}

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    if (message.isSubagentCard) {
      return _SubagentCardBlock(message: message, adapter: adapter);
    }
    return switch (message.kind) {
      AgentConversationMessageKind.user => _UserMessageBlock(
        message: message,
        adapter: adapter,
      ),
      AgentConversationMessageKind.assistant =>
        adapter.assistantLayout == AgentAssistantLayout.bubble
            ? _AssistantBubbleBlock(message: message, adapter: adapter)
            : _AssistantDocumentBlock(message: message, adapter: adapter),
      AgentConversationMessageKind.toolCall ||
      AgentConversationMessageKind.toolResult ||
      AgentConversationMessageKind.reasoning ||
      AgentConversationMessageKind.metadata ||
      AgentConversationMessageKind.error ||
      AgentConversationMessageKind.event => throw StateError(
        'Structured events must be rendered by the process timeline.',
      ),
      AgentConversationMessageKind.subagent => _SubagentCardBlock(
        message: message,
        adapter: adapter,
      ),
    };
  }
}

class _SubagentCardBlock extends StatefulWidget {
  const _SubagentCardBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  State<_SubagentCardBlock> createState() => _SubagentCardBlockState();
}

class _SubagentCardBlockState extends State<_SubagentCardBlock> {
  late bool _expanded = !widget.message.collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = widget.message.cardTitle.trim().isEmpty
        ? strings.subagentTask
        : widget.message.cardTitle.trim();
    final subtitle = widget.message.cardSubtitle.trim().isEmpty
        ? '${strings.subagentTask} · ${strings.messagesCount(widget.message.childMessages.length)}'
        : widget.message.cardSubtitle.trim();
    final preview = _messagePreviewText(widget.message.text);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Color.lerp(colors.surfaceLow, colors.primaryFixed, 0.18),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Color.lerp(colors.line, colors.primary, 0.36)!,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_tree_outlined,
                        color: colors.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text,
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: colors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
              if (!_expanded && preview.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(44, 0, 14, 12),
                  child: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
              if (_expanded) ...[
                Divider(height: 1, color: colors.line),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (
                        var index = 0;
                        index < widget.message.childMessages.length;
                        index++
                      ) ...[
                        _SubagentChildMessageBlock(
                          message: widget.message.childMessages[index],
                          adapter: widget.adapter,
                        ),
                        if (index != widget.message.childMessages.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Divider(height: 1, color: colors.line),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  const _MessageContent({
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    final display = splitMessageDisplayBlocks(data);
    final hasBody = display.body.trim().isNotEmpty;
    final hasDetails = display.metadataBlocks.isNotEmpty;
    final hasRecommendedPlugins = display.recommendedPluginsBlocks.isNotEmpty;
    if (!hasBody && !hasDetails && !hasRecommendedPlugins) {
      return MessageMarkdown(
        data: '',
        foreground: foreground,
        accent: accent,
        codeBackground: codeBackground,
        blockBackground: blockBackground,
        borderColor: borderColor,
        renderStyle: renderStyle,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasBody)
          MessageMarkdown(
            data: display.body,
            foreground: foreground,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        if (hasRecommendedPlugins) ...[
          if (hasBody) SizedBox(height: renderStyle.blockSpacing),
          _RecommendedPluginsDisclosure(
            blocks: display.recommendedPluginsBlocks,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        ],
        if (hasDetails) ...[
          if (hasBody || hasRecommendedPlugins)
            SizedBox(height: renderStyle.blockSpacing),
          _MessageDetailsDisclosure(
            details: display.metadataBlocks.join('\n\n'),
            detailsCount: display.metadataBlocks.length,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
        ],
      ],
    );
  }
}

class _MessageDetailsDisclosure extends StatefulWidget {
  const _MessageDetailsDisclosure({
    required this.details,
    required this.detailsCount,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final String details;
  final int detailsCount;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_MessageDetailsDisclosure> createState() =>
      _MessageDetailsDisclosureState();
}

class _MessageDetailsDisclosureState extends State<_MessageDetailsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = strings.details;
    final countSuffix = widget.detailsCount > 1
        ? ' · ${widget.detailsCount}'
        : '';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.blockBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '$title$countSuffix',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: widget.borderColor),
            Padding(
              padding: const EdgeInsets.all(10),
              child: MessageMarkdown(
                data: widget.details,
                foreground: colors.textMuted,
                accent: widget.accent,
                codeBackground: widget.codeBackground,
                blockBackground: widget.blockBackground,
                borderColor: widget.borderColor,
                renderStyle: widget.renderStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendedPluginsDisclosure extends StatefulWidget {
  const _RecommendedPluginsDisclosure({
    required this.blocks,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    required this.renderStyle,
  });

  final List<String> blocks;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  State<_RecommendedPluginsDisclosure> createState() =>
      _RecommendedPluginsDisclosureState();
}

class _RecommendedPluginsDisclosureState
    extends State<_RecommendedPluginsDisclosure> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = strings.recommendedPlugins;
    final pluginCount = recommendedPluginsCount(widget.blocks);
    final countSuffix = pluginCount > 0 ? ' · $pluginCount' : '';
    final content = widget.blocks.join('\n\n');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.blockBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.extension_outlined,
                    size: 14,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '$title$countSuffix',
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: widget.borderColor),
            Padding(
              padding: const EdgeInsets.all(10),
              child: MessageMarkdown(
                data: content,
                foreground: colors.text,
                accent: widget.accent,
                codeBackground: widget.codeBackground,
                blockBackground: widget.blockBackground,
                borderColor: widget.borderColor,
                renderStyle: widget.renderStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

@visibleForTesting
int recommendedPluginsCount(List<String> blocks) {
  var count = 0;
  for (final block in blocks) {
    for (final line in block.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        count++;
      }
    }
  }
  return count;
}

@visibleForTesting
class MessageDisplayContent {
  const MessageDisplayContent({
    required this.body,
    required this.metadataBlocks,
    required this.recommendedPluginsBlocks,
  });

  final String body;
  final List<String> metadataBlocks;
  final List<String> recommendedPluginsBlocks;
}

@visibleForTesting
MessageDisplayContent splitMessageDisplayBlocks(String data) {
  final pluginsExtraction = _extractBlocks(data, _recommendedPluginsPattern);
  final metadataExtraction = _extractBlocks(
    pluginsExtraction.body,
    _additionalMetadataPattern,
  );
  return MessageDisplayContent(
    body: _compactMessageBody(metadataExtraction.body),
    metadataBlocks: metadataExtraction.blocks,
    recommendedPluginsBlocks: pluginsExtraction.blocks,
  );
}

({String body, List<String> blocks}) _extractBlocks(
  String data,
  RegExp pattern,
) {
  final matches = pattern.allMatches(data);
  if (matches.isEmpty) {
    return (body: data, blocks: const <String>[]);
  }
  final body = StringBuffer();
  final blocks = <String>[];
  var cursor = 0;
  for (final match in matches) {
    body.write(data.substring(cursor, match.start));
    final block = (match.group(1) ?? '').trim();
    if (block.isNotEmpty) {
      blocks.add(block);
    }
    cursor = match.end;
  }
  body.write(data.substring(cursor));
  return (body: body.toString(), blocks: blocks);
}

final _additionalMetadataPattern = RegExp(
  r'<\s*additional_metadata\s*>([\s\S]*?)<\s*/\s*additional_metadata\s*>',
  caseSensitive: false,
);

final _recommendedPluginsPattern = RegExp(
  r'<\s*recommended_plugins\s*>([\s\S]*?)<\s*/\s*recommended_plugins\s*>',
  caseSensitive: false,
);

String _compactMessageBody(String text) {
  return text
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _messagePreviewText(String text) {
  return splitMessageDisplayBlocks(text).body.trim();
}

class _SubagentChildMessageBlock extends StatelessWidget {
  const _SubagentChildMessageBlock({
    required this.message,
    required this.adapter,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return _MessageContent(
      data: message.text,
      foreground: _messageForeground(colors, message.role),
      accent: colors.primary,
      codeBackground: _toneColor(colors, adapter.codeTone),
      blockBackground: _toneColor(colors, adapter.quoteTone),
      borderColor: colors.line,
      renderStyle: adapter.markdownStyle,
    );
  }
}

class _UserMessageBlock extends StatelessWidget {
  const _UserMessageBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.userBubble.maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _bubbleColor(colors, adapter.userBubble.tone),
            borderRadius: BorderRadius.circular(adapter.userBubble.radius),
            border: Border.all(color: _bubbleBorderColor(colors)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: adapter.userBubble.paddingX,
              vertical: adapter.userBubble.paddingY,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (adapter.showUserRoleLabel) ...[
                  Text(
                    strings.you,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                _MessageContent(
                  data: message.text,
                  foreground: colors.text,
                  accent: colors.primary,
                  codeBackground: _toneColor(colors, 'subtle'),
                  blockBackground: _toneColor(colors, 'surface'),
                  borderColor: colors.line,
                  renderStyle: adapter.markdownStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantDocumentBlock extends StatelessWidget {
  const _AssistantDocumentBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: adapter.assistantHorizontalInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (adapter.showAssistantRoleLabel) ...[
                Text(
                  strings.agent,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              _MessageContent(
                data: message.text,
                foreground: _messageForeground(colors, message.role),
                accent: colors.primary,
                codeBackground: _toneColor(colors, adapter.codeTone),
                blockBackground: _toneColor(colors, adapter.quoteTone),
                borderColor: colors.line,
                renderStyle: adapter.markdownStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantBubbleBlock extends StatelessWidget {
  const _AssistantBubbleBlock({required this.message, required this.adapter});

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: adapter.assistantMaxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: _MessageContent(
              data: message.text,
              foreground: _messageForeground(colors, message.role),
              accent: colors.primary,
              codeBackground: _toneColor(colors, adapter.codeTone),
              blockBackground: _toneColor(colors, adapter.quoteTone),
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            ),
          ),
        ),
      ),
    );
  }
}

Color _messageForeground(LicoThemeColors colors, String role) {
  final normalized = role.toLowerCase();
  if (normalized == 'metadata' || normalized == 'system') {
    return colors.textMuted;
  }
  return colors.text;
}

Color _bubbleColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'primary' => colors.primary,
    'subtle' => colors.surfaceLow,
    'raised' => colors.surface,
    _ => colors.surfaceLow,
  };
}

Color _bubbleBorderColor(LicoThemeColors colors) {
  return colors.line;
}

Color _toneColor(LicoThemeColors colors, String tone) {
  return switch (tone) {
    'raised' => colors.surfaceHigh,
    'surface' => colors.surface,
    'muted' => colors.surfaceHighest,
    _ => colors.surfaceLow,
  };
}

class _RuntimeMessageComposer extends StatefulWidget {
  const _RuntimeMessageComposer({
    required this.targetLabel,
    required this.busy,
    required this.enabled,
    required this.disabledHint,
    required this.modelOptions,
    required this.selectedModel,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onSend,
    required this.onVoiceHoldStart,
    required this.onVoiceHoldEnd,
  });

  final String targetLabel;
  final bool busy;
  final bool enabled;
  final String disabledHint;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onSend;
  final VoidCallback onVoiceHoldStart;
  final VoidCallback onVoiceHoldEnd;

  @override
  State<_RuntimeMessageComposer> createState() =>
      _RuntimeMessageComposerState();
}

class _RuntimeMessageComposerState extends State<_RuntimeMessageComposer> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy || !widget.enabled) {
      return;
    }
    _controller.clear();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final mobileClient = isMobileClientPlatform(context);
    final interactive = widget.enabled && !widget.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.modelOptions.isNotEmpty ||
              widget.reasoningEffortOptions.isNotEmpty) ...[
            _ConversationRuntimeSettingsBar(
              enabled: interactive,
              modelOptions: widget.modelOptions,
              selectedModel: widget.selectedModel,
              reasoningEffortOptions: widget.reasoningEffortOptions,
              selectedReasoningEffort: widget.selectedReasoningEffort,
              onModelChanged: widget.onModelChanged,
              onReasoningEffortChanged: widget.onReasoningEffortChanged,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  enabled: interactive,
                  decoration: InputDecoration(
                    hintText: widget.enabled
                        ? strings.messageTarget(widget.targetLabel)
                        : widget.disabledHint,
                    isDense: true,
                    filled: true,
                    fillColor: colors.surfaceLow,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.line),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colors.primary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (mobileClient) ...[
                _VoiceHoldButton(
                  enabled: interactive,
                  onHoldStart: widget.onVoiceHoldStart,
                  onHoldEnd: widget.onVoiceHoldEnd,
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  tooltip: strings.send,
                  onPressed: interactive ? _submit : null,
                  style: IconButton.styleFrom(
                    backgroundColor: interactive
                        ? colors.surfaceLow
                        : colors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(
                        color: interactive
                            ? colors.primary.withAlpha(60)
                            : colors.line.withAlpha(40),
                      ),
                    ),
                  ),
                  icon: widget.busy
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.primary,
                          ),
                        )
                      : Icon(
                          Icons.arrow_upward_rounded,
                          size: 18,
                          color: interactive
                              ? colors.primaryStrong
                              : colors.textMuted.withAlpha(80),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InactiveRuntimeMessageComposer extends StatelessWidget {
  const _InactiveRuntimeMessageComposer({
    required this.targetLabel,
    required this.onVoiceHoldStart,
    required this.onVoiceHoldEnd,
  });

  final String targetLabel;
  final VoidCallback onVoiceHoldStart;
  final VoidCallback onVoiceHoldEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              enabled: false,
              minLines: 1,
              maxLines: 1,
              decoration: InputDecoration(
                hintText: strings.messageTarget(targetLabel),
                isDense: true,
                filled: true,
                fillColor: colors.surfaceLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _VoiceHoldButton(
            enabled: true,
            onHoldStart: onVoiceHoldStart,
            onHoldEnd: onVoiceHoldEnd,
          ),
        ],
      ),
    );
  }
}

class _VoiceHoldButton extends StatelessWidget {
  const _VoiceHoldButton({
    required this.enabled,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final bool enabled;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: enabled ? (_) => onHoldStart() : null,
      onLongPressEnd: enabled ? (_) => onHoldEnd() : null,
      onLongPressCancel: enabled ? onHoldEnd : null,
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton.filledTonal(
          tooltip: strings.voiceInput,
          onPressed: enabled ? onHoldStart : null,
          icon: const Icon(Icons.mic_none_outlined, size: 18),
        ),
      ),
    );
  }
}

String _sessionUpdatedAtLabel(AgentConversationSession session) {
  final rawUpdatedAt = session.updatedAt.trim().isEmpty
      ? session.createdAt.trim()
      : session.updatedAt.trim();
  final updatedAt = DateTime.tryParse(rawUpdatedAt);
  if (updatedAt == null) {
    return rawUpdatedAt;
  }
  final local = updatedAt.toLocal();
  final value =
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return value;
}

Color _statusColor(TargetCandidate target, LicoThemeColors colors) {
  return switch (target.status) {
    'configured' => colors.success,
    'detected' => colors.primary,
    'manual' => colors.warning,
    _ => colors.textMuted,
  };
}
