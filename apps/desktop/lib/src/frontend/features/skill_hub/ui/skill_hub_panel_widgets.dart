import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

/// Floating right-side settings drawer for the Skill Hub panel. It is inserted
/// as an [OverlayEntry] without a modal barrier, so the underlying page keeps
/// its layout and stays scrollable while the drawer is open.
class SkillHubSettingsDrawer extends StatelessWidget {
  const SkillHubSettingsDrawer({
    super.key,
    required this.controller,
    required this.urlController,
    required this.onInstall,
    required this.onClose,
  });

  final ClientController controller;
  final TextEditingController urlController;
  final Future<void> Function() onInstall;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final theme = Theme.of(context);
    return Positioned(
      top: 12,
      right: 12,
      bottom: 12,
      width: 380,
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surface,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.settings,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: strings.hideSkillHubSettings,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onClose,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        strings.installFromGitHub,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: urlController,
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'GitHub URL',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) {
                          if (!controller.isSkillHubBusy) onInstall();
                        },
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: controller.isSkillHubBusy
                              ? null
                              : () {
                                  onInstall();
                                },
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: Text(strings.install),
                        ),
                      ),
                      if (controller.skillInstallResult != null) ...[
                        const SizedBox(height: 16),
                        _ResultSummary(
                          title: strings.installResult,
                          result: controller.skillInstallResult!,
                          keys: const [
                            'status',
                            'skillId',
                            'installDir',
                            'packageDigestSha256',
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ResultSummary extends StatelessWidget {
  const _ResultSummary({
    required this.title,
    required this.result,
    required this.keys,
  });

  final String title;
  final Map<String, dynamic> result;
  final List<String> keys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = LicoStrings.of(context);
    final entries = keys
        .where(
          (key) => result[key] != null && result[key].toString().isNotEmpty,
        )
        .map((key) => MapEntry(key, result[key].toString()))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: SelectableText(
              '${_skillResultKeyLabel(strings, entry.key)}: '
              '${_skillResultValueLabel(strings, entry.key, entry.value)}',
            ),
          ),
      ],
    );
  }
}

String _skillResultKeyLabel(LicoStrings strings, String key) {
  return switch (key) {
    'status' => strings.status,
    'skillId' => strings.skillId,
    'installDir' => strings.isChinese ? '安装位置' : 'Install Directory',
    'packageDigestSha256' =>
      strings.isChinese ? '软件包 SHA-256 摘要' : 'Package SHA-256 Digest',
    _ => key,
  };
}

String _skillResultValueLabel(LicoStrings strings, String key, String value) {
  if (key != 'status') return value;
  return switch (value.trim().toLowerCase()) {
    'installed' || 'applied' => strings.isChinese ? '已安装' : 'Installed',
    'blocked' => strings.isChinese ? '已阻止' : 'Blocked',
    'failed' || 'error' => strings.isChinese ? '失败' : 'Failed',
    _ => value,
  };
}
