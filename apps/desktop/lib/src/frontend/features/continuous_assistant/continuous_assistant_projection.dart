import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_child_entry.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_command_intent.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_keys.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_labels.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_parent_card.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Ordinary-chat entry plus typed child cards.
///
/// No Goal / coding / knowledge / new-session mode selector. Rebuilds and
/// dispose emit no commands. Production controller binding is M2.
final class ContinuousAssistantProjection extends StatefulWidget {
  const ContinuousAssistantProjection({
    super.key,
    this.failure,
    this.tasks = const <ContinuousAssistantTaskView>[],
    this.onOpenChild,
    this.onCommand,
    this.composerFocusNode,
    this.composerController,
    this.composerHint,
  });

  final ContinuityFailure? failure;
  final List<ContinuousAssistantTaskView> tasks;
  final ValueChanged<ContinuousAssistantTaskView>? onOpenChild;
  final ValueChanged<ContinuousAssistantCommandIntent>? onCommand;
  final FocusNode? composerFocusNode;
  final TextEditingController? composerController;
  final String? composerHint;

  @override
  State<ContinuousAssistantProjection> createState() =>
      _ContinuousAssistantProjectionState();
}

final class _ContinuousAssistantProjectionState
    extends State<ContinuousAssistantProjection> {
  FocusNode? _ownedFocus;
  TextEditingController? _ownedController;

  FocusNode get _composerFocus => widget.composerFocusNode ?? _ownedFocus!;

  TextEditingController get _composerController =>
      widget.composerController ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.composerFocusNode == null) {
      _ownedFocus = FocusNode(debugLabel: 'continuous-assistant-composer');
    }
    if (widget.composerController == null) {
      _ownedController = TextEditingController();
    }
  }

  @override
  void dispose() {
    _ownedFocus?.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = ContinuousAssistantLabels.of(context);
    final colors = context.licoColors;
    final failure = widget.failure;
    final ordered = orderContinuousAssistantTasksByCardSequence(widget.tasks);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure != null)
          Text(
            '${failure.code.wireName}:${failure.effectClass.wireName}',
            key: ContinuousAssistantKeys.unavailable,
          )
        else
          Expanded(
            child: ListView(
              key: ContinuousAssistantKeys.timeline,
              padding: const EdgeInsets.all(LicoContentSpacing.compact),
              children: [
                for (final task in ordered)
                  Padding(
                    key: ValueKey(task.relation.goalId),
                    padding: const EdgeInsets.only(
                      bottom: LicoContentSpacing.item,
                    ),
                    child: ContinuousAssistantParentCard(
                      task: task,
                      onOpenChild: widget.onOpenChild,
                      onCommand: widget.onCommand,
                    ),
                  ),
                if (ordered.isNotEmpty) ...[
                  Text(
                    labels.childTasks,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: LicoContentSpacing.inline),
                  Column(
                    key: ContinuousAssistantKeys.childList,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final task in ordered)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: LicoContentSpacing.compact,
                          ),
                          child: ContinuousAssistantChildEntry(
                            task: task,
                            onOpenChild: widget.onOpenChild,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(LicoContentSpacing.compact),
          child: Semantics(
            label: labels.composer,
            textField: true,
            child: TextField(
              key: ContinuousAssistantKeys.composer,
              focusNode: _composerFocus,
              controller: _composerController,
              decoration: InputDecoration(
                hintText: widget.composerHint ?? labels.composer,
                filled: true,
                fillColor: colors.surfaceSunken,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LicoRadius.composerField),
                  borderSide: BorderSide(color: colors.line),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
