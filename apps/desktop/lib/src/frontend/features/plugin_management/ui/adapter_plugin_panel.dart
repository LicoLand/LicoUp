import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_settings.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

final class AdapterPluginPanel extends StatefulWidget {
  const AdapterPluginPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<AdapterPluginPanel> createState() => _AdapterPluginPanelState();
}

final class _AdapterPluginPanelState extends State<AdapterPluginPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.controller.adapterPluginController.refresh());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final controller = widget.controller.adapterPluginController;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        key: const Key('adapter-plugin-panel'),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.isChinese ? '插件管理' : 'Agent Adapter Plugins',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      strings.isChinese
                          ? 'Native Support 与 Native ACP 无需额外安装。其他目标由 Lico Arc Adaptive Bridge 负责交互适配；只有目录声明的真实生命周期操作才会显示安装或卸载。对话就绪状态仅表示 Level 1 对话接续可用，不代表已实现 Level 2 双向对话。'
                          : 'Native Support and Native ACP need no extra installation. Other targets use a Lico Arc Adaptive Bridge; install or uninstall appears only for real lifecycle actions declared by the catalog. Conversation readiness indicates Level 1 continuation only; it does not imply Level 2 bidirectional conversation.',
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              IconButton.filledTonal(
                tooltip: strings.isChinese
                    ? '刷新插件目录'
                    : 'Refresh plugin catalog',
                onPressed: controller.busy
                    ? null
                    : () => unawaited(controller.refresh()),
                icon: controller.busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (controller.catalog == null && controller.busy)
            const Center(child: CircularProgressIndicator())
          else if (controller.adapters.isEmpty)
            _EmptyCatalog(isChinese: strings.isChinese)
          else
            for (final adapter in controller.adapters) ...[
              _AdapterCard(
                adapter: adapter,
                busy: controller.busy,
                isChinese: strings.isChinese,
                onAction: (action) => _confirmAction(adapter, action),
              ),
              const SizedBox(height: 12),
            ],
          if (controller.lastErrorCode.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              controller.lastErrorCode,
              key: const Key('adapter-plugin-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          Text(
            strings.isChinese ? '协作插件' : 'Collaboration Plugin',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            strings.isChinese
                ? 'LicoMesh 是独立安装、独立授权的可选协作能力。'
                : 'LicoMesh is an independently installed and authorized optional collaboration capability.',
          ),
          const SizedBox(height: 10),
          OptionalCollaborationSettings(
            controller: widget.controller.optionalCollaborationController,
          ),
        ],
      ),
    );
  }

  Future<void> _confirmAction(
    AdapterPluginDescriptor adapter,
    AdapterPluginLifecycleAction action,
  ) async {
    final isChinese = LicoStrings.of(context).isChinese;
    final installing = action == AdapterPluginLifecycleAction.install;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isChinese
              ? '${installing ? '安装' : '卸载'} ${adapter.label}？'
              : '${installing ? 'Install' : 'Uninstall'} ${adapter.label}?',
        ),
        content: Text(
          isChinese
              ? '此操作只会调用目录为该适配器声明的管理动作。'
              : 'This runs only the management action declared for this adapter by the catalog.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isChinese ? '取消' : 'Cancel'),
          ),
          FilledButton(
            key: Key('confirm-adapter-${action.name}'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isChinese
                  ? (installing ? '确认安装' : '确认卸载')
                  : (installing ? 'Install' : 'Uninstall'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (installing) {
      await widget.controller.adapterPluginController.install(adapter.agentId);
    } else {
      await widget.controller.adapterPluginController.uninstall(
        adapter.agentId,
      );
    }
  }
}

final class _AdapterCard extends StatelessWidget {
  const _AdapterCard({
    required this.adapter,
    required this.busy,
    required this.isChinese,
    required this.onAction,
  });

  final AdapterPluginDescriptor adapter;
  final bool busy;
  final bool isChinese;
  final ValueChanged<AdapterPluginLifecycleAction> onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: Key('adapter-plugin-${adapter.agentId}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  adapter.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                _ManagementKindBadge(kind: adapter.managementKind),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                _Fact(label: 'Agent', value: adapter.agentId),
                _Fact(label: 'Driver', value: adapter.driverId),
                _Fact(label: 'Protocol', value: adapter.runtimeProtocol),
                _Fact(label: 'Lane', value: adapter.laneFamily),
                _Fact(
                  label: isChinese ? '安装状态' : 'Installation',
                  value: adapter.installationState,
                ),
                _Fact(
                  label: isChinese ? '对话就绪状态' : 'Conversation readiness',
                  value: adapter.readiness,
                ),
              ],
            ),
            if (adapter.lifecycleActions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  if (adapter.supports(AdapterPluginLifecycleAction.install))
                    FilledButton.tonalIcon(
                      key: Key('adapter-install-${adapter.agentId}'),
                      onPressed: busy
                          ? null
                          : () =>
                                onAction(AdapterPluginLifecycleAction.install),
                      icon: const Icon(Icons.download_outlined),
                      label: Text(isChinese ? '安装' : 'Install'),
                    ),
                  if (adapter.supports(AdapterPluginLifecycleAction.uninstall))
                    OutlinedButton.icon(
                      key: Key('adapter-uninstall-${adapter.agentId}'),
                      onPressed: busy
                          ? null
                          : () => onAction(
                              AdapterPluginLifecycleAction.uninstall,
                            ),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(isChinese ? '卸载' : 'Uninstall'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _ManagementKindBadge extends StatelessWidget {
  const _ManagementKindBadge({required this.kind});

  final AdapterPluginManagementKind kind;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (kind) {
      AdapterPluginManagementKind.native => (
        Icons.memory_outlined,
        'Native Support',
      ),
      AdapterPluginManagementKind.bundledAcp => (
        Icons.inventory_2_outlined,
        'Native ACP',
      ),
      AdapterPluginManagementKind.managedBridge => (
        Icons.cable_outlined,
        'Lico Arc Adaptive Bridge',
      ),
    };
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

final class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label: ',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: value),
      ],
    ),
    style: Theme.of(context).textTheme.bodySmall,
  );
}

final class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog({required this.isChinese});

  final bool isChinese;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        isChinese ? '目录中没有适配器。' : 'No adapters were returned by the catalog.',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
