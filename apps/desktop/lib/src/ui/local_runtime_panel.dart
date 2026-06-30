import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../services/local_runtime_preferences_service.dart';
import 'panel_frame.dart';
import 'theme.dart';

class LocalRuntimePanel extends StatefulWidget {
  const LocalRuntimePanel({super.key, required this.controller});

  final FutureClientController controller;

  @override
  State<LocalRuntimePanel> createState() => _LocalRuntimePanelState();
}

class _LocalRuntimePanelState extends State<LocalRuntimePanel> {
  late final TextEditingController _portController;

  FutureClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final preferences = controller.localRuntimePreferences;
    _portController = TextEditingController(text: preferences.port.toString());
  }

  @override
  void didUpdateWidget(covariant LocalRuntimePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preferences = controller.localRuntimePreferences;
    _syncController(_portController, preferences.port.toString());
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final state = controller.localRuntimeState ?? const <String, dynamic>{};
    final runtime = _runtimeSnapshot(state);
    final running =
        runtime['running'] == true || runtime['status'] == 'running';
    final runtimeModules = _runtimeModulesSnapshot(state);
    final canEnable = !controller.isLocalRuntimeBusy;
    return PanelFrame(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionTitle(
            icon: Icons.dns_outlined,
            title: 'Runtime',
            trailing: _StatusPill(running: running),
          ),
          const SizedBox(height: 14),
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
          const SizedBox(height: 18),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _portController,
              enabled: !controller.isLocalRuntimeBusy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                prefixIcon: Icon(Icons.tag_outlined),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: canEnable
                    ? () => unawaited(_enableRuntime(rebuild: false))
                    : null,
                icon: Icon(
                  running
                      ? Icons.check_circle_outline
                      : Icons.play_arrow_outlined,
                ),
                label: Text(running ? 'Running' : 'Enable'),
              ),
              OutlinedButton.icon(
                onPressed: canEnable
                    ? () => unawaited(_enableRuntime(rebuild: true))
                    : null,
                icon: const Icon(Icons.construction_outlined),
                label: const Text('Rebuild'),
              ),
              OutlinedButton.icon(
                onPressed: controller.isLocalRuntimeBusy
                    ? null
                    : () => unawaited(controller.refreshLocalRuntimeStatus()),
                icon: const Icon(Icons.refresh_outlined),
                label: const Text('Refresh'),
              ),
              OutlinedButton.icon(
                onPressed: controller.isLocalRuntimeBusy || !running
                    ? null
                    : () =>
                          unawaited(controller.restartConfiguredLocalRuntime()),
                icon: const Icon(Icons.restart_alt_outlined),
                label: const Text('Restart'),
              ),
              OutlinedButton.icon(
                onPressed: controller.isLocalRuntimeBusy || !running
                    ? null
                    : () => unawaited(controller.stopLocalRuntime()),
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop'),
              ),
              OutlinedButton.icon(
                onPressed: controller.isLocalRuntimeBusy
                    ? null
                    : () => unawaited(controller.loadLocalRuntimeLogs()),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Logs'),
              ),
            ],
          ),
          const _Divider(),
          _InfoRow(label: 'Runtime URL', value: _text(runtime['serverUrl'])),
          _InfoRow(
            label: 'Health',
            value: _text(_nested(runtime, const ['health', 'ok'])),
          ),
          _InfoRow(
            label: 'Runtime ID',
            value: _text(_nested(runtime, const ['health', 'serverId'])),
          ),
          _InfoRow(label: 'Data Root', value: _text(runtime['dataRoot'])),
          _InfoRow(
            label: 'Runtime Config',
            value: _text(runtime['runtimeConfigPath']),
          ),
          _InfoRow(label: 'Log File', value: _text(runtime['logPath'])),
          const _Divider(),
          _RuntimeModulesCard(modules: runtimeModules, running: running),
          if (controller.localRuntimeLogLines.isNotEmpty) ...[
            const _Divider(),
            Text(
              'Logs',
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
      ),
    );
  }

  Future<void> _enableRuntime({required bool rebuild}) {
    return controller.ensureLocalRuntime(port: _port(), rebuild: rebuild);
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
          _Metric(label: 'State', value: running ? 'Running' : 'Stopped'),
          _Metric(label: 'URL', value: serverUrl),
          _Metric(label: 'PID', value: pid),
          _Metric(label: 'Secrets', value: secretBackend),
        ],
      ),
    );
  }
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
            running ? 'Running' : 'Stopped',
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

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
        Icon(icon, color: colors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        trailing,
      ],
    );
  }
}

class _RuntimeModulesCard extends StatelessWidget {
  const _RuntimeModulesCard({required this.modules, required this.running});

  final Map<String, dynamic> modules;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final features = _runtimeFeatureEntries(modules);
    final groupedFeatures = _featuresByGroup(features);
    final runtimeModules = _stringList(modules['runtimeModules']);
    final mounts = _runtimeMountNames(modules['mounts']);
    final edition = _firstText([
      modules['edition'],
      _nested(modules, const ['featureProfile', 'edition']),
    ]);
    final profileSource = _firstText([modules['source']]);
    final source = _firstText([
      modules['metadataRoot'],
      modules['activeFeaturesPath'],
      modules['featureProfilePath'],
    ]);
    final hasModuleData =
        features.isNotEmpty || runtimeModules.isNotEmpty || mounts.isNotEmpty;
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
                  'Runtime Modules',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              _CountPill(label: '${features.length} active'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            hasModuleData
                ? 'Current service runtime profile grouped by platform layer${profileSource.isEmpty ? '' : ' from $profileSource'}.'
                : running
                ? 'Runtime module profile is not available from this process.'
                : 'No packaged or installed runtime module profile was found.',
            style: TextStyle(color: colors.textMuted),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _SummaryPill(label: 'Edition', value: edition),
              _SummaryPill(
                label: 'Feature modules',
                value: '${features.length}',
              ),
              _SummaryPill(
                label: 'Runtime modules',
                value: '${runtimeModules.length}',
              ),
              _SummaryPill(label: 'Mounts', value: '${mounts.length}'),
            ],
          ),
          if (source.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              source,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textMuted,
                fontFamily: 'monospace',
              ),
            ),
          ],
          if (groupedFeatures.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final group in groupedFeatures.entries) ...[
              _RuntimeModuleGroup(
                title: _groupLabel(group.key),
                items: group.value,
              ),
              const SizedBox(height: 12),
            ],
          ],
          _StringModuleLayer(
            title: 'Client runtime modules',
            items: runtimeModules,
          ),
          const SizedBox(height: 12),
          _StringModuleLayer(title: 'Runtime mounts', items: mounts),
        ],
      ),
    );
  }
}

class _RuntimeModuleGroup extends StatelessWidget {
  const _RuntimeModuleGroup({required this.title, required this.items});

  final String title;
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title (${items.length})',
          style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              _RuntimeModuleChip(
                label: _runtimeModuleTitle(item),
                detail: _runtimeModuleDescription(item),
              ),
          ],
        ),
      ],
    );
  }
}

class _StringModuleLayer extends StatelessWidget {
  const _StringModuleLayer({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$title (${items.length})',
          style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Text('-', style: TextStyle(color: colors.textMuted))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in items)
                _RuntimeModuleChip(label: item, detail: ''),
            ],
          ),
      ],
    );
  }
}

class _RuntimeModuleChip extends StatelessWidget {
  const _RuntimeModuleChip({required this.label, required this.detail});

  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = label.trim().isEmpty ? '-' : label.trim();
    final detailText = detail.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w700),
            ),
            if (detailText.isNotEmpty && detailText != display) ...[
              const SizedBox(height: 2),
              Text(
                detailText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: colors.textMuted)),
          const SizedBox(width: 8),
          Text(
            display,
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.primaryFixed,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: colors.primary, fontWeight: FontWeight.w800),
      ),
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
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Divider(height: 1, color: colors.line),
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
    'runtimeModules': _stringList(runtimeSummary['runtimeModules']),
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

List<String> _runtimeMountNames(Object? value) {
  final mountMaps = _objectList(value);
  if (mountMaps.isEmpty) {
    return _stringList(value);
  }
  final seen = <String>{};
  final names = <String>[];
  for (final mount in mountMaps) {
    final name = _firstText([mount['name'], mount['id'], mount['kind']]);
    if (name.isNotEmpty && seen.add(name)) {
      names.add(name);
    }
  }
  return names;
}

List<Map<String, dynamic>> _runtimeFeatureEntries(
  Map<String, dynamic> modules,
) {
  final explicit = _objectList(modules['activeFeatures']);
  if (explicit.isNotEmpty) {
    return _normalizeFeatureEntries(explicit);
  }
  final runtimeInfoFeatures = _objectList(
    _nested(modules, const ['runtimeInfo', 'features', 'activeFeatures']),
  );
  if (runtimeInfoFeatures.isNotEmpty) {
    return _normalizeFeatureEntries(runtimeInfoFeatures);
  }
  return _normalizeFeatureEntries([
    for (final id in _stringList(modules['activeFeatureIds']))
      {'featureId': id, 'label': id, 'group': 'runtime'},
  ]);
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
      'group': _firstText([item['group'], 'runtime']),
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

Map<String, List<Map<String, dynamic>>> _featuresByGroup(
  List<Map<String, dynamic>> features,
) {
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final feature in features) {
    final group = _firstText([feature['group'], 'runtime']);
    grouped.putIfAbsent(group, () => <Map<String, dynamic>>[]).add(feature);
  }
  final entries = grouped.entries.toList(growable: false)
    ..sort((a, b) => _groupSortIndex(a.key).compareTo(_groupSortIndex(b.key)));
  return Map<String, List<Map<String, dynamic>>>.fromEntries(entries);
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

String _groupLabel(String group) {
  return _runtimeGroupLabels[group] ?? group;
}

String _runtimeModuleTitle(Map<String, dynamic> item) {
  final id = _firstText([item['featureId'], item['id']]);
  if (id.isNotEmpty) {
    return _titleFromIdentifier(id);
  }
  return _firstText([item['label']]);
}

String _runtimeModuleDescription(Map<String, dynamic> item) {
  final id = _firstText([item['featureId'], item['id']]);
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
  'agent': 'Agent',
  'agent-ingress': 'Agent Ingress',
  'client': 'Client',
  'modules': 'Processing Modules',
  'knowledge': 'Knowledge',
  'connectors': 'Connectors',
  'industry': 'Industry',
  'embedded-server': 'Embedded Server',
  'runtime': 'Runtime',
};
