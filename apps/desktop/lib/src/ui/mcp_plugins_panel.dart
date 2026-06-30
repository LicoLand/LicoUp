import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../services/agent_service.dart';
import 'panel_frame.dart';

class McpPluginsPanel extends StatelessWidget {
  const McpPluginsPanel({super.key, required this.controller});

  final FutureClientController controller;

  @override
  Widget build(BuildContext context) {
    final targets = controller.scannedTargets
        .where((target) => target.visibleInClient)
        .toList(growable: false);
    return PanelFrame(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('LicoLite MCP Plugins'),
            subtitle: const Text(
              'Update target-native MCP config and rollback from snapshots.',
            ),
            trailing: IconButton(
              tooltip: 'Refresh targets',
              onPressed: controller.isScanningTargets
                  ? null
                  : controller.scanTargets,
              icon: controller.isScanningTargets
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: targets.isEmpty ? 1 : targets.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (targets.isEmpty) {
                  return const ListTile(
                    leading: Icon(Icons.extension_outlined),
                    title: Text('No targets scanned'),
                    subtitle: Text(
                      'Run target scan before managing LicoLite MCP plugins.',
                    ),
                  );
                }
                final target = targets[index];
                final status = controller.mcpPluginStatuses[target.target];
                return _McpPluginTile(
                  target: target,
                  status: status,
                  busy: controller.isMcpPluginBusy(target.target),
                  onStatus: () => controller.refreshMcpPluginStatus(target),
                  onUpdate: target.canUpdateMcpPlugin
                      ? () => controller.updateMcpPlugin(target)
                      : null,
                  onRollback: target.canRollbackMcpPlugin
                      ? () => controller.rollbackLatestMcpPlugin(target)
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _McpPluginTile extends StatelessWidget {
  const _McpPluginTile({
    required this.target,
    required this.status,
    required this.busy,
    required this.onStatus,
    required this.onUpdate,
    required this.onRollback,
  });

  final TargetCandidate target;
  final Map<String, dynamic>? status;
  final bool busy;
  final VoidCallback onStatus;
  final VoidCallback? onUpdate;
  final VoidCallback? onRollback;

  @override
  Widget build(BuildContext context) {
    final statusLabel =
        (status?['status'] ??
                (target.configured ? 'configured' : target.status))
            .toString();
    final configPath =
        target.configPath ?? target.detail ?? 'No config path detected';
    final isUnsupported = target.adapterStatus == 'unsupported';
    final isPartial = target.adapterStatus == 'partial';

    return ListTile(
      leading: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.extension_outlined),
      title: Row(
        children: [
          Expanded(child: Text('${target.label} / LicoLite MCP')),
          if (isUnsupported)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Unsupported',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          if (isPartial)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Partial',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(configPath, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(statusLabel),
          IconButton(
            tooltip: 'Plugin status',
            onPressed: busy ? null : onStatus,
            icon: const Icon(Icons.fact_check_outlined),
          ),
          if (onUpdate != null)
            FilledButton.icon(
              onPressed: busy ? null : onUpdate,
              icon: const Icon(Icons.system_update_alt_outlined, size: 18),
              label: const Text('Update'),
            ),
          if (onRollback != null)
            OutlinedButton.icon(
              onPressed: busy ? null : onRollback,
              icon: const Icon(
                Icons.settings_backup_restore_outlined,
                size: 18,
              ),
              label: const Text('Rollback'),
            ),
        ],
      ),
    );
  }
}
