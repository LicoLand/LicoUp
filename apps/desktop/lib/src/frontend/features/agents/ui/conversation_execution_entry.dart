import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Presentation command supplied by the owning native or canonical pane.
/// The scope carries no history and never resolves another authority's IDs.
typedef OpenConversationExecution =
    void Function(
      BuildContext context,
      AgentConversationMessage message,
      TargetCandidate target,
      FocusNode returnFocusNode,
    );

class ConversationExecutionScope extends InheritedWidget {
  const ConversationExecutionScope({
    super.key,
    required this.onOpen,
    required super.child,
  });

  final OpenConversationExecution? onOpen;

  static OpenConversationExecution? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ConversationExecutionScope>()
      ?.onOpen;

  @override
  bool updateShouldNotify(ConversationExecutionScope oldWidget) =>
      oldWidget.onOpen != onOpen;
}

/// The sole action in an Agent bubble's outside, upper-right menu.
class ConversationExecutionMenu extends StatefulWidget {
  const ConversationExecutionMenu({
    super.key,
    required this.target,
    required this.message,
  });

  final TargetCandidate target;
  final AgentConversationMessage message;

  @override
  State<ConversationExecutionMenu> createState() =>
      _ConversationExecutionMenuState();
}

class _ConversationExecutionMenuState extends State<ConversationExecutionMenu> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = ConversationExecutionScope.maybeOf(context);
    final strings = LicoStrings.of(context);
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        key: const Key('conversation-execution-menu'),
        focusNode: _focusNode,
        tooltip: strings.executionProcess,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        icon: Icon(
          Icons.more_horiz_rounded,
          size: 19,
          color: context.licoColors.textMuted,
        ),
        onPressed: open == null
            ? null
            : () async {
                final box = context.findRenderObject()! as RenderBox;
                final selected = await showMessagingGlassMenu<String>(
                  context: context,
                  globalPosition: box.localToGlobal(
                    Offset(box.size.width, box.size.height),
                  ),
                  menuKey: const Key('conversation-execution-actions'),
                  actions: [
                    MessagingGlassMenuAction<String>(
                      value: 'execution',
                      label: strings.executionProcess,
                      leading: Icon(
                        Icons.visibility_outlined,
                        size: 17,
                        color: context.licoColors.textMuted,
                      ),
                    ),
                  ],
                );
                if (selected == 'execution' && context.mounted) {
                  open(context, widget.message, widget.target, _focusNode);
                }
              },
      ),
    );
  }
}
