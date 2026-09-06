import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

Future<void> showCreateCanonicalGroupConversationDialog({
  required BuildContext context,
  required IntentSink<ConversationIntent> intents,
  required EffectSource<ConversationEffect> effects,
  required List<TargetCandidate> targets,
}) async {
  final candidates = targets
      .where((target) => target.isConversationAgent && target.canRelayRuntime)
      .toList(growable: false);
  await showDialog<void>(
    context: context,
    builder: (context) => _CreateCanonicalGroupConversationDialog(
      intents: intents,
      effects: effects,
      candidates: candidates,
    ),
  );
}

class _CreateCanonicalGroupConversationDialog extends StatefulWidget {
  const _CreateCanonicalGroupConversationDialog({
    required this.intents,
    required this.effects,
    required this.candidates,
  });

  final IntentSink<ConversationIntent> intents;
  final EffectSource<ConversationEffect> effects;
  final List<TargetCandidate> candidates;

  @override
  State<_CreateCanonicalGroupConversationDialog> createState() =>
      _CreateCanonicalGroupConversationDialogState();
}

class _CreateCanonicalGroupConversationDialogState
    extends State<_CreateCanonicalGroupConversationDialog> {
  final _title = TextEditingController();
  final _selected = <String>{};
  var _creating = false;
  var _failureCode = '';
  StreamSubscription<ConversationEffect>? _effectSubscription;

  @override
  void initState() {
    super.initState();
    _effectSubscription = widget.effects.effects.listen(_handleEffect);
  }

  @override
  void dispose() {
    unawaited(_effectSubscription?.cancel());
    _title.dispose();
    super.dispose();
  }

  void _handleEffect(ConversationEffect effect) {
    if (!mounted || !_creating) return;
    switch (effect) {
      case CanonicalConversationGroupCreated():
        Navigator.of(context).pop();
      case ConversationActionRejected(:final stage, :final reasonCode)
          when stage == 'canonical-create':
        setState(() {
          _creating = false;
          _failureCode = reasonCode;
        });
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final canCreate =
        !_creating && _title.text.trim().isNotEmpty && _selected.isNotEmpty;
    return AlertDialog(
      key: const Key('canonical-group-create-dialog'),
      title: Text(strings.newGroupConversation),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('canonical-group-title-field'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: strings.groupConversationName,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            Text(
              strings.selectGroupConversationAgents,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (widget.candidates.isEmpty)
              Text(
                strings.groupConversationNeedsAgent,
                style: TextStyle(color: context.licoColors.error),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.candidates.length,
                  itemBuilder: (context, index) {
                    final candidate = widget.candidates[index];
                    final checked = _selected.contains(candidate.target);
                    return CheckboxListTile(
                      key: ValueKey<String>(
                        'canonical-group-member-${candidate.target}',
                      ),
                      value: checked,
                      title: Text(
                        agentConversationTargetDisplayName(candidate),
                      ),
                      secondary: MessagingAgentAvatar(
                        target: candidate,
                        size: 32,
                        iconSize: 18,
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      onChanged: (value) => setState(() {
                        value == true
                            ? _selected.add(candidate.target)
                            : _selected.remove(candidate.target);
                      }),
                    );
                  },
                ),
              ),
            if (_failureCode.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                key: const Key('canonical-group-create-failure'),
                strings.groupConversationFailure('create', _failureCode),
                style: TextStyle(color: context.licoColors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const Key('canonical-group-create-confirm'),
          onPressed: canCreate ? _create : null,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return colors.surfaceLow.withValues(alpha: 0.5);
              }
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return colors.primaryStrong;
              }
              return colors.primary;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.disabled)
                  ? colors.textDisabled
                  : colors.textOnPrimary;
            }),
          ),
          child: _creating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.createGroupConversation),
        ),
      ],
    );
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _failureCode = '';
    });
    final members = [
      for (final candidate in widget.candidates)
        if (_selected.contains(candidate.target))
          ClientConversationGroupMemberDraft(
            agentId: candidate.target,
            displayName: agentConversationTargetDisplayName(candidate),
          ),
    ];
    widget.intents.send(
      CreateCanonicalConversationGroup(title: _title.text, members: members),
    );
  }
}
