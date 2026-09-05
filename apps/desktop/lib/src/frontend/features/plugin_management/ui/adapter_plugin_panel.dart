import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AdapterPluginPanel extends StatelessWidget {
  const AdapterPluginPanel({super.key, required this.binding});

  final PluginManagementBinding binding;

  @override
  Widget build(BuildContext context) {
    return EffectListener<PluginManagementEffect>(
      source: binding.effects,
      onEffect: (effect) => _handleEffect(context, effect),
      child:
          ProjectionBuilder<
            PluginManagementProjection,
            PluginManagementProjection
          >(
            source: binding.projection,
            select: (projection) => projection,
            builder: (context, projection) => LicoPaneScaffold(
              key: const Key('adapter-plugin-panel'),
              titleBarKey: const Key('adapter-plugin-title-bar'),
              title: LicoStrings.of(context).pluginManagement,
              refreshTooltip: LicoStrings.of(context).refresh,
              onRefresh: projection.phase == PresentationPhase.loading
                  ? null
                  : () => binding.intents.send(const RefreshPlugins()),
              refreshing: projection.phase == PresentationPhase.loading,
              refreshButtonKey: const Key('adapter-plugin-refresh'),
              body: projection.plugins.isEmpty
                  ? LicoEmptyState(
                      icon: Icons.extension_outlined,
                      title: LicoStrings.of(context).pluginManagement,
                      message: LicoStrings.of(context).isChinese
                          ? '插件目录中没有适配器。'
                          : 'No adapters were returned by the plugin catalog.',
                    )
                  : ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        _PluginCardGrid(
                          plugins: projection.plugins,
                          busy: projection.phase == PresentationPhase.loading,
                          binding: binding,
                        ),
                        if (projection.notice != null) ...[
                          const SizedBox(height: 4),
                          SelectableText(
                            projection.notice!.reasonCode,
                            key: const Key('adapter-plugin-error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
    );
  }

  void _handleEffect(BuildContext context, PluginManagementEffect effect) {
    switch (effect) {
      case PluginLifecyclePlanReady():
        unawaited(_confirmPluginLifecycle(context, effect));
      case PluginActionCompleted():
        _showActionSnack(context, _completedMessage(context, effect));
      case CollaborationInstallPlanReady():
        unawaited(_confirmCollaborationInstall(context, effect));
      case PluginActionRejected():
        _showActionSnack(context, _rejectionMessage(context, effect));
    }
  }

  Future<void> _confirmPluginLifecycle(
    BuildContext context,
    PluginLifecyclePlanReady effect,
  ) async {
    final strings = LicoStrings.of(context);
    final installing = effect.action == PluginLifecyclePlanAction.install;
    final special = effect.kind == PluginInstallPlanKind.codexPinnedRelease;
    final title = special
        ? (strings.isChinese
              ? '安装 LicoUp Codex Plugin？'
              : 'Install LicoUp Codex Plugin?')
        : strings.isChinese
        ? '${installing ? '安装' : '卸载'} ${effect.pluginLabel}？'
        : '${installing ? 'Install' : 'Uninstall'} ${effect.pluginLabel}?';
    final message = special
        ? strings.isChinese
              ? 'Codex 将从 GitHub ${effect.marketplaceSource} 的 '
                    '${effect.marketplaceRelease} 安装插件 '
                    '${effect.pluginVersion}。LicoUp 只提供本机运行时；'
                    '插件只传递本机对话文件位置。安装后，请新建 Codex 对话。'
              : 'Codex will install plugin ${effect.pluginVersion} from '
                    'GitHub ${effect.marketplaceSource} at '
                    '${effect.marketplaceRelease}. LicoUp provides only the '
                    'local runtime, and the plugin shares only local '
                    'conversation file locations. Start a new Codex '
                    'conversation after installation.'
        : strings.isChinese
        ? '此操作只会调用目录为该适配器声明的管理动作。'
        : 'This runs only the management action declared for this adapter '
              'by the catalog.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('plugin-lifecycle-plan'),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(strings.isChinese ? '取消' : 'Cancel'),
          ),
          FilledButton(
            key: Key('confirm-adapter-${effect.action.name}'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              strings.isChinese
                  ? (installing ? '确认安装' : '确认卸载')
                  : (installing ? 'Install' : 'Uninstall'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    binding.intents.send(
      ApplyPluginLifecyclePlan(effect.planId, trace: effect.trace),
    );
  }

  Future<void> _confirmCollaborationInstall(
    BuildContext context,
    CollaborationInstallPlanReady effect,
  ) async {
    final confirmed = await _confirmPlan(context, effect.summary);
    if (confirmed) {
      binding.intents.send(ApplyCollaborationInstall(trace: effect.trace));
    }
  }

  Future<bool> _confirmPlan(BuildContext context, String summary) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            key: const Key('plugin-install-plan'),
            title: Text(LicoStrings.of(dialogContext).installPlan),
            content: SelectableText(summary),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(LicoStrings.of(dialogContext).cancel),
              ),
              FilledButton(
                key: const Key('plugin-install-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(LicoStrings.of(dialogContext).install),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showActionSnack(BuildContext context, String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _completedMessage(BuildContext context, PluginActionCompleted effect) {
    final chinese = LicoStrings.of(context).isChinese;
    return switch (effect.reasonCode) {
      'codex_plugin_installed' =>
        chinese
            ? 'LicoUp Codex Plugin 已安装，新对话将由 Codex 主线程调度。'
            : 'LicoUp Codex Plugin is installed; new conversations are '
                  'orchestrated by the Codex main thread.',
      'adapter_plugin_installed' => chinese ? '适配器已安装。' : 'Adapter installed.',
      'adapter_plugin_uninstalled' =>
        chinese ? '适配器已卸载。' : 'Adapter uninstalled.',
      _ => effect.reasonCode,
    };
  }

  String _rejectionMessage(BuildContext context, PluginActionRejected effect) {
    final chinese = LicoStrings.of(context).isChinese;
    return switch (effect.reasonCode) {
      'codex_executable_missing' =>
        chinese ? '未找到 Codex 可执行文件。' : 'The Codex executable was not found.',
      'codex_plugin_plan_failed' =>
        chinese
            ? '无法准备 LicoUp Codex Plugin 安装。'
            : 'The LicoUp Codex Plugin installation could not be prepared.',
      'codex_plugin_install_failed' =>
        chinese
            ? 'LicoUp Codex Plugin 安装失败。'
            : 'LicoUp Codex Plugin installation failed.',
      'adapter_plugin_plan_expired' =>
        chinese
            ? '插件操作确认已失效，请重试。'
            : 'The plugin confirmation expired. Try again.',
      'adapter_plugin_missing' =>
        chinese
            ? '找不到指定的适配器插件。'
            : 'The requested adapter plugin is not in the catalog.',
      'adapter_plugin_action_not_declared' =>
        chinese
            ? '目录未声明此适配器操作。'
            : 'The catalog does not declare this adapter action.',
      'adapter_plugin_install_failed' =>
        chinese ? '适配器安装失败。' : 'Adapter installation failed.',
      'adapter_plugin_uninstall_failed' =>
        chinese ? '适配器卸载失败。' : 'Adapter uninstall failed.',
      'adapter_plugin_catalog_refresh_failed' =>
        chinese
            ? '操作成功，但无法刷新插件目录。'
            : 'The action succeeded, but the plugin catalog could not be '
                  'refreshed.',
      _ => effect.reasonCode,
    };
  }
}

final class _PluginCardGrid extends StatelessWidget {
  const _PluginCardGrid({
    required this.plugins,
    required this.busy,
    required this.binding,
  });

  final List<PluginProjectionItem> plugins;
  final bool busy;
  final PluginManagementBinding binding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 940 ? 2 : 1;
      final rows = <Widget>[];
      for (var index = 0; index < plugins.length; index += columns) {
        final row = plugins.skip(index).take(columns).toList(growable: false);
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < columns; column++) ...[
                if (column > 0) const SizedBox(width: 12),
                Expanded(
                  child: column < row.length
                      ? _PluginCard(
                          plugin: row[column],
                          busy: busy,
                          binding: binding,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        );
        rows.add(const SizedBox(height: 12));
      }
      return Column(children: rows);
    },
  );
}

final class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.busy,
    required this.binding,
  });

  final PluginProjectionItem plugin;
  final bool busy;
  final PluginManagementBinding binding;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Card(
      key: Key('adapter-plugin-${plugin.id}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LicoRadius.card),
        side: BorderSide(color: colors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.surfaceLow,
                    borderRadius: BorderRadius.circular(LicoRadius.floating),
                  ),
                  child: Center(
                    child: AgentBrandIcon(
                      target: TargetCandidate(
                        target: plugin.id,
                        label: plugin.name,
                        kind: 'agent-adapter',
                        status: TargetCandidateStatus.detected,
                        configured: true,
                        confidence: 1,
                        adapterStatus: 'packaged',
                      ),
                      size: 30,
                      iconSize: 22,
                      selected: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    plugin.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _ReadinessPill(readiness: plugin.runtimeStateLabel),
              ],
            ),
            if (plugin.capabilities.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionHeader(
                title: strings.isChinese ? '原生能力' : 'NATIVE CAPABILITIES',
              ),
              const SizedBox(height: 8),
              for (
                var index = 0;
                index < plugin.capabilities.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(height: 8),
                _CapabilityTile(
                  agentId: plugin.id,
                  capability: plugin.capabilities[index],
                ),
              ],
            ],
            if (plugin.plugins.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionHeader(
                title: strings.isChinese ? '适配插件' : 'ADAPTER PLUGINS',
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < plugin.plugins.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                _PluginEntryTile(
                  agentId: plugin.id,
                  entry: plugin.plugins[index],
                  busy: busy,
                  binding: binding,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: LicoStrings.of(context).isChinese ? 0 : 0.8,
      color: context.licoColors.textMuted,
    ),
  );
}

final class _CapabilityTile extends StatelessWidget {
  const _CapabilityTile({required this.agentId, required this.capability});

  final String agentId;
  final PluginCapabilityProjection capability;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = LicoStrings.of(context).isChinese;
    final (label, icon) = _capabilityPresentation(capability.id, chinese);
    final stateColor = capability.running
        ? colors.success
        : capability.detected
        ? colors.primaryStrong
        : colors.textMuted;
    final stateLabel = capability.running
        ? (chinese ? '运行中' : 'Running')
        : capability.detected
        ? (chinese ? '已检测' : 'Detected')
        : (chinese ? '未检测到' : 'Not detected');
    final liveText = _liveText(capability, chinese);
    return Container(
      key: Key('adapter-capability-$agentId-${capability.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.floating),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.brandSurface,
              borderRadius: BorderRadius.circular(LicoRadius.chip),
            ),
            child: Icon(icon, size: 17, color: stateColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (capability.detected && liveText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    liveText,
                    key: Key(
                      'adapter-capability-live-$agentId-${capability.id}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: capability.running
                          ? colors.success
                          : colors.textMuted,
                      fontFamily: capability.running ? 'SF Mono' : null,
                      fontFamilyFallback: const [
                        'Menlo',
                        'Consolas',
                        'monospace',
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          _StatePill(label: stateLabel, color: stateColor),
        ],
      ),
    );
  }
}

final class _PluginEntryTile extends StatelessWidget {
  const _PluginEntryTile({
    required this.agentId,
    required this.entry,
    required this.busy,
    required this.binding,
  });

  final String agentId;
  final PluginEntryProjection entry;
  final bool busy;
  final PluginManagementBinding binding;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = LicoStrings.of(context).isChinese;
    final installed = entry.installationState == 'installed';
    final (stateLabel, stateColor) = _installationPresentation(
      entry.installationState,
      chinese,
      colors,
    );
    return Container(
      key: Key('adapter-plugin-entry-$agentId-${entry.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.floating),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.brandSurface,
                  borderRadius: BorderRadius.circular(LicoRadius.chip),
                ),
                child: Icon(
                  _pluginIcon(entry.id),
                  size: 17,
                  color: colors.accentStrong,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (entry.detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        entry.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textMuted,
                          fontFamily: 'SF Mono',
                          fontFamilyFallback: const [
                            'Menlo',
                            'Consolas',
                            'monospace',
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _StatePill(label: stateLabel, color: stateColor),
            ],
          ),
          if (installed || entry.installable || entry.uninstallable) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: colors.line),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (installed)
                  Tooltip(
                    message: chinese
                        ? '当前已是最新版本'
                        : 'Already on the latest version',
                    child: FilledButton.tonalIcon(
                      key: Key('adapter-update-$agentId-${entry.id}'),
                      onPressed: null,
                      style: FilledButton.styleFrom(
                        foregroundColor: colors.success,
                      ),
                      icon: const Icon(
                        Icons.system_update_alt_outlined,
                        size: 17,
                      ),
                      label: Text(chinese ? '更新' : 'Update'),
                    ),
                  ),
                if (entry.installable)
                  FilledButton.tonalIcon(
                    key: Key('adapter-install-$agentId-${entry.id}'),
                    onPressed: busy
                        ? null
                        : () => binding.intents.send(
                            PlanPluginInstall(agentId, entry.id),
                          ),
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: Text(chinese ? '安装' : 'Install'),
                  ),
                if (entry.uninstallable)
                  OutlinedButton.icon(
                    key: Key('adapter-uninstall-$agentId-${entry.id}'),
                    onPressed: busy
                        ? null
                        : () => binding.intents.send(
                            PlanPluginUninstall(agentId, entry.id),
                          ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.error,
                      side: BorderSide(color: colors.error.withAlpha(120)),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: Text(chinese ? '卸载' : 'Uninstall'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

final class _ReadinessPill extends StatelessWidget {
  const _ReadinessPill({required this.readiness});
  final String readiness;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = LicoStrings.of(context).isChinese;
    final (label, color) = switch (readiness) {
      'ready' => (chinese ? '就绪' : 'Ready', colors.success),
      'partial' => (chinese ? '部分就绪' : 'Partial', colors.warning),
      'failed' => (chinese ? '失败' : 'Failed', colors.error),
      'blocked' => (chinese ? '受阻' : 'Blocked', colors.error),
      'history-only' => (chinese ? '仅历史' : 'History only', colors.accent),
      'unverified' => (chinese ? '未验证' : 'Unverified', colors.textMuted),
      _ => (readiness, colors.textMuted),
    };
    return _StatePill(label: label, color: color);
  }
}

final class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withAlpha(20),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    ),
  );
}

(String, IconData) _capabilityPresentation(String id, bool chinese) =>
    switch (id) {
      'desktop' => (
        chinese ? '桌面端' : 'Desktop',
        Icons.desktop_windows_outlined,
      ),
      'cli' => ('CLI', Icons.terminal),
      'acp' => ('ACP', Icons.cable_outlined),
      'rpc' => ('RPC', Icons.sync_alt),
      'app-server' => ('App Server', Icons.hub_outlined),
      'gateway' => (chinese ? '网关' : 'Gateway', Icons.alt_route),
      'local-server' => (chinese ? '本地服务' : 'Local Server', Icons.dns_outlined),
      'web-server' => ('Web Server', Icons.language_outlined),
      'tui-gateway' => ('TUI Gateway', Icons.alt_route),
      _ => (id, Icons.extension_outlined),
    };

String? _liveText(PluginCapabilityProjection capability, bool chinese) {
  if (!capability.running) return chinese ? '未运行' : 'Not running';
  final parts = <String>[
    if (capability.pid != null) 'PID ${capability.pid}',
    if (capability.processName != null) capability.processName!,
    if (capability.port != null) ':${capability.port}',
  ];
  return parts.isEmpty ? (chinese ? '运行中' : 'Running') : parts.join(' · ');
}

IconData _pluginIcon(String pluginId) => switch (pluginId) {
  'acp-bridge' => Icons.cable_outlined,
  'lico-up-codex' => Icons.account_tree_outlined,
  _ => Icons.extension_outlined,
};

(String, Color) _installationPresentation(
  String state,
  bool chinese,
  LicoThemeColors colors,
) => switch (state) {
  'installed' => (chinese ? '已安装' : 'Installed', colors.success),
  'not-installed' => (chinese ? '未安装' : 'Not installed', colors.warning),
  'unavailable' => (chinese ? '不可用' : 'Unavailable', colors.textMuted),
  _ => (state, colors.textMuted),
};
