import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../l10n/lico_strings.dart';
import '../services/agent_conversation_service.dart';
import '../services/agent_service.dart';
import 'agent_brand_icon.dart';
import 'agent_usage_panel.dart';
import 'history_session_panel.dart';
import 'panel_frame.dart';
import 'theme.dart';

class AgentConversationWorkspace extends StatefulWidget {
  const AgentConversationWorkspace({
    super.key,
    required this.controller,
    required this.targets,
    required this.scanning,
    required this.adding,
    required this.onRescan,
    required this.onAddTarget,
    required this.onInspect,
    required this.onPlan,
  });

  final FutureClientController controller;
  final List<TargetCandidate> targets;
  final bool scanning;
  final bool adding;
  final VoidCallback onRescan;
  final VoidCallback onAddTarget;
  final ValueChanged<String> onInspect;
  final ValueChanged<String> onPlan;

  @override
  State<AgentConversationWorkspace> createState() =>
      _AgentConversationWorkspaceState();
}

class _AgentConversationWorkspaceState
    extends State<AgentConversationWorkspace> {
  @override
  Widget build(BuildContext context) {
    final targets = widget.targets
        .where((target) => target.visibleInClient)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AgentTabBar(
          targets: targets,
          selectedTargetId: widget.controller.selectedConversationAgentId,
          scanning: widget.scanning,
          adding: widget.adding,
          onSelect: (targetId) =>
              unawaited(widget.controller.selectConversationAgent(targetId)),
          onAddTarget: widget.onAddTarget,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _ConversationWorkspaceBody(
            controller: widget.controller,
            onAddTarget: widget.onAddTarget,
            onInspect: widget.onInspect,
            onPlan: widget.onPlan,
          ),
        ),
      ],
    );
  }
}

class _AgentTabBar extends StatefulWidget {
  const _AgentTabBar({
    required this.targets,
    required this.selectedTargetId,
    required this.scanning,
    required this.adding,
    required this.onSelect,
    required this.onAddTarget,
  });

  final List<TargetCandidate> targets;
  final String selectedTargetId;
  final bool scanning;
  final bool adding;
  final ValueChanged<String> onSelect;
  final VoidCallback onAddTarget;

  @override
  State<_AgentTabBar> createState() => _AgentTabBarState();
}

class _AgentTabBarState extends State<_AgentTabBar> {
  static const double _wheelStep = 184;

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
    final deltaY = event.scrollDelta.dy;
    if (deltaY == 0) {
      return;
    }
    final position = _scrollController.position;
    final targetOffset = agentTabWheelTargetOffset(
      currentOffset: position.pixels,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      scrollDeltaY: deltaY,
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
    return PanelFrame(
      child: SizedBox(
        height: 62,
        child: Row(
          children: [
            Expanded(
              child: widget.targets.isEmpty
                  ? _AgentTabsEmpty(
                      adding: widget.adding,
                      scanning: widget.scanning,
                      onAddTarget: widget.onAddTarget,
                    )
                  : Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerSignal: _handlePointerSignal,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        physics: const NeverScrollableScrollPhysics(),
                        scrollDirection: Axis.horizontal,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              for (
                                var index = 0;
                                index < widget.targets.length;
                                index++
                              ) ...[
                                _AgentTab(
                                  target: widget.targets[index],
                                  selected:
                                      widget.targets[index].target ==
                                      widget.selectedTargetId,
                                  onSelect: widget.onSelect,
                                ),
                                if (index != widget.targets.length - 1)
                                  const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
            if (widget.scanning)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
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

class _AgentTabsEmpty extends StatelessWidget {
  const _AgentTabsEmpty({
    required this.adding,
    required this.scanning,
    required this.onAddTarget,
  });

  final bool adding;
  final bool scanning;
  final VoidCallback onAddTarget;

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
    final strings = LicoStrings.of(context);
    final detected = target.status != 'not-detected';
    return Material(
      color: selected ? colors.surfaceHigh : colors.surfaceLow,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onSelect(target.target),
        child: SizedBox(
          width: 176,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? colors.primary : colors.line,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                AgentBrandIcon(
                  target: target,
                  selected: selected,
                  detected: detected,
                  size: 30,
                  iconSize: 20,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        target.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: colors.text,
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _statusColor(target, colors),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${_statusLabel(target, strings)} · ${target.kind}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 11,
                                height: 1.2,
                              ),
                            ),
                          ),
                        ],
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

class _ConversationWorkspaceBody extends StatelessWidget {
  const _ConversationWorkspaceBody({
    required this.controller,
    required this.onAddTarget,
    required this.onInspect,
    required this.onPlan,
  });

  final FutureClientController controller;
  final VoidCallback onAddTarget;
  final ValueChanged<String> onInspect;
  final ValueChanged<String> onPlan;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final target = controller.selectedConversationAgent;
    if (target == null) {
      return PanelFrame(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  color: colors.textMuted,
                  size: 28,
                ),
                const SizedBox(height: 10),
                Text(
                  strings.selectAgentToView,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textMuted),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: onAddTarget,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(strings.addTarget),
                ),
              ],
            ),
          ),
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
            meta: _sessionPanelMeta(session, strings),
            preview: session.preview,
            active: session.id == selectedSessionId,
            canDelete: false,
            deleteLabel: strings.deleteNativeHistory,
          ),
        )
        .toList(growable: false);
    return Column(
      children: [
        AgentUsagePanel(controller: controller, selectedTarget: target),
        const SizedBox(height: 12),
        _ConversationArchivePanel(controller: controller),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 760;
              final chatPane = _ConversationPane(
                controller: controller,
                target: target,
                session: selectedSession,
                onInspect: onInspect,
                onPlan: onPlan,
              );
              HistorySessionPanel historyPaneFor(double maxListHeight) {
                return HistorySessionPanel(
                  title: strings.historyConversations,
                  subtitle: controller.isLoadingConversations
                      ? strings.loading
                      : strings.conversationCount(sessions.length),
                  loading: controller.isLoadingConversations,
                  items: historyItems,
                  onSelect: controller.selectConversationSession,
                  emptyLabel: strings.noNativeHistories,
                  loadingLabel: strings.loadingNativeHistories,
                  maxListHeight: maxListHeight,
                );
              }

              if (compact) {
                final historyRatio = sessions.length > 1 ? 0.50 : 0.34;
                final historyMax = sessions.length > 1 ? 300.0 : 228.0;
                final historyMin = sessions.length > 1 ? 154.0 : 138.0;
                final historyHeight = (constraints.maxHeight * historyRatio)
                    .clamp(historyMin, historyMax);
                final historyListHeight = (historyHeight - 58).clamp(
                  72.0,
                  170.0,
                );
                const minScrollableChatHeight = 220.0;
                final compactContentHeight =
                    historyHeight + 8 + minScrollableChatHeight;
                if (constraints.maxHeight < compactContentHeight) {
                  final scrollHistoryHeight = historyMax;
                  final scrollHistoryListHeight = (scrollHistoryHeight - 58)
                      .clamp(72.0, 240.0);
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: scrollHistoryHeight,
                          child: historyPaneFor(
                            scrollHistoryListHeight.toDouble(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: minScrollableChatHeight,
                          child: chatPane,
                        ),
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

              final historyWidth = constraints.maxWidth < 920 ? 280.0 : 316.0;
              final historyListHeight = (constraints.maxHeight - 58).clamp(
                180.0,
                520.0,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: historyWidth,
                    child: historyPaneFor(historyListHeight.toDouble()),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: chatPane),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConversationArchivePanel extends StatelessWidget {
  const _ConversationArchivePanel({required this.controller});

  final FutureClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final busy = controller.isCollectingConversationArchive;
    final canArchive =
        controller.archiveKeywordsController.text.trim().isNotEmpty &&
        controller.archiveDestinationController.text.trim().isNotEmpty;
    final result = controller.conversationArchiveResult;
    final count = (result?['documentCount'] ?? result?['selectedCount'] ?? '')
        .toString();
    final root =
        (result?['archiveRoot'] ?? controller.archiveDestinationController.text)
            .toString();

    return PanelFrame(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 620;
            final keywords = TextField(
              controller: controller.archiveKeywordsController,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: strings.keywords,
                isDense: true,
                filled: true,
                fillColor: colors.surfaceLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              textInputAction: TextInputAction.next,
            );
            final destination = TextField(
              controller: controller.archiveDestinationController,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: strings.archiveDirectory,
                isDense: true,
                filled: true,
                fillColor: colors.surfaceLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            );
            final archiveButton = FilledButton.icon(
              onPressed: busy || !canArchive
                  ? null
                  : () => unawaited(controller.archiveConversationKeywords()),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.archive_outlined, size: 18),
              label: Text(strings.archive),
            );
            final status = [
              if (count.trim().isNotEmpty) strings.recordsCount(count),
              if (root.trim().isNotEmpty) root,
            ].join(' · ');
            final statusText = Text(
              status,
              maxLines: compact ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  keywords,
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      archiveButton,
                      const SizedBox(width: 10),
                      Expanded(child: statusText),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(flex: 2, child: keywords),
                const SizedBox(width: 10),
                Expanded(flex: 3, child: destination),
                const SizedBox(width: 10),
                archiveButton,
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: statusText,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.controller,
    required this.target,
    required this.session,
    required this.onInspect,
    required this.onPlan,
  });

  final FutureClientController controller;
  final TargetCandidate target;
  final AgentConversationSession? session;
  final ValueChanged<String> onInspect;
  final ValueChanged<String> onPlan;

  @override
  Widget build(BuildContext context) {
    return PanelFrame(
      child: Column(
        children: [
          _ConversationHeader(
            target: target,
            onInspect: onInspect,
            onPlan: onPlan,
          ),
          const Divider(height: 1),
          Expanded(
            child: _MessageList(
              loading: controller.isLoadingConversations,
              session: session,
            ),
          ),
          const Divider(height: 1),
          _RuntimeMessageComposer(
            targetLabel: target.label,
            busy: controller.isSendingConversationMessage,
            onSend: (text) =>
                unawaited(controller.sendConversationMessage(text)),
          ),
        ],
      ),
    );
  }
}

class _ConversationHeader extends StatelessWidget {
  const _ConversationHeader({
    required this.target,
    required this.onInspect,
    required this.onPlan,
  });

  final TargetCandidate target;
  final ValueChanged<String> onInspect;
  final ValueChanged<String> onPlan;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 440;
          final identity = Row(
            children: [
              AgentBrandIcon(
                target: target,
                selected: true,
                detected: target.status != 'not-detected',
                size: 40,
                iconSize: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '${_statusLabel(target, strings)} · ${target.kind}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: compact ? WrapAlignment.start : WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => onInspect(target.target),
                child: Text(strings.inspect),
              ),
              FilledButton(
                onPressed: () => onPlan(target.target),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(strings.plan),
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [identity, const SizedBox(height: 10), actions],
            );
          }

          return Row(
            children: [
              Expanded(child: identity),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({required this.loading, required this.session});

  final bool loading;
  final AgentConversationSession? session;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final messages = session?.messages ?? const <AgentConversationMessage>[];
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
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemBuilder: (context, index) {
        return _MessageBubble(message: messages[index]);
      },
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemCount: messages.length,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AgentConversationMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isUser ? colors.primary : colors.surfaceLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isUser ? strings.you : strings.agent,
                  style: TextStyle(
                    color: isUser
                        ? Color.lerp(colors.primary, colors.textOnPrimary, 0.72)
                        : colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message.text,
                  style: TextStyle(
                    color: isUser ? colors.textOnPrimary : colors.text,
                    height: 1.35,
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

class _RuntimeMessageComposer extends StatefulWidget {
  const _RuntimeMessageComposer({
    required this.targetLabel,
    required this.busy,
    required this.onSend,
  });

  final String targetLabel;
  final bool busy;
  final ValueChanged<String> onSend;

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
    if (text.isEmpty || widget.busy) {
      return;
    }
    _controller.clear();
    widget.onSend(text);
  }

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
              controller: _controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              enabled: !widget.busy,
              decoration: InputDecoration(
                hintText: strings.messageTarget(widget.targetLabel),
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
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton.filled(
              tooltip: strings.send,
              onPressed: widget.busy ? null : _submit,
              icon: widget.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

String _sessionMeta(AgentConversationSession session) {
  final parts = [
    if (session.adapterId.isNotEmpty) session.adapterId,
    if (session.sourceKind.isNotEmpty) session.sourceKind,
    if (session.nativeSessionId.isNotEmpty) session.nativeSessionId,
  ];
  if (parts.isNotEmpty) {
    return parts.join(' · ');
  }
  return session.sourcePath.isEmpty ? session.updatedAt : session.sourcePath;
}

String _sessionPanelMeta(
  AgentConversationSession session,
  LicoStrings strings,
) {
  final messageCount = session.messageCount == 0
      ? session.messages.length
      : session.messageCount;
  return '${strings.messagesCount(messageCount)} · ${_sessionMeta(session)}';
}

String _statusLabel(TargetCandidate target, LicoStrings strings) {
  return switch (target.status) {
    'configured' => strings.configured,
    'detected' => strings.detected,
    'manual' => strings.manual,
    _ => strings.unavailable,
  };
}

Color _statusColor(TargetCandidate target, LicoThemeColors colors) {
  return switch (target.status) {
    'configured' => colors.success,
    'detected' => colors.primary,
    'manual' => colors.warning,
    _ => colors.textMuted,
  };
}
