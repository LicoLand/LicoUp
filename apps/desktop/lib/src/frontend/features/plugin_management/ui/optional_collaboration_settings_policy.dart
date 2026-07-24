import 'package:flutter/material.dart';

final class OptionalCollaborationSettingsHeader extends StatelessWidget {
  const OptionalCollaborationSettingsHeader({
    super.key,
    required this.isChinese,
  });

  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.hub_outlined,
          size: 19,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            isChinese ? '可选协作' : 'Optional Collaboration',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

final class OptionalCollaborationPolicyNotice extends StatelessWidget {
  const OptionalCollaborationPolicyNotice({super.key, required this.isChinese});

  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          isChinese
              ? '默认禁用、默认不查询、默认不加载。信任根导入、GitHub 下载、安装、组装与部署是相互独立的直接用户操作。认证逐项审批代理尚未实现，因此可选 MCP 外发保持不可用。'
              : 'Disabled, unqueried, and unloaded by default. Trust import, GitHub download, installation, assembly, and deployment are separate direct-user actions. Optional MCP egress remains unavailable until LicoUp provides an authenticated exact-review broker.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
