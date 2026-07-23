import 'package:flutter/material.dart';

final class OptionalCollaborationCatalogAction extends StatelessWidget {
  const OptionalCollaborationCatalogAction({
    super.key,
    required this.loaded,
    required this.busy,
    required this.isChinese,
    required this.onLoad,
  });

  final bool loaded;
  final bool busy;
  final bool isChinese;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('collaboration-workflow-catalog'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isChinese ? '声明式工作流目录' : 'Declarative workflow catalog',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    loaded
                        ? (isChinese
                              ? '已由用户按需加载。'
                              : 'Loaded explicitly on demand.')
                        : (isChinese
                              ? '未加载；点击后才读取已安装目录。'
                              : 'Not loaded; the installed catalog is read only after this click.'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              key: const Key('collaboration-load-catalog'),
              onPressed: busy ? null : onLoad,
              child: Text(isChinese ? '加载目录' : 'Load catalog'),
            ),
          ],
        ),
      ),
    );
  }
}
