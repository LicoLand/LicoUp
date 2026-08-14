import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentConversationRecentSessions extends StatelessWidget {
  const AgentConversationRecentSessions({
    super.key,
    required this.sessions,
    this.runningSessionIds = const {},
    required this.loading,
    this.hasMore = false,
    this.loadingMore = false,
    required this.onNewConversation,
    required this.onSelectSession,
    this.onLoadMore,
    this.topOverlayInset = 0,
    this.bottomOverlayInset = 0,
  });

  final List<AgentConversationSession> sessions;
  final Set<String> runningSessionIds;
  final bool loading;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onNewConversation;
  final ValueChanged<String> onSelectSession;
  final VoidCallback? onLoadMore;
  final double topOverlayInset;
  final double bottomOverlayInset;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LicoContentSpacing.section,
        LicoContentSpacing.item + topOverlayInset,
        LicoContentSpacing.section,
        LicoContentSpacing.section + bottomOverlayInset,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 460),
          child: SizedBox.expand(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final recent = _RecentSessionsList(
                  sessions: sessions,
                  runningSessionIds: runningSessionIds,
                  loading: loading,
                  hasMore: hasMore,
                  loadingMore: loadingMore,
                  emptyLabel: strings.noNativeHistories,
                  onSelectSession: onSelectSession,
                  onLoadMore: onLoadMore,
                );
                final newConversation = _NewConversationCard(
                  label: strings.newConversation,
                  onTap: onNewConversation,
                );
                if (constraints.maxWidth < 680) {
                  return Column(
                    key: const Key('agent-conversation-home-stacked'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      newConversation,
                      const SizedBox(height: 20),
                      Expanded(child: recent),
                    ],
                  );
                }
                return Row(
                  key: const Key('agent-conversation-home-split'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 220,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: double.infinity,
                          child: newConversation,
                        ),
                      ),
                    ),
                    const SizedBox(width: 36),
                    Expanded(child: recent),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NewConversationCard extends StatelessWidget {
  const _NewConversationCard({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      key: const Key('agent-conversation-home-new-conversation'),
      color: colors.surfaceLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.card),
        side: BorderSide(color: colors.line.withAlpha(120), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: LicoContentSpacing.compact,
          ),
          child: Row(
            children: [
              Icon(Icons.add_comment_outlined, color: colors.text, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentSessionsList extends StatefulWidget {
  const _RecentSessionsList({
    required this.sessions,
    required this.runningSessionIds,
    required this.loading,
    required this.hasMore,
    required this.loadingMore,
    required this.emptyLabel,
    required this.onSelectSession,
    required this.onLoadMore,
  });

  final List<AgentConversationSession> sessions;
  final Set<String> runningSessionIds;
  final bool loading;
  final bool hasMore;
  final bool loadingMore;
  final String emptyLabel;
  final ValueChanged<String> onSelectSession;
  final VoidCallback? onLoadMore;

  @override
  State<_RecentSessionsList> createState() => _RecentSessionsListState();
}

class _RecentSessionsListState extends State<_RecentSessionsList> {
  bool _loadRequested = false;

  @override
  void didUpdateWidget(covariant _RecentSessionsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.hasMore ||
        widget.sessions.length != oldWidget.sessions.length ||
        (oldWidget.loadingMore && !widget.loadingMore)) {
      _loadRequested = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      key: const Key('agent-conversation-recent-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          LicoStrings.of(context).recentConversations,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            height: 1,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(child: _body(context)),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.licoColors;
    if (widget.sessions.isEmpty) {
      if (widget.loading) {
        return const Center(
          key: Key('agent-conversation-recent-loading'),
          child: CircularProgressIndicator(),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            widget.emptyLabel,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (widget.hasMore &&
            !widget.loadingMore &&
            !_loadRequested &&
            notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter <= 80) {
          _loadRequested = true;
          widget.onLoadMore?.call();
        }
        return false;
      },
      child: Scrollbar(
        child: ListView.separated(
          key: const Key('agent-conversation-recent-list'),
          padding: EdgeInsets.zero,
          itemCount: widget.sessions.length + (widget.loadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == widget.sessions.length) {
              return const SizedBox(
                key: Key('agent-conversation-recent-loading-more'),
                height: 36,
                child: Center(
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final session = widget.sessions[index];
            return _RecentSessionRow(
              key: Key('agent-conversation-recent-${session.id}'),
              session: session,
              running: widget.runningSessionIds.contains(session.id),
              onTap: () => widget.onSelectSession(session.id),
            );
          },
          separatorBuilder: (context, index) => Divider(
            key: Key('agent-conversation-recent-divider-$index'),
            height: 1,
            color: colors.line.withAlpha(72),
          ),
        ),
      ),
    );
  }
}

class _RecentSessionRow extends StatefulWidget {
  const _RecentSessionRow({
    super.key,
    required this.session,
    required this.running,
    required this.onTap,
  });

  final AgentConversationSession session;
  final bool running;
  final VoidCallback onTap;

  @override
  State<_RecentSessionRow> createState() => _RecentSessionRowState();
}

class _RecentSessionRowState extends State<_RecentSessionRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final session = widget.session;
    final title = session.title.trim().isEmpty ? session.id : session.title;
    final preview = conversationMessagePreviewText(session.preview);
    final updatedLabel = conversationSessionRelativeUpdatedAtLabel(session);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (hovered) => setState(() => _hovered = hovered),
        borderRadius: BorderRadius.circular(LicoRadius.well),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          decoration: BoxDecoration(
            color: _hovered
                ? (colors.isDark ? colors.surfaceLow : colors.surface)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(LicoRadius.well),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.running) ...[
                    const SizedBox(width: 8),
                    LicoSpinningRefreshIcon(
                      key: Key(
                        'agent-conversation-recent-running-${session.id}',
                      ),
                      size: 13,
                      color: colors.textMuted,
                    ),
                  ],
                  if (updatedLabel.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(
                      updatedLabel,
                      maxLines: 1,
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
