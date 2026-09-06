import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

const String conversationArchiveAllSelection = 'all';
const String conversationArchiveExactKeywordSelection = 'exact-keyword';

final class ConversationArchiveActions {
  const ConversationArchiveActions({
    required this.initialQuery,
    required this.destinationFor,
    required this.archiveAll,
    required this.archiveExactKeyword,
  });

  final String initialQuery;
  final String Function(String selectionMode, String sourceAgentId)
  destinationFor;
  final void Function(String sourceAgentId, String destination) archiveAll;
  final void Function(String query, String sourceAgentId, String destination)
  archiveExactKeyword;
}

Future<void> showConversationArchiveDialog(
  BuildContext context, {
  required ConversationArchiveActions actions,
  required String sourceAgentId,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ConversationArchiveDialog(
      actions: actions,
      sourceAgentId: sourceAgentId,
    ),
  );
}

final class _ConversationArchiveDialog extends StatefulWidget {
  const _ConversationArchiveDialog({
    required this.actions,
    required this.sourceAgentId,
  });

  final ConversationArchiveActions actions;
  final String sourceAgentId;

  @override
  State<_ConversationArchiveDialog> createState() =>
      _ConversationArchiveDialogState();
}

final class _ConversationArchiveDialogState
    extends State<_ConversationArchiveDialog> {
  late final TextEditingController _queryController;
  String _selectionMode = conversationArchiveAllSelection;

  @override
  void initState() {
    super.initState();
    _queryController = TextEditingController(text: widget.actions.initialQuery);
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final exact = _selectionMode == conversationArchiveExactKeywordSelection;
    final sourceAgentId = widget.sourceAgentId.trim();
    final destination = widget.actions.destinationFor(
      _selectionMode,
      sourceAgentId,
    );
    final canSubmit =
        destination.isNotEmpty &&
        (!exact || _queryController.text.trim().isNotEmpty);
    return AlertDialog(
      title: Text(strings.backupConversations),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              key: const Key('conversation-archive-selection-mode'),
              segments: [
                ButtonSegment(
                  value: conversationArchiveAllSelection,
                  label: Text(strings.allConversations),
                ),
                ButtonSegment(
                  value: conversationArchiveExactKeywordSelection,
                  label: Text(strings.exactKeyword),
                ),
              ],
              selected: {_selectionMode},
              onSelectionChanged: (selection) {
                setState(() => _selectionMode = selection.single);
              },
            ),
            if (exact) ...[
              const SizedBox(height: 14),
              TextField(
                key: const Key('conversation-archive-exact-query'),
                controller: _queryController,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: strings.exactKeyword),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              destination.isEmpty
                  ? strings.archiveDestinationRequired
                  : strings.archiveDestination(destination),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('conversation-archive-confirm'),
          onPressed: canSubmit
              ? () {
                  final query = _queryController.text.trim();
                  Navigator.of(context).pop();
                  if (exact) {
                    widget.actions.archiveExactKeyword(
                      query,
                      sourceAgentId,
                      destination,
                    );
                  } else {
                    widget.actions.archiveAll(sourceAgentId, destination);
                  }
                }
              : null,
          child: Text(strings.previewAndBackup),
        ),
      ],
    );
  }
}
