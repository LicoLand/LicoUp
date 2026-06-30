import 'package:flutter/material.dart';

import '../l10n/lico_strings.dart';

class ManualTargetDraft {
  const ManualTargetDraft({
    required this.target,
    required this.configPath,
    required this.binaryPath,
    required this.historyRoot,
  });

  final String target;
  final String configPath;
  final String binaryPath;
  final String historyRoot;
}

class ManualTargetDialog extends StatefulWidget {
  const ManualTargetDialog({super.key});

  @override
  State<ManualTargetDialog> createState() => _ManualTargetDialogState();
}

class _ManualTargetDialogState extends State<ManualTargetDialog> {
  static const _targets = [
    ('antigravity', 'Antigravity'),
    ('claude-code', 'Claude Code'),
    ('codex', 'Codex'),
    ('cursor', 'Cursor'),
    ('copilot', 'GitHub Copilot'),
    ('hermes', 'Hermes Agent'),
    ('kilo-code', 'Kilo Code'),
    ('openclaw', 'OpenClaw'),
    ('opencode', 'OpenCode'),
  ];

  final _configPathController = TextEditingController();
  final _binaryPathController = TextEditingController();
  final _historyRootController = TextEditingController();
  String _target = _targets.first.$1;

  @override
  void dispose() {
    _configPathController.dispose();
    _binaryPathController.dispose();
    _historyRootController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return AlertDialog(
      title: Text(strings.addTarget),
      key: const Key('manual-target-dialog'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _target,
              decoration: InputDecoration(labelText: strings.target),
              items: [
                for (final target in _targets)
                  DropdownMenuItem(value: target.$1, child: Text(target.$2)),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() {
                  _target = value;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _configPathController,
              decoration: InputDecoration(labelText: strings.configPath),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _binaryPathController,
              decoration: InputDecoration(labelText: strings.binaryPath),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _historyRootController,
              decoration: InputDecoration(labelText: strings.historyRoot),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('manual-target-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('manual-target-submit'),
          onPressed: _submit,
          child: Text(strings.addTarget),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(
      ManualTargetDraft(
        target: _target,
        configPath: _configPathController.text.trim(),
        binaryPath: _binaryPathController.text.trim(),
        historyRoot: _historyRootController.text.trim(),
      ),
    );
  }
}
