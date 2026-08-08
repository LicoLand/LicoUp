import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

final class CatalogConvergenceStatusCard extends StatelessWidget {
  const CatalogConvergenceStatusCard({super.key, required this.controller});

  final CatalogConvergenceController controller;

  @override
  Widget build(BuildContext context) {
    final isChinese = LicoStrings.of(context).isChinese;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final status = controller.status;
        return Card(
          key: const Key('catalog-convergence-status'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(LicoContentSpacing.item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.sync_alt_outlined, size: 19),
                    const SizedBox(width: LicoContentSpacing.compact),
                    Expanded(
                      child: Text(
                        isChinese ? '工具目录同步' : 'Tool catalog sync',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const Key('catalog-convergence-refresh-status'),
                      tooltip: isChinese ? '刷新本机状态' : 'Refresh local state',
                      onPressed: controller.busy
                          ? null
                          : () => unawaited(controller.bootstrap()),
                      icon: const Icon(Icons.refresh_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: LicoContentSpacing.compact),
                Text(
                  _summary(controller.phase, isChinese),
                  key: const Key('catalog-convergence-summary'),
                ),
                const SizedBox(height: LicoContentSpacing.compact),
                Wrap(
                  spacing: LicoContentSpacing.item,
                  runSpacing: LicoContentSpacing.compact,
                  children: [
                    _Fact(
                      label: isChinese ? '分区' : 'Partitions',
                      value: '${status.partitionCount}',
                    ),
                    _Fact(
                      label: isChinese ? '待同步' : 'Pending',
                      value: '${status.pendingInvalidationCount}',
                    ),
                    _Fact(
                      label: isChinese ? '已应用' : 'Applied',
                      value: '${status.appliedCohortCount}',
                    ),
                    _Fact(
                      label: isChinese ? '界面已观察修订' : 'UI revision',
                      value: status.uiObservedRevision < 0
                          ? '—'
                          : '${status.uiObservedRevision}',
                    ),
                  ],
                ),
                if (controller.reasonCode != 'catalog_current') ...[
                  const SizedBox(height: LicoContentSpacing.compact),
                  Text(
                    controller.reasonCode,
                    key: const Key('catalog-convergence-reason'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text('$label: $value', style: Theme.of(context).textTheme.bodySmall);
  }
}

String _summary(CatalogConvergencePhase phase, bool isChinese) {
  return switch (phase) {
    CatalogConvergencePhase.disabled =>
      isChinese
          ? '未配置目录连接；不会推断或自动连接服务。'
          : 'No catalog connection is configured; no service is inferred or contacted.',
    CatalogConvergencePhase.idle => isChinese ? '等待同步。' : 'Waiting to sync.',
    CatalogConvergencePhase.reconciling =>
      isChinese
          ? '正在拉取授权目录；同步完成前不会提供缓存发现。'
          : 'Pulling the authorized catalog; cached discovery stays blocked until reconciliation completes.',
    CatalogConvergencePhase.ready =>
      isChinese ? '授权目录已同步。' : 'The authorized catalog is current.',
    CatalogConvergencePhase.blocked =>
      isChinese
          ? '目录发现已暂停，等待重新同步。'
          : 'Catalog discovery is paused until reconciliation succeeds.',
    CatalogConvergencePhase.failed =>
      isChinese
          ? '无法读取本机目录同步状态。'
          : 'The local catalog sync state is unavailable.',
  };
}
