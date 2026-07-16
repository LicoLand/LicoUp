import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';

final class OptionalCollaborationWorkflowPlanReview extends StatelessWidget {
  const OptionalCollaborationWorkflowPlanReview({
    super.key,
    required this.plan,
    required this.confirmed,
    required this.busy,
    required this.isChinese,
    required this.keyPrefix,
    required this.onConfirmed,
    required this.onApply,
    required this.onCancel,
  });

  final OptionalCollaborationWorkflowPlan plan;
  final bool confirmed;
  final bool busy;
  final bool isChinese;
  final String keyPrefix;
  final ValueChanged<bool?> onConfirmed;
  final VoidCallback? onApply;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('$keyPrefix-plan-review'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isChinese ? '精确计划核对' : 'Exact plan review',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _ReviewLine(
              label: isChinese ? '选择' : 'Selection',
              value: plan.selectedIds.join(', '),
              valueKey: Key('$keyPrefix-plan-selection'),
            ),
            if (plan.destination.isNotEmpty)
              _ReviewLine(
                label: isChinese ? '目标' : 'Destination',
                value: plan.destination,
                valueKey: Key('$keyPrefix-plan-destination'),
              ),
            if (plan.localAssembly case final assembly?) ...[
              _ReviewLine(
                label: isChinese ? '下载来源' : 'Download source',
                value: assembly.sourceUrl,
              ),
              _ReviewLine(
                label: isChinese ? '服务端版本' : 'Server version',
                value: assembly.serverVersion,
              ),
              _ReviewLine(
                label: 'Source commit',
                value: assembly.sourceCommitOid,
              ),
              _ReviewLine(
                label: isChinese ? '组装适配器' : 'Assembly adapter',
                value: assembly.assemblyAdapterId,
              ),
              _ReviewLine(
                label: isChinese ? '组装清单摘要' : 'Assembly manifest digest',
                value: assembly.assemblyManifestDigestSha256,
              ),
              _ReviewLine(
                label: isChinese ? '预留回环端点' : 'Reserved loopback endpoint',
                value: 'http://${assembly.bindHost}:${assembly.port}',
              ),
              _ReviewLine(
                label: isChinese ? 'Runner 目标' : 'Runner target',
                value:
                    '${assembly.runnerPlatform}/${assembly.runnerArchitecture}',
              ),
              _ReviewLine(
                label: isChinese ? 'Runner 摘要' : 'Runner digest',
                value: assembly.runnerDigestSha256,
              ),
              _ReviewLine(
                label: isChinese ? 'Runner 契约' : 'Runner contract',
                value: assembly.runnerContractVersion,
              ),
              _ReviewLine(
                label: isChinese ? '信任 key ID' : 'Trust key ID',
                value: assembly.runnerTrustKeyId,
              ),
              _ReviewLine(
                label: isChinese ? '信任指纹' : 'Trust fingerprint',
                value: assembly.runnerTrustFingerprintSha256,
              ),
            ],
            for (final agent in plan.agents) ...[
              _ReviewLine(
                label: isChinese ? '智能体' : 'Agent',
                value: agent.agentId,
              ),
              _ReviewLine(
                label: isChinese ? '安装目标' : 'Install target',
                value: agent.installDestination,
              ),
            ],
            _ReviewLine(
              label: isChinese ? '计划摘要' : 'Plan digest',
              value: plan.planDigestSha256,
              valueKey: Key('$keyPrefix-plan-digest'),
            ),
            _ReviewLine(
              label: isChinese ? '包摘要' : 'Package digest',
              value: plan.packageDigestSha256,
              valueKey: Key('$keyPrefix-package-digest'),
            ),
            const SizedBox(height: 8),
            Text(
              '${isChinese ? '文件变更' : 'File changes'} (${plan.fileChanges.length})',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            for (final change in plan.fileChanges)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: SelectableText(
                  '${change.agentId.isEmpty ? '' : '${change.agentId} · '}'
                  '${change.selectionId} · ${change.destination} · '
                  '${change.bytes} B · ${change.digestSha256}',
                  key: ValueKey(
                    '$keyPrefix-file-${change.agentId}-${change.destination}',
                  ),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            for (final registration in plan.agentRegistrations)
              _ReviewLine(
                label: isChinese ? '智能体注册摘要' : 'Agent registration digest',
                value:
                    '${registration.agentId} · ${registration.destination} · ${registration.digestSha256}',
              ),
            const SizedBox(height: 6),
            Text(
              plan.kind == OptionalCollaborationWorkflowKind.localDeployment
                  ? (isChinese
                        ? 'LicoArc 自有适配器会组装摘要绑定的服务端和受签名固定 runner。结果处于待部署状态，runner 需要后续单独确认才会执行；组装不执行插件命令或脚本，也不授权外部传输。'
                        : 'The LicoArc-owned adapter assembles a digest-bound server and signed fixed runner. The result awaits deployment, and the runner requires a later separate confirmation to execute. Assembly does not run plugin commands or scripts and does not authorize external transfer.')
                  : (isChinese
                        ? '此计划不会在安装时执行插件代码、不会修改厂商配置，也不授权任何外部文件传输；认证审批代理不可用，注册保持未激活。'
                        : 'This plan does not execute plugin code during installation, modify vendor configuration, or authorize external transfer. Registrations remain inactive because the authenticated LicoArc review broker is unavailable.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            CheckboxListTile(
              key: Key('$keyPrefix-confirm'),
              contentPadding: EdgeInsets.zero,
              value: confirmed,
              onChanged: busy ? null : onConfirmed,
              title: Text(
                isChinese
                    ? '我已核对当前精确选择、目标、计划摘要、包摘要和全部文件；应用或取消都会一次性消耗此计划。'
                    : 'I reviewed the exact selection, destinations, plan digest, package digest, and every file; applying or cancelling consumes this plan once.',
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: Key('$keyPrefix-cancel'),
                  onPressed: busy ? null : onCancel,
                  child: Text(isChinese ? '确认取消计划' : 'Confirm cancellation'),
                ),
                FilledButton(
                  key: Key('$keyPrefix-apply'),
                  onPressed: busy ? null : onApply,
                  child: Text(
                    plan.kind ==
                            OptionalCollaborationWorkflowKind.localDeployment
                        ? (isChinese
                              ? '组装并等待部署'
                              : 'Assemble and await deployment')
                        : (isChinese ? '按精确计划应用' : 'Apply exact plan'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _ReviewLine extends StatelessWidget {
  const _ReviewLine({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 128, child: Text(label)),
          Expanded(child: SelectableText(value, key: valueKey)),
        ],
      ),
    );
  }
}
