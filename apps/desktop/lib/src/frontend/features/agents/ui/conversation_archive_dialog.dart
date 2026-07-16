import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/agents/archive/conversation_archive_job_controller.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

Future<void> showConversationArchiveDialog(
  BuildContext context,
  ClientController controller, {
  String? sourceAgentId,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ConversationArchiveDialog(
      controller: controller,
      sourceAgentId: sourceAgentId ?? controller.selectedConversationAgentId,
    ),
  );
}

final class _ConversationArchiveDialog extends StatefulWidget {
  const _ConversationArchiveDialog({
    required this.controller,
    required this.sourceAgentId,
  });

  final ClientController controller;
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
    _queryController = TextEditingController(
      text: widget.controller.archiveQueryDraft,
    );
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
    final destination = widget.controller.conversationArchiveDestinationFor(
      selectionMode: _selectionMode,
      sourceAgentId: sourceAgentId,
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
                  widget.controller.archiveQueryDraft = query;
                  Navigator.of(context).pop();
                  if (exact) {
                    unawaited(
                      widget.controller.archiveConversationExactKeyword(
                        query: query,
                        sourceAgentId: sourceAgentId,
                        path: destination,
                      ),
                    );
                  } else {
                    unawaited(
                      widget.controller.archiveAllConversations(
                        sourceAgentId: sourceAgentId,
                        path: destination,
                      ),
                    );
                  }
                }
              : null,
          child: Text(strings.previewAndBackup),
        ),
      ],
    );
  }
}
