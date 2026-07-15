import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/local_runtime_preferences.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class LocalRuntimePanel extends StatefulWidget {
  const LocalRuntimePanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<LocalRuntimePanel> createState() => _LocalRuntimePanelState();
}

class _LocalRuntimePanelState extends State<LocalRuntimePanel> {
  late final TextEditingController _sourceRootController;
  late final TextEditingController _presetConfigController;
  late final TextEditingController _portController;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final preferences = controller.localRuntimePreferences;
    _sourceRootController = TextEditingController(text: preferences.sourceRoot);
    _presetConfigController = TextEditingController(
      text: preferences.presetConfig,
    );
    _portController = TextEditingController(text: preferences.port.toString());
  }

  @override
  void didUpdateWidget(covariant LocalRuntimePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preferences = controller.localRuntimePreferences;
    _syncController(_sourceRootController, preferences.sourceRoot);
    _syncController(_presetConfigController, preferences.presetConfig);
    _syncController(_portController, preferences.port.toString());
  }

  @override
  void dispose() {
    _sourceRootController.dispose();
    _presetConfigController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final state = controller.localRuntimeState ?? const <String, dynamic>{};
    final runtime = _runtimeSnapshot(state);
    final running =
        runtime['running'] == true || runtime['status'] == 'running';
    final runtimeModules = _runtimeModulesSnapshot(state);
    final canEnable =
        _sourceRootController.text.trim().isNotEmpty &&
        _presetConfigController.text.trim().isNotEmpty &&
        !controller.isLocalRuntimeBusy;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ─── Status & Controls ───
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.dns_outlined, color: colors.primary, size: 20),
            const SizedBox(width: 10),
            Text(
              strings.runtime,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            _StatusPill(running: running),
            const Spacer(),
            // Primary actions inline
            FilledButton.icon(
              onPressed: canEnable
                  ? () => unawaited(_enableRuntime(rebuild: false))
                  : null,
              icon: Icon(
                running ? Icons.check_circle_outline : Icons.play_arrow_rounded,
                size: 16,
              ),
              label: Text(running ? strings.running : strings.enable),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _RuntimeStatusStrip(
          running: running,
          serverUrl: _text(runtime['serverUrl']),
          pid: _text(runtime['pid']),
          secretBackend: _text(
            _nested(runtime, const [
              'identity',
              'identity',
              'secretStorage',
              'backend',
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // ─── Configuration ───
        _RuntimeSectionLabel(label: strings.configuration, colors: colors),
        const SizedBox(height: 8),
        DirectoryPathField(
          title: strings.sourceRepository,
          label: strings.sourceRepository,
          controller: _sourceRootController,
          icon: Icons.folder_open_outlined,
          enabled: !controller.isLocalRuntimeBusy,
          padding: EdgeInsets.zero,
          onOpen: (path) => controller.openDirectoryPath(
            path,
            caption: strings.sourceRepository,
          ),
        ),
        const SizedBox(height: 8),
        DirectoryPathField(
          title: strings.presetConfig,
          label: strings.presetConfig,
          controller: _presetConfigController,
          icon: Icons.rule_folder_outlined,
          enabled: !controller.isLocalRuntimeBusy,
          padding: EdgeInsets.zero,
          onOpen: (path) => controller.openDirectoryPath(
            _directoryForPath(path),
            caption: strings.presetConfig,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 160,
          child: TextField(
            controller: _portController,
            enabled: !controller.isLocalRuntimeBusy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: strings.port,
              prefixIcon: Icon(
                Icons.tag_outlined,
                size: 16,
                color: colors.textMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Secondary actions
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: canEnable
                  ? () => unawaited(_enableRuntime(rebuild: true))
                  : null,
              icon: const Icon(Icons.construction_outlined, size: 15),
              label: Text(strings.rebuild),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: controller.isLocalRuntimeBusy || !running
                  ? null
                  : () => unawaited(controller.restartConfiguredLocalRuntime()),
              icon: const Icon(Icons.restart_alt_outlined, size: 15),
              label: Text(strings.restart),
            ),
            const SizedBox(width: 6),
            if (running)
              TextButton.icon(
                onPressed: controller.isLocalRuntimeBusy
                    ? null
                    : () => unawaited(controller.stopLocalRuntime()),
                icon: const Icon(Icons.stop_circle_outlined, size: 15),
                label: Text(strings.stop),
                style: TextButton.styleFrom(foregroundColor: colors.error),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: controller.isLocalRuntimeBusy
                  ? null
                  : () => unawaited(controller.loadLocalRuntimeLogs()),
              icon: const Icon(Icons.receipt_long_outlined, size: 15),
              label: Text(strings.logs),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // ─── Server Info ───
        _RuntimeSectionLabel(label: strings.serverInfo, colors: colors),
        const SizedBox(height: 8),
        _InfoRow(label: strings.serverUrl, value: _text(runtime['serverUrl'])),
        _InfoRow(
          label: strings.health,
          value: _text(_nested(runtime, const ['health', 'ok'])),
        ),
        _InfoRow(
          label: strings.serverId,
          value: _text(_nested(runtime, const ['health', 'serverId'])),
        ),
        const SizedBox(height: 12),
        // ─── Paths ───
        _RuntimeSectionLabel(label: strings.paths, colors: colors),
        const SizedBox(height: 8),
        _RuntimePathField(
          controller: controller,
          title: strings.dataRoot,
          path: _text(runtime['dataRoot']),
          icon: Icons.folder_outlined,
        ),
        const SizedBox(height: 6),
        _RuntimePathField(
          controller: controller,
          title: strings.runtimeConfig,
          path: _text(runtime['runtimeConfigPath']),
          icon: Icons.rule_folder_outlined,
          openParent: true,
        ),
        const SizedBox(height: 6),
        _RuntimePathField(
          controller: controller,
          title: strings.logFile,
          path: _text(runtime['logPath']),
          icon: Icons.receipt_long_outlined,
          openParent: true,
        ),
        const SizedBox(height: 16),
        _RuntimeModulesCard(modules: runtimeModules, running: running),
        if (controller.localRuntimeLogLines.isNotEmpty) ...[
          const _Divider(),
          Text(
            strings.logs,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              controller.localRuntimeLogLines.join('\n'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colors.text,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _enableRuntime({required bool rebuild}) {
    return controller.ensureLocalRuntime(
      sourceRoot: _sourceRootController.text,
      presetConfig: _presetConfigController.text,
      port: _port(),
      rebuild: rebuild,
    );
  }

  int _port() {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed <= 0 || parsed > 65535) {
      return LocalRuntimePreferences.defaultPort;
    }
    return parsed;
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) {
      return;
    }
    controller.text = value;
  }
}

class _RuntimePathField extends StatelessWidget {
  const _RuntimePathField({
    required this.controller,
    required this.title,
    required this.path,
    required this.icon,
    this.openParent = false,
  });

  final ClientController controller;
  final String title;
  final String path;
  final IconData icon;
  final bool openParent;

  @override
  Widget build(BuildContext context) {
    return DirectoryPathField(
      title: title,
      label: title,
      path: path,
      icon: icon,
      readOnly: true,
      padding: EdgeInsets.zero,
      onOpen: (value) => controller.openDirectoryPath(
        openParent ? _directoryForPath(value) : value,
        caption: title,
      ),
    );
  }
}

class _RuntimeStatusStrip extends StatelessWidget {
  const _RuntimeStatusStrip({
    required this.running,
    required this.serverUrl,
    required this.pid,
    required this.secretBackend,
  });

  final bool running;
  final String serverUrl;
  final String pid;
  final String secretBackend;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 8,
        children: [
          _Metric(
            label: strings.state,
            value: running ? strings.running : strings.stopped,
          ),
          _Metric(label: 'URL', value: serverUrl),
          _Metric(label: 'PID', value: pid),
          _Metric(label: strings.secrets, value: secretBackend),
        ],
      ),
    );
  }
}

String _directoryForPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '-') {
    return '';
  }
  final basename = p.basename(trimmed);
  return basename.contains('.') ? p.dirname(trimmed) : trimmed;
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: colors.textMuted, fontSize: 12)),
          const SizedBox(height: 3),
          Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final color = running ? colors.success : colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            running ? Icons.circle : Icons.circle_outlined,
            size: 10,
            color: color,
          ),
          const SizedBox(width: 7),
          Text(
            running ? strings.running : strings.stopped,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      children: [
        Icon(icon, color: colors.primary, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        trailing,
      ],
    );
  }
}

class _RuntimeModulesCard extends StatefulWidget {
  const _RuntimeModulesCard({required this.modules, required this.running});

  final Map<String, dynamic> modules;
  final bool running;

  @override
  State<_RuntimeModulesCard> createState() => _RuntimeModulesCardState();
}

class _RuntimeModulesCardState extends State<_RuntimeModulesCard> {
  String? _selectedFeatureId;

  @override
  void didUpdateWidget(covariant _RuntimeModulesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final features = _runtimeFeatureEntries(widget.modules);
    if (_selectedFeatureId != null &&
        !features.any((item) => _runtimeModuleId(item) == _selectedFeatureId)) {
      _selectedFeatureId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final modules = widget.modules;
    final features = _runtimeFeatureEntries(modules);
    final selectedFeature = _selectedRuntimeFeature(features);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_tree_outlined, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.runtimeModules,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          if (features.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RuntimeModuleBrowser(
              features: features,
              selectedFeature: selectedFeature,
              onSelected: (feature) {
                setState(() {
                  _selectedFeatureId = _runtimeModuleId(feature);
                });
              },
            ),
          ] else ...[
            const SizedBox(height: 16),
            Text(
              widget.running
                  ? strings.noRuntimeFeatureModules
                  : strings.runtimeModulesAvailableAfterStartup,
              style: TextStyle(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Map<String, dynamic>? _selectedRuntimeFeature(
    List<Map<String, dynamic>> features,
  ) {
    if (features.isEmpty) {
      return null;
    }
    final selectedId = _selectedFeatureId;
    if (selectedId != null) {
      for (final feature in features) {
        if (_runtimeModuleId(feature) == selectedId) {
          return feature;
        }
      }
    }
    return features.first;
  }
}

class _RuntimeModuleBrowser extends StatelessWidget {
  const _RuntimeModuleBrowser({
    required this.features,
    required this.selectedFeature,
    required this.onSelected,
  });

  final List<Map<String, dynamic>> features;
  final Map<String, dynamic>? selectedFeature;
  final ValueChanged<Map<String, dynamic>> onSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final moduleList = _RuntimeModuleList(
          features: features,
          selectedFeature: selectedFeature,
          onSelected: onSelected,
        );
        final detail = _RuntimeModuleDetailPanel(feature: selectedFeature);
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 280, child: moduleList),
              const SizedBox(height: 14),
              SizedBox(height: 360, child: detail),
            ],
          );
        }
        return SizedBox(
          height: 430,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 340, child: moduleList),
              const SizedBox(width: 16),
              Expanded(child: detail),
            ],
          ),
        );
      },
    );
  }
}

class _RuntimeModuleList extends StatelessWidget {
  const _RuntimeModuleList({
    required this.features,
    required this.selectedFeature,
    required this.onSelected,
  });

  final List<Map<String, dynamic>> features;
  final Map<String, dynamic>? selectedFeature;
  final ValueChanged<Map<String, dynamic>> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final selectedId = selectedFeature == null
        ? ''
        : _runtimeModuleId(selectedFeature!);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Text(
              strings.modules,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: features.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final feature = features[index];
                return _RuntimeModuleListItem(
                  feature: feature,
                  selected: _runtimeModuleId(feature) == selectedId,
                  onTap: () => onSelected(feature),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeModuleListItem extends StatelessWidget {
  const _RuntimeModuleListItem({
    required this.feature,
    required this.selected,
    required this.onTap,
  });

  final Map<String, dynamic> feature;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = _runtimeModuleTitle(feature);
    final description = _runtimeModuleDescription(feature);
    final category = _groupLabel(
      strings,
      _firstText([feature['category'], feature['group'], 'runtime']),
    );
    final status = _runtimeModuleStatus(feature, colors, strings);
    return Material(
      color: selected ? colors.primaryFixed : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? colors.primary : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? colors.primary : colors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: status.tooltip,
                    child: Icon(status.icon, size: 18, color: status.color),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                description.isEmpty ? category : description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuntimeModuleStatus {
  const _RuntimeModuleStatus({
    required this.enabled,
    required this.icon,
    required this.color,
    required this.tooltip,
  });

  final bool enabled;
  final IconData icon;
  final Color color;
  final String tooltip;
}

_RuntimeModuleStatus _runtimeModuleStatus(
  Map<String, dynamic> feature,
  LicoThemeColors colors,
  LicoStrings strings,
) {
  final status = _firstText([
    feature['status'],
    feature['state'],
    feature['availability'],
  ]).toLowerCase();
  final ok = _boolValue(feature['ok']);
  final enabled = _boolValue(feature['enabled']) != false;
  final disabled = _boolValue(feature['disabled']) == true;
  final error = _firstText([feature['error'], feature['lastError']]);
  final abnormal =
      ok == false ||
      error.isNotEmpty ||
      _runtimeWarningStatuses.contains(status) ||
      (status.isNotEmpty &&
          !_runtimeEnabledStatuses.contains(status) &&
          !_runtimeDisabledStatuses.contains(status));
  if (abnormal) {
    return _RuntimeModuleStatus(
      enabled: enabled && !disabled,
      icon: Icons.warning_amber_rounded,
      color: colors.warning,
      tooltip: strings.warning,
    );
  }
  if (!enabled || disabled || _runtimeDisabledStatuses.contains(status)) {
    return _RuntimeModuleStatus(
      enabled: false,
      icon: Icons.close_rounded,
      color: colors.error,
      tooltip: strings.proxyBridgeDisabled,
    );
  }
  return _RuntimeModuleStatus(
    enabled: true,
    icon: Icons.check_rounded,
    color: colors.success,
    tooltip: strings.proxyBridgeEnabled,
  );
}

class _RuntimeModuleDetailPanel extends StatelessWidget {
  const _RuntimeModuleDetailPanel({required this.feature});

  final Map<String, dynamic>? feature;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final item = feature;
    if (item == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          strings.selectRuntimeModule,
          style: TextStyle(color: colors.textMuted),
        ),
      );
    }
    final title = _runtimeModuleTitle(item);
    final description = _runtimeModuleDescription(item);
    final id = _runtimeModuleId(item);
    final category = _groupLabel(
      strings,
      _firstText([item['category'], item['group'], 'runtime']),
    );
    final packaging = _firstText([item['packaging'], item['profile']]);
    final platforms = _stringList(item['platforms']);
    final requires = _stringList(item['requires']);
    final required = item['required'] == true
        ? strings.requiredLabel
        : strings.optionalLabel;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(description, style: TextStyle(color: colors.textMuted)),
          ],
          const SizedBox(height: 16),
          _RuntimeDetailRow(label: strings.moduleId, value: id),
          _RuntimeDetailRow(label: strings.category, value: category),
          _RuntimeDetailRow(
            label: strings.packaging,
            value: packaging.isEmpty ? '-' : _titleFromIdentifier(packaging),
          ),
          _RuntimeDetailRow(label: strings.availability, value: required),
          const SizedBox(height: 14),
          _RuntimeChipSection(title: strings.platforms, items: platforms),
          const SizedBox(height: 14),
          _RuntimeChipSection(
            title: strings.dependencies,
            items: requires.map(_titleFromIdentifier).toList(growable: false),
            emptyLabel: strings.noDependencies,
          ),
        ],
      ),
    );
  }
}

class _RuntimeDetailRow extends StatelessWidget {
  const _RuntimeDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: colors.textMuted)),
          ),
          Expanded(
            child: SelectableText(
              display,
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeChipSection extends StatelessWidget {
  const _RuntimeChipSection({
    required this.title,
    required this.items,
    this.emptyLabel = '-',
  });

  final String title;
  final List<String> items;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: colors.textMuted)),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text(emptyLabel, style: TextStyle(color: colors.textMuted))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in items)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceHigh,
                    border: Border.all(color: colors.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    item,
                    style: TextStyle(
                      color: colors.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label, style: TextStyle(color: colors.textMuted)),
          ),
          Expanded(
            child: SelectableText(
              display,
              style: TextStyle(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Divider(height: 1, color: colors.line.withAlpha(50)),
    );
  }
}

class _RuntimeSectionLabel extends StatelessWidget {
  const _RuntimeSectionLabel({required this.label, required this.colors});

  final String label;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: colors.text,
        letterSpacing: -0.2,
      ),
    );
  }
}

Object? _nested(Map<String, dynamic> source, List<String> keys) {
  Object? current = source;
  for (final key in keys) {
    if (current is! Map) {
      return null;
    }
    current = current[key];
  }
  return current;
}

Map<String, dynamic> _runtimeSnapshot(Map<String, dynamic> state) {
  final nested = _objectMap(state['runtime']);
  if (nested.isEmpty) {
    return state;
  }
  return {...state, ...nested};
}

Map<String, dynamic> _runtimeModulesSnapshot(Map<String, dynamic> state) {
  final runtime = _objectMap(state['runtime']);
  final directCandidates = [
    state['runtimeModules'],
    runtime['runtimeModules'],
    state['modules'],
    runtime['modules'],
  ];
  for (final candidate in directCandidates) {
    final map = _objectMap(candidate);
    if (map.isNotEmpty) {
      return map;
    }
  }

  final runtimeInfo = _objectMap(
    state['runtimeInfo'] ?? runtime['runtimeInfo'],
  );
  if (runtimeInfo.isEmpty) {
    return const <String, dynamic>{};
  }
  final features = _objectMap(runtimeInfo['features']);
  final runtimeSummary = _objectMap(runtimeInfo['runtime']);
  return {
    ...features,
    'runtimeInfo': runtimeInfo,
    'serverModules': _stringList(runtimeSummary['serverModules']),
    'mounts': runtimeSummary['mounts'],
  };
}

Map<String, dynamic> _objectMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> _objectList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value
      .map(_objectMap)
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const [];
  }
  final seen = <String>{};
  final items = <String>[];
  for (final item in value) {
    final text = _text(item).trim();
    if (text.isNotEmpty && seen.add(text)) {
      items.add(text);
    }
  }
  return items;
}

List<Map<String, dynamic>> _runtimeFeatureEntries(
  Map<String, dynamic> modules,
) {
  final activeFeatures = _activeRuntimeFeatureEntries(modules);
  final disabledFeatures = _disabledRuntimeFeatureEntries(modules);
  return _normalizeFeatureEntries([...disabledFeatures, ...activeFeatures]);
}

List<Map<String, dynamic>> _activeRuntimeFeatureEntries(
  Map<String, dynamic> modules,
) {
  final explicit = _objectList(modules['activeFeatures']);
  if (explicit.isNotEmpty) {
    return explicit;
  }
  final runtimeInfoFeatures = _objectList(
    _nested(modules, const ['runtimeInfo', 'features', 'activeFeatures']),
  );
  if (runtimeInfoFeatures.isNotEmpty) {
    return runtimeInfoFeatures;
  }
  return [
    for (final id in _stringList(modules['activeFeatureIds']))
      {'featureId': id, 'label': id, 'group': 'runtime', 'enabled': true},
  ];
}

List<Map<String, dynamic>> _disabledRuntimeFeatureEntries(
  Map<String, dynamic> modules,
) {
  final explicit = _objectList(modules['disabledFeatures']);
  if (explicit.isNotEmpty) {
    return explicit.map(_disabledRuntimeFeatureEntry).toList(growable: false);
  }
  final runtimeInfoFeatures = _objectList(
    _nested(modules, const ['runtimeInfo', 'features', 'disabledFeatures']),
  );
  if (runtimeInfoFeatures.isNotEmpty) {
    return runtimeInfoFeatures
        .map(_disabledRuntimeFeatureEntry)
        .toList(growable: false);
  }
  return [
    for (final id in _stringList(modules['disabledFeatureIds']))
      {
        'featureId': id,
        'label': id,
        'group': 'runtime',
        'enabled': false,
        'status': 'disabled',
      },
  ];
}

Map<String, dynamic> _disabledRuntimeFeatureEntry(Map<String, dynamic> item) {
  return {
    ...item,
    'enabled': false,
    if (_firstText([
      item['status'],
      item['state'],
      item['availability'],
    ]).isEmpty)
      'status': 'disabled',
  };
}

List<Map<String, dynamic>> _normalizeFeatureEntries(
  List<Map<String, dynamic>> source,
) {
  final byId = <String, Map<String, dynamic>>{};
  for (final item in source) {
    final id = _firstText([item['featureId'], item['id']]);
    if (id.isEmpty) {
      continue;
    }
    byId[id] = {
      ...item,
      'featureId': id,
      'label': _firstText([item['label'], id]),
      'group': _firstText([item['group'], item['category'], 'runtime']),
    };
  }
  final items = byId.values.toList(growable: false);
  items.sort((a, b) {
    final groupCompare = _groupSortIndex(
      _text(a['group']),
    ).compareTo(_groupSortIndex(_text(b['group'])));
    if (groupCompare != 0) {
      return groupCompare;
    }
    return _text(a['label']).compareTo(_text(b['label']));
  });
  return items;
}

String _firstText(List<Object?> values) {
  for (final value in values) {
    final text = _text(value).trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '';
}

int _groupSortIndex(String group) {
  final index = _runtimeGroupOrder.indexOf(group);
  return index < 0 ? _runtimeGroupOrder.length : index;
}

String _groupLabel(LicoStrings strings, String group) {
  final trimmed = group.trim();
  if (trimmed.isEmpty) {
    return '-';
  }
  final known = _runtimeGroupLabels[trimmed];
  if (known == null) {
    return _titleFromIdentifier(trimmed);
  }
  return strings.runtimeGroupLabel(trimmed);
}

String _runtimeModuleId(Map<String, dynamic> item) {
  return _firstText([item['featureId'], item['id']]);
}

String _runtimeModuleTitle(Map<String, dynamic> item) {
  final id = _runtimeModuleId(item);
  if (id.isNotEmpty) {
    return _titleFromIdentifier(id);
  }
  return _firstText([item['label']]);
}

String _runtimeModuleDescription(Map<String, dynamic> item) {
  final id = _runtimeModuleId(item);
  final label = _firstText([item['label']]);
  if (label.isEmpty || label == id) {
    return '';
  }
  return label;
}

String _titleFromIdentifier(String value) {
  final words = value
      .trim()
      .split(RegExp(r'[-_\s]+'))
      .where((word) => word.isNotEmpty)
      .map(_titleWord)
      .toList(growable: false);
  return words.join(' ');
}

String _titleWord(String value) {
  final lower = value.toLowerCase();
  const acronyms = {
    'api': 'API',
    'cli': 'CLI',
    'http': 'HTTP',
    'jre': 'JRE',
    'mcp': 'MCP',
    'ocr': 'OCR',
    'pdf': 'PDF',
    'ui': 'UI',
  };
  final acronym = acronyms[lower];
  if (acronym != null) {
    return acronym;
  }
  return '${lower[0].toUpperCase()}${lower.substring(1)}';
}

String _text(Object? value) {
  if (value == null) {
    return '';
  }
  return value.toString();
}

bool? _boolValue(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final normalized = _text(value).trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  if (const {
    'true',
    '1',
    'yes',
    'enabled',
    'active',
    'on',
  }.contains(normalized)) {
    return true;
  }
  if (const {
    'false',
    '0',
    'no',
    'disabled',
    'inactive',
    'off',
  }.contains(normalized)) {
    return false;
  }
  return null;
}

const _runtimeEnabledStatuses = {
  'active',
  'available',
  'configured',
  'enabled',
  'installed',
  'loaded',
  'ok',
  'ready',
  'running',
};

const _runtimeDisabledStatuses = {
  'disabled',
  'inactive',
  'not-running',
  'off',
  'skipped',
  'stopped',
};

const _runtimeWarningStatuses = {
  'blocked',
  'degraded',
  'error',
  'failed',
  'failure',
  'invalid',
  'missing',
  'partial',
  'todo',
  'unavailable',
  'unknown',
};

const _runtimeGroupOrder = [
  'core',
  'security',
  'module-management',
  'data-structure',
  'storage',
  'devops',
  'capabilities',
  'agent',
  'agent-ingress',
  'client',
  'modules',
  'knowledge',
  'connectors',
  'industry',
  'embedded-server',
  'runtime',
];

const _runtimeGroupLabels = {
  'core': 'Core',
  'security': 'Security',
  'module-management': 'Module Management',
  'data-structure': 'Data Structure',
  'storage': 'Storage',
  'devops': 'Devops',
  'capabilities': 'Capabilities',
  'activity': 'Activity',
  'agent': 'Agent',
  'agent-ingress': 'Agent Ingress',
  'agents': 'Agents',
  'client': 'Client',
  'modules': 'Processing Modules',
  'knowledge': 'Knowledge',
  'connectors': 'Connectors',
  'ingestion': 'Ingestion',
  'industry': 'Industry',
  'embedded-server': 'Embedded Server',
  'mcp': 'MCP',
  'mcp-plugins': 'MCP Plugins',
  'mobile-relay': 'Mobile Relay',
  'model-forwarding': 'Model Forwarding',
  'settings': 'Settings',
  'skill-hub': 'Skill Hub',
  'runtime': 'Runtime',
};
