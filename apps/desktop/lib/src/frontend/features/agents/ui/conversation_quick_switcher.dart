import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

/// Opens the quick switcher: one field that filters group conversations,
/// agent conversations and the shell's [apps]. Choosing a conversation
/// selects it; choosing an app calls [onOpenApp].
Future<void> showConversationQuickSwitcher(
  BuildContext context, {
  required AgentsBinding agents,
  required ConversationBinding conversation,
  required List<LayoutQuickSwitcherApp> apps,
  required ValueChanged<String> onOpenApp,
}) {
  final strings = LicoStrings.of(context);
  final groups = [
    for (final group in conversation.canonicalEvents.current.groupConversations)
      if (!group.archived)
        _SwitcherItem.group(
          id: group.id,
          label: group.title.trim().isEmpty
              ? strings.groupConversation
              : group.title.trim(),
        ),
  ];
  final agentItems = [
    for (final target in agents.projection.current.targetDetails)
      if (target.isConversationAgent)
        _SwitcherItem.agent(
          target: target,
          label: agentConversationTargetDisplayName(target),
        ),
  ];
  final appItems = [for (final app in apps) _SwitcherItem.app(app: app)];
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withAlpha(36),
    builder: (dialogContext) => _ConversationQuickSwitcher(
      conversations: [...groups, ...agentItems],
      apps: appItems,
      onChoose: (item) {
        switch (item.kind) {
          case _SwitcherKind.group:
            conversation.intents.send(SelectCanonicalConversation(item.id));
          case _SwitcherKind.agent:
            agents.intents.send(StartAgentConversation(item.id));
          case _SwitcherKind.app:
            onOpenApp(item.id);
        }
      },
    ),
  );
}

enum _SwitcherKind { group, agent, app }

final class _SwitcherItem {
  _SwitcherItem.group({required this.id, required this.label})
    : kind = _SwitcherKind.group,
      target = null,
      icon = Icons.groups_2_outlined;

  _SwitcherItem.agent({
    required TargetCandidate this.target,
    required this.label,
  }) : kind = _SwitcherKind.agent,
       id = target.id,
       icon = null;

  _SwitcherItem.app({required LayoutQuickSwitcherApp app})
    : kind = _SwitcherKind.app,
      id = app.id,
      label = app.label,
      target = null,
      icon = app.icon;

  final _SwitcherKind kind;
  final String id;
  final String label;
  final TargetCandidate? target;
  final IconData? icon;

  String get key => '${kind.name}:$id';
}

final class _ConversationQuickSwitcher extends StatefulWidget {
  const _ConversationQuickSwitcher({
    required this.conversations,
    required this.apps,
    required this.onChoose,
  });

  final List<_SwitcherItem> conversations;
  final List<_SwitcherItem> apps;
  final ValueChanged<_SwitcherItem> onChoose;

  @override
  State<_ConversationQuickSwitcher> createState() =>
      _ConversationQuickSwitcherState();
}

final class _ConversationQuickSwitcherState
    extends State<_ConversationQuickSwitcher> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  List<_SwitcherItem> _filter(List<_SwitcherItem> items) {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return items;
    return [
      for (final item in items)
        if (item.label.toLowerCase().contains(query)) item,
    ];
  }

  void _choose(_SwitcherItem item) {
    Navigator.of(context).pop();
    widget.onChoose(item);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event, int count) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (count == 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1) % count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1 + count) % count);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final conversations = _filter(widget.conversations);
    final apps = _filter(widget.apps);
    final ordered = [...conversations, ...apps];
    final selected = ordered.isEmpty
        ? -1
        : _selected.clamp(0, ordered.length - 1);
    final rows = <Widget>[];
    void section(String label, List<_SwitcherItem> items, int offset) {
      if (items.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(
            label,
            style: LicoTypography.eyebrow(color: colors.textDisabled),
          ),
        ),
      );
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        rows.add(
          _SwitcherRow(
            key: ValueKey<String>('quick-switcher-${item.key}'),
            item: item,
            selected: offset + index == selected,
            onTap: () => _choose(item),
          ),
        );
      }
    }

    section(strings.conversations, conversations, 0);
    section(strings.quickSwitcherApps, apps, conversations.length);

    return Dialog(
      key: const Key('conversation-quick-switcher'),
      alignment: const Alignment(0, -0.6),
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: MessagingGlassOptionCard(
          borderRadius: BorderRadius.circular(
            MessagingDesktopMetrics.conversationListCardCornerRadius,
          ),
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                child: Focus(
                  onKeyEvent: (node, event) =>
                      _handleKey(node, event, ordered.length),
                  child: TextField(
                    key: const Key('conversation-quick-switcher-field'),
                    controller: _query,
                    focusNode: _queryFocus,
                    autofocus: true,
                    onChanged: (_) => setState(() => _selected = 0),
                    onSubmitted: (_) {
                      if (selected >= 0) _choose(ordered[selected]);
                    },
                    decoration: InputDecoration(
                      hintText: strings.quickSwitcherHint,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: colors.line),
              Flexible(
                child: ordered.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          strings.noConversationSearchResults,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.textMuted),
                        ),
                      )
                    : ListView(
                        key: const Key('conversation-quick-switcher-results'),
                        padding: const EdgeInsets.only(bottom: 8),
                        shrinkWrap: true,
                        children: rows,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SwitcherRow extends StatelessWidget {
  const _SwitcherRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _SwitcherItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final target = item.target;
    final Widget leading = target != null
        ? MessagingAgentAvatar(target: target, size: 24, iconSize: 14)
        : Icon(item.icon, size: 18, color: colors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: MessagingGlassMenuItem(
        label: item.label,
        leading: SizedBox.square(dimension: 24, child: Center(child: leading)),
        selected: selected,
        trailing: item.kind == _SwitcherKind.app
            ? Icon(Icons.north_east_rounded, size: 13, color: colors.textMuted)
            : const SizedBox.shrink(),
        onTap: onTap,
      ),
    );
  }
}
