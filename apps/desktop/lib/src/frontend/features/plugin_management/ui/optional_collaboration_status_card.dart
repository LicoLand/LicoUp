import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationStatusCard extends StatelessWidget {
  const OptionalCollaborationStatusCard({
    super.key,
    required this.state,
    required this.statusLoaded,
    required this.busy,
    required this.isChinese,
    required this.onLoadStatus,
  });

  final OptionalCollaborationRuntimeState? state;
  final bool statusLoaded;
  final bool busy;
  final bool isChinese;
  final VoidCallback onLoadStatus;

  @override
  Widget build(BuildContext context) {
    final plugin = state?.plugin;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    isChinese ? '生命周期状态' : 'Lifecycle status',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('collaboration-load-status'),
                  onPressed: busy ? null : onLoadStatus,
                  icon: const Icon(Icons.refresh_outlined, size: 16),
                  label: Text(isChinese ? '查询状态' : 'Load status'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              !statusLoaded || state == null
                  ? (isChinese
                        ? '尚未查询；未启动任何插件或目录。'
                        : 'Not queried; no plugin or catalog has been started.')
                  : _stateSummary(state!, isChinese),
              key: const Key('collaboration-status-summary'),
            ),
            if (plugin != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                '${isChinese ? '来源' : 'Source'}: ${plugin.sourceUrl}',
                key: const Key('collaboration-installed-source'),
              ),
              const SizedBox(height: 3),
              SelectableText(
                '${isChinese ? '来源 commit' : 'Source commit'}: ${plugin.sourceCommitOid}',
                key: const Key('collaboration-installed-source-commit'),
              ),
              const SizedBox(height: 3),
              SelectableText(
                'SHA-256: ${plugin.packageDigestSha256}',
                key: const Key('collaboration-installed-digest'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _stateSummary(OptionalCollaborationRuntimeState state, bool isChinese) {
  if (isChinese) {
    return '能力：${state.capabilityEnabled ? '已启用' : '已停用'} · '
        '插件：${state.pluginInstalled ? '已安装' : '未安装'} · '
        '目录：${state.pluginLoaded ? '已按需加载' : '未加载'} · '
        'Runner 信任：${state.runnerTrust == null ? '未导入' : '已绑定'}';
  }
  return 'Capability: ${state.capabilityEnabled ? 'enabled' : 'disabled'} · '
      'Plugin: ${state.pluginInstalled ? 'installed' : 'not installed'} · '
      'Catalog: ${state.pluginLoaded ? 'loaded on demand' : 'not loaded'} · '
      'Runner trust: ${state.runnerTrust == null ? 'not imported' : 'bound'}';
}
