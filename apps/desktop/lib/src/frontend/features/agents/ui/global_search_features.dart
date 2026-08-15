import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/agent_product_names.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_section_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// One jump target in the global search: a destination section or an action
/// such as starting a new conversation. Feature hits always rank ahead of
/// conversation content hits.
class GlobalSearchFeatureEntry {
  const GlobalSearchFeatureEntry({
    required this.id,
    required this.label,
    required this.keywords,
    required this.icon,
    required this.run,
  });

  final String id;
  final String label;
  final List<String> keywords;
  final IconData icon;
  final Future<void> Function() run;

  double matchScore(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return 0;
    }
    final lowerLabel = label.toLowerCase();
    var score = 0.0;
    if (lowerLabel.contains(normalized)) {
      score += 6;
    }
    if (keywords.any((keyword) => keyword.toLowerCase().contains(normalized))) {
      score += 3;
    }
    for (final term
        in normalized.split(RegExp(r'\s+')).where((term) => term.isNotEmpty)) {
      if (lowerLabel.contains(term)) {
        score += 2;
      } else if (keywords.any(
        (keyword) => keyword.toLowerCase().contains(term),
      )) {
        score += 1;
      }
    }
    return score;
  }
}

List<GlobalSearchFeatureEntry> buildGlobalSearchFeatures({
  required LicoStrings strings,
  required void Function(ClientSection section) onSelectSection,
  required VoidCallback onNewConversation,
}) {
  GlobalSearchFeatureEntry section(
    ClientSection value,
    String label,
    IconData icon,
    List<String> keywords,
  ) {
    return GlobalSearchFeatureEntry(
      id: 'section-${value.name}',
      label: label,
      keywords: [value.name, ...keywords],
      icon: icon,
      run: () async => onSelectSection(value),
    );
  }

  return [
    section(
      ClientSection.agentHub,
      strings.agentHub,
      Icons.auto_awesome_outlined,
      const ['agent', 'hub', '智能体中心', '适配'],
    ),
    section(
      ClientSection.agents,
      strings.agents,
      Icons.psychology_outlined,
      const ['agent', 'chat', '智能体', '对话'],
    ),
    section(
      ClientSection.monitoring,
      strings.tokenUsage,
      Icons.query_stats_outlined,
      const ['token', 'usage', 'chart', 'monitoring', '用量', '统计', '图表'],
    ),
    section(
      ClientSection.skillHub,
      strings.skillHub,
      Icons.library_books_outlined,
      const ['skill', 'hub', '技能'],
    ),
    section(
      ClientSection.pluginManagement,
      strings.pluginManagement,
      Icons.extension_outlined,
      const ['plugin', 'adapter', '插件', '适配器'],
    ),
    section(
      ClientSection.mobileRelay,
      strings.mobileRelay,
      Icons.phonelink_outlined,
      const ['mobile', 'relay', 'pair', '配对', '通信'],
    ),
    section(ClientSection.models, strings.keys, Icons.key_outlined, const [
      'model',
      'api',
      'key',
      'gateway',
      '模型',
      '密钥',
      '网关',
    ]),
    section(
      ClientSection.settings,
      strings.settings,
      Icons.settings_outlined,
      const ['setting', 'preference', '设置'],
    ),
    GlobalSearchFeatureEntry(
      id: 'action-new-conversation',
      label: strings.newConversation,
      keywords: const ['new', 'conversation', 'chat', '新建', '新对话'],
      icon: Icons.add_comment_outlined,
      run: () async => onNewConversation(),
    ),
  ];
}

List<GlobalSearchFeatureEntry> buildSettingsSearchFeatures({
  required LicoStrings strings,
  required VoidCallback onOpenSettings,
}) {
  return [
    for (final section in settingsSectionDescriptors(strings))
      GlobalSearchFeatureEntry(
        id: 'settings-${section.id}',
        label: section.label,
        keywords: [section.id, 'setting', 'settings', 'preference', '设置'],
        icon: section.icon,
        run: () async => onOpenSettings(),
      ),
  ];
}

List<GlobalSearchFeatureEntry> buildAgentSearchFeatures({
  required List<TargetCandidate> targets,
  required VoidCallback onOpenAgentHub,
}) {
  return [
    for (final target in targets)
      if (target.isConversationAgent || target.visibleInClient)
        GlobalSearchFeatureEntry(
          id: 'agent-${target.target}',
          label: agentProductLabel(target.label),
          keywords: [target.target, target.id, target.label, 'agent', '智能体'],
          icon: Icons.psychology_outlined,
          run: () async => onOpenAgentHub(),
        ),
  ];
}

List<GlobalSearchFeatureEntry> buildPluginSearchFeatures({
  required List<AdapterPluginDescriptor> adapters,
  required VoidCallback onOpenPlugins,
}) {
  return [
    for (final adapter in adapters) ...[
      GlobalSearchFeatureEntry(
        id: 'plugin-adapter-${adapter.agentId}',
        label: agentProductLabel(adapter.label),
        keywords: [
          adapter.agentId,
          adapter.label,
          'plugin',
          'adapter',
          '插件',
          '适配器',
        ],
        icon: Icons.extension_outlined,
        run: () async => onOpenPlugins(),
      ),
      for (final plugin in adapter.plugins)
        GlobalSearchFeatureEntry(
          id: 'plugin-entry-${adapter.agentId}-${plugin.id}',
          label: plugin.label,
          keywords: [plugin.id, plugin.detail, adapter.agentId, 'plugin', '插件'],
          icon: Icons.extension_outlined,
          run: () async => onOpenPlugins(),
        ),
    ],
  ];
}
