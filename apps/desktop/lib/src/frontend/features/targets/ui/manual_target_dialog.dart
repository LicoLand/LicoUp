import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';

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
  const ManualTargetDialog({super.key, this.onOpenDirectory});

  final FutureOr<void> Function(String path)? onOpenDirectory;

  @override
  State<ManualTargetDialog> createState() => _ManualTargetDialogState();
}

class _ManualTargetDialogState extends State<ManualTargetDialog> {
  static const _targets = [
    'antigravity',
    'claude-code',
    'codex',
    'cursor',
    'copilot',
    'hermes',
    'kilo-code',
    'kimi',
    'kimi-code',
    'openclaw',
    'opencode',
  ];

  final _configPathController = TextEditingController();
  final _binaryPathController = TextEditingController();
  final _historyRootController = TextEditingController();
  String _target = _targets.first;

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
                  DropdownMenuItem(
                    value: target,
                    child: Text(agentProductLabel(target)),
                  ),
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
            DirectoryPathField(
              title: strings.configPath,
              label: strings.configPath,
              controller: _configPathController,
              showHeader: false,
              compactBreakpoint: 360,
              padding: EdgeInsets.zero,
              onOpen: (path) => _openDirectory(p.dirname(path)),
            ),
            const SizedBox(height: 12),
            DirectoryPathField(
              title: strings.binaryPath,
              label: strings.binaryPath,
              controller: _binaryPathController,
              showHeader: false,
              compactBreakpoint: 360,
              padding: EdgeInsets.zero,
              onOpen: (path) => _openDirectory(p.dirname(path)),
            ),
            const SizedBox(height: 12),
            DirectoryPathField(
              title: strings.historyRoot,
              label: strings.historyRoot,
              controller: _historyRootController,
              showHeader: false,
              compactBreakpoint: 360,
              padding: EdgeInsets.zero,
              onOpen: _openDirectory,
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

  Future<void> _openDirectory(String path) async {
    final opener = widget.onOpenDirectory;
    if (opener == null) {
      return;
    }
    await opener(path);
  }
}
