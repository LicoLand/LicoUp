import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

final class AgentOrchestrationRenamePolicyDialog extends StatefulWidget {
  const AgentOrchestrationRenamePolicyDialog({
    super.key,
    required this.initialName,
  });

  final String initialName;

  @override
  State<AgentOrchestrationRenamePolicyDialog> createState() =>
      _AgentOrchestrationRenamePolicyDialogState();
}

final class _AgentOrchestrationRenamePolicyDialogState
    extends State<AgentOrchestrationRenamePolicyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(strings.renamePolicy),
      content: TextField(
        key: const Key('agent-orchestration-policy-name-field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: strings.policyName,
          isDense: true,
          filled: true,
          fillColor: colors.surfaceLow,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('agent-orchestration-policy-rename-save'),
          onPressed: _submit,
          child: Text(strings.save),
        ),
      ],
    );
  }
}
