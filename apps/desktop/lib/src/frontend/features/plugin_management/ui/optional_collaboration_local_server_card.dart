import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';

final class OptionalCollaborationLocalServerCard extends StatelessWidget {
  const OptionalCollaborationLocalServerCard({
    super.key,
    required this.server,
    required this.confirmed,
    required this.busy,
    required this.isChinese,
    required this.onConfirmed,
    required this.onStart,
    required this.onStop,
    required this.onUninstall,
  });

  final OptionalLocalServerState server;
  final bool confirmed;
  final bool busy;
  final bool isChinese;
  final ValueChanged<bool?> onConfirmed;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onUninstall;

  @override
  Widget build(BuildContext context) {
    final enabled = confirmed && !busy;
    return Column(
      key: Key('collaboration-local-server-${server.deploymentId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Fact(label: isChinese ? '状态' : 'Status', value: server.status),
        _Fact(
          label: isChinese ? '来源版本' : 'Source version',
          value: server.serverVersion,
        ),
        _Fact(
          label: isChinese ? '下载来源' : 'Download source',
          value: server.sourceUrl,
        ),
        _Fact(
          label: isChinese ? '已选组件' : 'Components',
          value: server.selectedComponentIds.join(', '),
        ),
        _Fact(
          label: isChinese ? '组装目标' : 'Assembly target',
          value: server.destination,
        ),
        _Fact(
          label: isChinese ? '组装适配器' : 'Assembly adapter',
          value: server.assemblyAdapterId,
        ),
        _Fact(
          label: isChinese ? '运行能力' : 'Runtime capability',
          value: optionalLocalServerRuntimeCapability,
        ),
        _Fact(label: 'Source commit', value: server.sourceCommitOid),
        _Fact(
          label: isChinese ? 'Runner 目标' : 'Runner target',
          value: '${server.runnerPlatform}/${server.runnerArchitecture}',
        ),
        _Fact(
          label: isChinese ? 'Runner 摘要' : 'Runner digest',
          value: server.runnerDigestSha256,
        ),
        _Fact(
          label: isChinese ? 'Runner 契约' : 'Runner contract',
          value: server.runnerContractVersion,
        ),
        _Fact(
          label: isChinese ? '健康契约' : 'Health contract',
          value: server.healthContractVersion,
        ),
        _Fact(
          label: isChinese ? '能力契约' : 'Capabilities contract',
          value: server.capabilitiesContractVersion,
        ),
        _Fact(
          label: isChinese ? '信任 key ID' : 'Trust key ID',
          value: server.runnerTrustKeyId,
        ),
        _Fact(
          label: isChinese ? '信任指纹' : 'Trust fingerprint',
          value: server.runnerTrustFingerprintSha256,
        ),
        _Fact(
          label: isChinese ? '健康验证' : 'Health verified',
          value: server.healthVerified.toString(),
        ),
        _Fact(
          label: isChinese ? '能力验证' : 'Capabilities verified',
          value: server.capabilitiesVerified.toString(),
        ),
        _Fact(
          label: isChinese ? '回环端点' : 'Loopback endpoint',
          value: 'http://${server.bindHost}:${server.port}',
        ),
        _Fact(
          label: isChinese ? '组装清单摘要' : 'Assembly manifest digest',
          value: server.assemblyManifestDigestSha256,
        ),
        CheckboxListTile(
          key: Key('collaboration-local-server-confirm-${server.deploymentId}'),
          contentPadding: EdgeInsets.zero,
          value: confirmed,
          onChanged: busy ? null : onConfirmed,
          title: Text(
            isChinese
                ? '我已核对状态、commit、runner 目标与契约、精确摘要和信任指纹，并单独直接批准下方一次动作。'
                : 'I reviewed the state, commit, runner target and contracts, exact digests, and trust fingerprint and separately approve one action below.',
          ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            if (server.isAwaitingDeployment)
              FilledButton(
                key: Key(
                  'collaboration-local-server-start-${server.deploymentId}',
                ),
                onPressed: enabled ? onStart : null,
                child: Text(
                  isChinese
                      ? '部署并启动受签名 runner'
                      : 'Deploy and start signed runner',
                ),
              )
            else
              FilledButton(
                key: Key(
                  'collaboration-local-server-stop-${server.deploymentId}',
                ),
                onPressed: enabled ? onStop : null,
                child: Text(isChinese ? '停止本机部署' : 'Stop local deployment'),
              ),
            OutlinedButton(
              key: Key(
                'collaboration-local-server-uninstall-${server.deploymentId}',
              ),
              onPressed: enabled && server.isAwaitingDeployment
                  ? onUninstall
                  : null,
              child: Text(isChinese ? '卸载组装' : 'Uninstall assembly'),
            ),
          ],
        ),
      ],
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 136, child: Text(label)),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
