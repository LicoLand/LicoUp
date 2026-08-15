import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
      builder: (context, _) {
        final Widget body;
        if (controller.catalog == null && controller.busy) {
          body = const Center(child: CircularProgressIndicator());
        } else if (controller.adapters.isEmpty) {
          body = _EmptyCatalog(isChinese: strings.isChinese);
        } else {
          body = ListView(
            padding: EdgeInsets.zero,
            children: [
              _AdapterCardGrid(
                adapters: controller.adapters,
                busy: controller.busy,
                isChinese: strings.isChinese,
                onAction: _confirmAction,
              ),
              if (controller.lastErrorCode.isNotEmpty) ...[
                const SizedBox(height: 4),
                SelectableText(
                  controller.lastErrorCode,
                  key: const Key('adapter-plugin-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          );
        }
        return LicoPaneScaffold(
          key: const Key('adapter-plugin-panel'),
          titleBarKey: const Key('adapter-plugin-title-bar'),
          title: strings.isChinese ? '插件管理' : 'Agent Adapter Plugins',
          refreshTooltip: strings.pluginManagementRefresh,
          onRefresh: controller.busy
              ? null
              : () => unawaited(controller.refresh()),
          refreshing: controller.busy,
          refreshButtonKey: const Key('adapter-plugin-refresh'),
          body: body,
        );
      },
    );
  }

  Future<void> _confirmAction(
    AdapterPluginDescriptor adapter,
    AdapterPluginEntry plugin,
    AdapterPluginLifecycleAction action,
  ) async {
    if (adapter.agentId == 'codex' &&
        plugin.id == 'lico-up-codex' &&
        action == AdapterPluginLifecycleAction.install) {
      return _installCodexPlugin();
    }
    final isChinese = LicoStrings.of(context).isChinese;
    final installing = action == AdapterPluginLifecycleAction.install;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isChinese
              ? '${installing ? '安装' : '卸载'} ${plugin.label}？'
              : '${installing ? 'Install' : 'Uninstall'} ${plugin.label}?',
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

  /// LicoUp Codex Plugin installation never uses the generic lifecycle lane:
  /// the pinned GitHub release is planned first, the user confirms the exact
  /// source digest, and a single-use permit executes `codex plugin add`.
  Future<void> _installCodexPlugin() async {
    final isChinese = LicoStrings.of(context).isChinese;
    final service = widget.controller.agentService;
    final binaryPath = _codexBinaryPath();
    if (binaryPath.isEmpty) {
      _showActionSnack(
        isChinese ? '未找到 Codex 可执行文件。' : 'The Codex executable was not found.',
      );
      return;
    }

    Map<String, dynamic> plan;
    try {
      final status = await service.codexPluginStatus(binaryPath: binaryPath);
      if (status['ok'] == true && status['ready'] == true) {
        await widget.controller.adapterPluginController.refresh();
        return;
      }
      plan = await service.planCodexPlugin(binaryPath: binaryPath);
    } catch (_) {
      _showActionSnack(
        isChinese
            ? '无法准备 LicoUp Codex Plugin 安装。'
            : 'The LicoUp Codex Plugin installation could not be prepared.',
      );
      return;
    }
    final digest = plan['digest']?.toString() ?? '';
    if (plan['ok'] != true ||
        plan['requiresConfirmation'] != true ||
        digest.isEmpty) {
      _showActionSnack(
        isChinese
            ? '无法准备 LicoUp Codex Plugin 安装。'
            : 'The LicoUp Codex Plugin installation could not be prepared.',
      );
      return;
    }
    final source = plan['marketplaceSource']?.toString() ?? '';
    final release = plan['marketplaceRelease']?.toString() ?? '';
    final version = plan['pluginVersion']?.toString() ?? '';
    if (source.isEmpty || release.isEmpty || version.isEmpty || !mounted) {
      return;
    }

    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              isChinese
                  ? '安装 LicoUp Codex Plugin？'
                  : 'Install LicoUp Codex Plugin?',
            ),
            content: Text(
              isChinese
                  ? 'Codex 将从 GitHub $source 的 $release 安装插件 $version。LicoUp 只提供本机运行时；插件只传递本机对话文件位置。安装后，请新建 Codex 对话。'
                  : 'Codex will install plugin $version from GitHub $source at $release. LicoUp provides only the local runtime, and the plugin shares only local conversation file locations. Start a new Codex conversation after installation.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(isChinese ? '取消' : 'Cancel'),
              ),
              FilledButton(
                key: const Key('confirm-adapter-install'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(isChinese ? '确认安装' : 'Install'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    try {
      final result = await service.installCodexPlugin(
        binaryPath: binaryPath,
        confirmation: digest,
      );
      if (result['ok'] == true && result['installed'] == true) {
        await widget.controller.adapterPluginController.refresh();
        if (!mounted) return;
        _showActionSnack(
          isChinese
              ? 'LicoUp Codex Plugin 已安装，新对话将由 Codex 主线程调度。'
              : 'LicoUp Codex Plugin is installed; new conversations are orchestrated by the Codex main thread.',
        );
        return;
      }
      _showActionSnack(
        isChinese
            ? 'LicoUp Codex Plugin 安装失败。'
            : 'LicoUp Codex Plugin installation failed.',
      );
    } catch (_) {
      _showActionSnack(
        isChinese
            ? 'LicoUp Codex Plugin 安装失败。'
            : 'LicoUp Codex Plugin installation failed.',
      );
    }
  }

  String _codexBinaryPath() {
    for (final candidate in widget.controller.scannedTargets) {
      if (candidate.target == 'codex') {
        final binaryPath = candidate.binaryPath?.trim() ?? '';
        if (binaryPath.isNotEmpty) {
          return binaryPath;
        }
      }
    }
    return '';
  }

  void _showActionSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Responsive per-agent grid: two columns on wide desktop layouts, one column
/// otherwise. Each agent stays an independent card.
final class _AdapterCardGrid extends StatelessWidget {
  const _AdapterCardGrid({
    required this.adapters,
    required this.busy,
    required this.isChinese,
    required this.onAction,
  });

  final List<AdapterPluginDescriptor> adapters;
  final bool busy;
  final bool isChinese;
  final void Function(
    AdapterPluginDescriptor adapter,
    AdapterPluginEntry plugin,
    AdapterPluginLifecycleAction action,
  )
  onAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 940 ? 2 : 1;
        final rows = <Widget>[];
        for (var i = 0; i < adapters.length; i += columns) {
          final row = adapters.skip(i).take(columns).toList(growable: false);
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var column = 0; column < columns; column++) ...[
                  if (column > 0) const SizedBox(width: 12),
                  Expanded(
                    child: column < row.length
                        ? _AdapterCard(
                            adapter: row[column],
                            busy: busy,
                            isChinese: isChinese,
                            onAction: (plugin, action) =>
                                onAction(row[column], plugin, action),
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
  final void Function(
    AdapterPluginEntry plugin,
    AdapterPluginLifecycleAction action,
  )
  onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Card(
      key: Key('adapter-plugin-${adapter.agentId}'),
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
                        target: adapter.agentId,
                        label: adapter.label,
                        kind: 'agent-adapter',
                        status: 'detected',
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
                    agentProductLabel(adapter.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                _ReadinessPill(
                  readiness: adapter.readiness,
                  isChinese: isChinese,
                ),
              ],
            ),
            if (adapter.nativeCapabilities.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionHeader(
                title: isChinese ? '原生能力' : 'NATIVE CAPABILITIES',
                isChinese: isChinese,
              ),
              const SizedBox(height: 8),
              for (
                var index = 0;
                index < adapter.nativeCapabilities.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(height: 8),
                _CapabilityTile(
                  agentId: adapter.agentId,
                  capability: adapter.nativeCapabilities[index],
                  isChinese: isChinese,
                ),
              ],
            ],
            if (adapter.plugins.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionHeader(
                title: isChinese ? '适配插件' : 'ADAPTER PLUGINS',
                isChinese: isChinese,
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < adapter.plugins.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                _AdapterPluginTile(
                  agentId: adapter.agentId,
                  plugin: adapter.plugins[index],
                  isChinese: isChinese,
                  busy: busy,
                  onAction: onAction,
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
  const _SectionHeader({required this.title, required this.isChinese});

  final String title;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: isChinese ? 0 : 0.8,
        color: context.licoColors.textMuted,
      ),
    );
  }
}

/// One native capability of the agent (Desktop / CLI / RPC / Gateway /
/// Local Server) as an independent tile matching the adapter-plugin cards:
/// capability icon, name, live on-host evidence (pid, process name, and
/// listening port when a server is running), and a state pill.
final class _CapabilityTile extends StatelessWidget {
  const _CapabilityTile({
    required this.agentId,
    required this.capability,
    required this.isChinese,
  });

  final String agentId;
  final AdapterNativeCapability capability;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final (label, icon) = _capabilityPresentation(capability.kind, isChinese);
    final detected = capability.detected;
    final running = capability.running;
    final stateColor = running
        ? colors.success
        : (detected ? colors.primaryStrong : colors.textMuted);
    final stateLabel = running
        ? (isChinese ? '运行中' : 'Running')
        : detected
        ? (isChinese ? '已检测' : 'Detected')
        : (isChinese ? '未检测到' : 'Not detected');
    final liveText = _liveText(capability, isChinese);
    return Container(
      key: Key('adapter-capability-$agentId-${capability.kind.wireName}'),
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
                if (detected && liveText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    liveText,
                    key: Key(
                      'adapter-capability-live-$agentId-${capability.kind.wireName}',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: running ? colors.success : colors.textMuted,
                      fontFamily: running ? 'SF Mono' : null,
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: stateColor.withAlpha(20),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: stateColor,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  stateLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Live evidence line: `PID 42189 · codex · :4096` while running, otherwise a
/// plain not-running marker.
String? _liveText(AdapterNativeCapability capability, bool isChinese) {
  if (!capability.running) {
    return isChinese ? '未运行' : 'Not running';
  }
  final parts = <String>[
    if (capability.pid != null) 'PID ${capability.pid}',
    if (capability.processName != null) capability.processName!,
    if (capability.port != null) ':${capability.port}',
  ];
  if (parts.isEmpty) {
    return isChinese ? '运行中' : 'Running';
  }
  return parts.join(' · ');
}

/// One LicoUp-managed adapter plugin as an independent tile: plugin name,
/// detail code, an installation-state pill, and the lifecycle actions the
/// catalog declared for this plugin, kept inside the card.
final class _AdapterPluginTile extends StatelessWidget {
  const _AdapterPluginTile({
    required this.agentId,
    required this.plugin,
    required this.isChinese,
    required this.busy,
    required this.onAction,
  });

  final String agentId;
  final AdapterPluginEntry plugin;
  final bool isChinese;
  final bool busy;
  final void Function(
    AdapterPluginEntry plugin,
    AdapterPluginLifecycleAction action,
  )
  onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final (stateLabel, stateColor) = _installationPresentation(
      plugin.installationState,
      isChinese,
      colors,
    );
    final installed = plugin.installationState == 'installed';
    final hasActionArea =
        installed ||
        plugin.supports(AdapterPluginLifecycleAction.install) ||
        plugin.supports(AdapterPluginLifecycleAction.uninstall);
    return Container(
      key: Key('adapter-plugin-entry-$agentId-${plugin.id}'),
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
                  _pluginIcon(plugin.id),
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
                      plugin.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (plugin.detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        plugin.detail,
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: stateColor.withAlpha(20),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: stateColor,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      stateLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: stateColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasActionArea) ...[
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
                    message: isChinese
                        ? '当前已是最新版本'
                        : 'Already on the latest version',
                    child: FilledButton.tonalIcon(
                      key: Key('adapter-update-$agentId-${plugin.id}'),
                      // The catalog carries no version comparison yet, so an
                      // update can never be available; the button stays in
                      // its gray disabled state until one is reported.
                      onPressed: null,
                      style: FilledButton.styleFrom(
                        foregroundColor: colors.success,
                      ),
                      icon: const Icon(
                        Icons.system_update_alt_outlined,
                        size: 17,
                      ),
                      label: Text(isChinese ? '更新' : 'Update'),
                    ),
                  ),
                if (plugin.supports(AdapterPluginLifecycleAction.install))
                  FilledButton.tonalIcon(
                    key: Key('adapter-install-$agentId-${plugin.id}'),
                    onPressed: busy
                        ? null
                        : () => onAction(
                            plugin,
                            AdapterPluginLifecycleAction.install,
                          ),
                    icon: const Icon(Icons.download_outlined, size: 17),
                    label: Text(isChinese ? '安装' : 'Install'),
                  ),
                if (plugin.supports(AdapterPluginLifecycleAction.uninstall))
                  OutlinedButton.icon(
                    key: Key('adapter-uninstall-$agentId-${plugin.id}'),
                    onPressed: busy
                        ? null
                        : () => onAction(
                            plugin,
                            AdapterPluginLifecycleAction.uninstall,
                          ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.error,
                      side: BorderSide(color: colors.error.withAlpha(120)),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 17),
                    label: Text(isChinese ? '卸载' : 'Uninstall'),
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
  const _ReadinessPill({required this.readiness, required this.isChinese});

  final String readiness;
  final bool isChinese;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final (label, color) = switch (readiness) {
      'ready' => (isChinese ? '就绪' : 'Ready', colors.success),
      'partial' => (isChinese ? '部分就绪' : 'Partial', colors.warning),
      'failed' => (isChinese ? '失败' : 'Failed', colors.error),
      'blocked' => (isChinese ? '受阻' : 'Blocked', colors.error),
      'history-only' => (isChinese ? '仅历史' : 'History only', colors.accent),
      'unverified' => (isChinese ? '未验证' : 'Unverified', colors.textMuted),
      _ => (readiness, colors.textMuted),
    };
    return Container(
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
}

(String, IconData) _capabilityPresentation(
  AdapterNativeCapabilityKind kind,
  bool isChinese,
) => switch (kind) {
  AdapterNativeCapabilityKind.desktop => (
    isChinese ? '桌面端' : 'Desktop',
    Icons.desktop_windows_outlined,
  ),
  AdapterNativeCapabilityKind.cli => ('CLI', Icons.terminal),
  AdapterNativeCapabilityKind.acp => ('ACP', Icons.cable_outlined),
  AdapterNativeCapabilityKind.rpc => ('RPC', Icons.sync_alt),
  AdapterNativeCapabilityKind.appServer => ('App Server', Icons.hub_outlined),
  AdapterNativeCapabilityKind.gateway => (
    isChinese ? '网关' : 'Gateway',
    Icons.alt_route,
  ),
  AdapterNativeCapabilityKind.localServer => (
    isChinese ? '本地服务' : 'Local Server',
    Icons.dns_outlined,
  ),
  AdapterNativeCapabilityKind.webServer => (
    'Web Server',
    Icons.language_outlined,
  ),
  AdapterNativeCapabilityKind.tuiGateway => ('TUI Gateway', Icons.alt_route),
};

IconData _pluginIcon(String pluginId) => switch (pluginId) {
  'acp-bridge' => Icons.cable_outlined,
  'lico-up-codex' => Icons.account_tree_outlined,
  _ => Icons.extension_outlined,
};

(String, Color) _installationPresentation(
  String state,
  bool isChinese,
  LicoThemeColors colors,
) => switch (state) {
  'installed' => (isChinese ? '已安装' : 'Installed', colors.success),
  'not-installed' => (isChinese ? '未安装' : 'Not installed', colors.warning),
  'unavailable' => (isChinese ? '不可用' : 'Unavailable', colors.textMuted),
  _ => (state, colors.textMuted),
};

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
