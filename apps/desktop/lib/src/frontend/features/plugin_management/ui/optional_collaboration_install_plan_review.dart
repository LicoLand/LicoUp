import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationInstallPlanReview extends StatelessWidget {
  const OptionalCollaborationInstallPlanReview({
    super.key,
    required this.plan,
    required this.confirmed,
    required this.busy,
    required this.isChinese,
    required this.onConfirmed,
    required this.onApply,
    required this.onCancel,
  });

  final OptionalCollaborationInstallPlan plan;
  final bool confirmed;
  final bool busy;
  final bool isChinese;
  final ValueChanged<bool?> onConfirmed;
  final VoidCallback? onApply;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final trust = plan.runnerTrust;
    return Card(
      key: const Key('collaboration-install-plan-review'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isChinese
                  ? '安装计划、commit 与信任核对'
                  : 'Install plan, commit, and trust review',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _ReviewLine(
              label: isChinese ? '插件' : 'Plugin',
              value: '${plan.plugin.displayName} ${plan.plugin.version}',
            ),
            _ReviewLine(
              label: isChinese ? '来源 URL' : 'Source URL',
              value: plan.sourceUrl,
              valueKey: const Key('collaboration-plan-source-url'),
            ),
            _ReviewLine(
              label: 'Git commit',
              value: plan.sourceRef,
              valueKey: const Key('collaboration-plan-source-ref'),
            ),
            if (plan.pluginPath.isNotEmpty)
              _ReviewLine(
                label: isChinese ? '插件路径' : 'Plugin path',
                value: plan.pluginPath,
              ),
            if (trust != null) ...[
              _ReviewLine(
                label: isChinese ? '信任 key ID' : 'Trust key ID',
                value: trust.keyId,
              ),
              _ReviewLine(
                label: isChinese ? 'Runner 仓库' : 'Runner repository',
                value: trust.sourceRepositoryUrl,
              ),
              _ReviewLine(
                label: 'Runner identity',
                value: trust.runnerIdentity,
              ),
              _ReviewLine(
                label: isChinese ? '信任指纹' : 'Trust fingerprint',
                value: trust.fingerprintSha256,
              ),
            ],
            _ReviewLine(
              label: 'SHA-256',
              value: plan.packageDigestSha256,
              valueKey: const Key('collaboration-plan-digest'),
            ),
            _ReviewLine(
              label: isChinese ? '文件 / 字节' : 'Files / bytes',
              value: '${plan.fileCount} / ${plan.totalBytes}',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('collaboration-confirm-install'),
              contentPadding: EdgeInsets.zero,
              value: confirmed,
              onChanged: busy ? null : onConfirmed,
              title: Text(
                isChinese
                    ? '我已核对来源、精确 40 位 commit、runner 仓库与 identity、信任指纹和包摘要，并直接批准下方一次操作。'
                    : 'I reviewed the source, exact 40-character commit, runner repository and identity, trust fingerprint, and package digest and directly approve one action below.',
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: const Key('collaboration-cancel-install'),
                  onPressed: busy ? null : onCancel,
                  child: Text(
                    isChinese ? '确认取消安装计划' : 'Confirm plan cancellation',
                  ),
                ),
                FilledButton.icon(
                  key: const Key('collaboration-apply-install'),
                  onPressed: busy ? null : onApply,
                  icon: const Icon(Icons.install_desktop_outlined, size: 16),
                  label: Text(isChinese ? '按此绑定安装' : 'Install this binding'),
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
          SizedBox(width: 132, child: Text(label)),
          Expanded(child: SelectableText(value, key: valueKey)),
        ],
      ),
    );
  }
}
