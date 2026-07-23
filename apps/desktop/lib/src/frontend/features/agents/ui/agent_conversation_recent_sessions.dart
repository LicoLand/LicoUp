import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentConversationRecentSessions extends StatelessWidget {
  const AgentConversationRecentSessions({
    super.key,
    required this.sessions,
    required this.loading,
    required this.onSelectSession,
  });

  final List<AgentConversationSession> sessions;
  final bool loading;
  final ValueChanged<String> onSelectSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (sessions.isEmpty) {
      if (loading) {
        return const Center(
          key: Key('agent-conversation-recent-loading'),
          child: CircularProgressIndicator(),
        );
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            strings.noNativeHistories,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.recentConversations,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  height: 1,
                ),
              ),
              const SizedBox(height: 8),
              for (final session in sessions)
                _RecentSessionRow(
                  key: Key('agent-conversation-recent-${session.id}'),
                  session: session,
                  onTap: () => onSelectSession(session.id),
                ),
            ],
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
    required this.onTap,
  });

  final AgentConversationSession session;
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (hovered) => setState(() => _hovered = hovered),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: _hovered
                  ? (colors.isDark ? colors.surfaceLow : colors.surface)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.line.withAlpha(80), width: 0.5),
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
      ),
    );
  }
}
