import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_local_server_card.dart';

final class OptionalCollaborationLocalServerSection extends StatefulWidget {
  const OptionalCollaborationLocalServerSection({
    super.key,
    required this.controller,
    required this.isChinese,
  });

  final OptionalCollaborationWorkflowController controller;
  final bool isChinese;

  @override
  State<OptionalCollaborationLocalServerSection> createState() =>
      _OptionalCollaborationLocalServerSectionState();
}

final class _OptionalCollaborationLocalServerSectionState
    extends State<OptionalCollaborationLocalServerSection> {
  final Set<String> _confirmed = <String>{};

  @override
  Widget build(BuildContext context) {
    final servers = widget.controller.localServers;
    final busy = widget.controller.busy;
    return Card(
      key: const Key('collaboration-local-server-status-section'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.power_settings_new_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isChinese
                        ? '本机组装与部署'
                        : 'Local assembly and deployment',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: const Key('collaboration-local-server-refresh'),
                  onPressed: busy
                      ? null
                      : () => unawaited(
                          widget.controller.loadLocalServerStatus(),
                        ),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(widget.isChinese ? '刷新' : 'Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.isChinese
                  ? '下载、组装与部署启动是三次独立动作。组装产物默认处于待部署状态；部署启动、停止和卸载均需单独直接确认。只会执行 commit、清单、摘要与信任指纹绑定的受签名固定 runner；健康与能力契约验证后才显示为运行中。'
                  : 'Download, assembly, and deploy/start are separate actions. Assembled output awaits deployment by default; deploy/start, stop, and uninstall each need separate direct confirmation. Only the signed fixed runner bound to the commit, inventory, digests, and trust fingerprint executes, and status becomes running only after health and capability verification.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (servers.isEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.isChinese
                    ? '尚未加载或没有本机组装与部署。'
                    : 'No local assembly or deployment is loaded.',
                key: const Key('collaboration-local-server-empty'),
              ),
            ],
            for (final server in servers) ...[
              const Divider(height: 24),
              OptionalCollaborationLocalServerCard(
                server: server,
                confirmed: _confirmed.contains(server.deploymentId),
                busy: busy,
                isChinese: widget.isChinese,
                onConfirmed: (value) => _setConfirmed(server, value == true),
                onStart: () => _run(
                  server,
                  () => widget.controller.startLocalServer(
                    server.deploymentId,
                    confirmed: true,
                  ),
                ),
                onStop: () => _run(
                  server,
                  () => widget.controller.stopLocalServer(
                    server.deploymentId,
                    confirmed: true,
                  ),
                ),
                onUninstall: () => _run(
                  server,
                  () => widget.controller.uninstallLocalServer(
                    server.deploymentId,
                    confirmed: true,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _setConfirmed(OptionalLocalServerState server, bool confirmed) {
    setState(() {
      if (confirmed) {
        _confirmed.add(server.deploymentId);
      } else {
        _confirmed.remove(server.deploymentId);
      }
    });
  }

  Future<void> _run(
    OptionalLocalServerState server,
    Future<bool> Function() operation,
  ) async {
    final completed = await operation();
    if (mounted && completed) {
      setState(() => _confirmed.remove(server.deploymentId));
    }
  }
}
