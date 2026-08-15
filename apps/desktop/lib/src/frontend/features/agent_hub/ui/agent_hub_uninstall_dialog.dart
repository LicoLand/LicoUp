import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Future<bool> showAgentHubUninstallConfirm(
  BuildContext context, {
  required String displayName,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _AgentHubUninstallConfirmDialog(displayName: displayName),
  );
  return confirmed == true;
}

final class _AgentHubUninstallConfirmDialog extends StatefulWidget {
  const _AgentHubUninstallConfirmDialog({required this.displayName});

  final String displayName;

  @override
  State<_AgentHubUninstallConfirmDialog> createState() =>
      _AgentHubUninstallConfirmDialogState();
}

final class _AgentHubUninstallConfirmDialogState
    extends State<_AgentHubUninstallConfirmDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final matches = _controller.text == widget.displayName;
    return AlertDialog(
      key: const Key('agent-hub-uninstall-dialog'),
      title: Text(strings.agentHubUninstall),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(strings.agentHubUninstallTypeConfirm(widget.displayName)),
            const SizedBox(height: 14),
            TextField(
              key: const Key('agent-hub-uninstall-name-field'),
              controller: _controller,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('agent-hub-uninstall-confirm'),
          style: FilledButton.styleFrom(backgroundColor: colors.error),
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(strings.agentHubUninstall),
        ),
      ],
    );
  }
}
