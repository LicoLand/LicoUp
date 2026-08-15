import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/agent_conversation_search_index.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/destination_search_ranking.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_search.dart';

void main() {
  final features = [
    GlobalSearchFeatureEntry(
      id: 'section-skillHub',
      label: 'Skill Hub',
      keywords: const ['skill'],
      icon: Icons.library_books_outlined,
      run: () async {},
    ),
    GlobalSearchFeatureEntry(
      id: 'section-settings',
      label: 'Settings',
      keywords: const ['setting'],
      icon: Icons.settings_outlined,
      run: () async {},
    ),
  ];
  final settings = [
    GlobalSearchFeatureEntry(
      id: 'settings-appearance',
      label: 'Appearance',
      keywords: const ['appearance', 'theme'],
      icon: Icons.palette_outlined,
      run: () async {},
    ),
  ];
  final agents = [
    GlobalSearchFeatureEntry(
      id: 'agent-codex',
      label: 'Codex',
      keywords: const ['codex'],
      icon: Icons.psychology_outlined,
      run: () async {},
    ),
  ];
  final plugins = [
    GlobalSearchFeatureEntry(
      id: 'plugin-adapter-codex',
      label: 'Codex Plugin',
      keywords: const ['codex', 'plugin'],
      icon: Icons.extension_outlined,
      run: () async {},
    ),
  ];
  const skills = [
    {
      'skillId': 'alpha-writer',
      'title': 'Alpha Writer',
      'description': 'Notes',
    },
    {'skillId': 'other', 'title': 'Other', 'description': 'Alpha notes'},
  ];
  final conversations = [
    AgentConversationSearchHit(
      document: AgentConversationSearchDocument(
        agentId: 'codex',
        sessionId: 's1',
        title: 'Alpha topic',
        content: 'body',
      ),
      score: 1,
      titleMatched: true,
      snippet: 'Alpha topic',
    ),
  ];

  DestinationSearchHits rank(
    ClientSection destination,
    String query, {
    List<AgentConversationSearchHit> hits = const [],
  }) {
    return rankDestinationSearch(
      destination: destination,
      query: query,
      features: features,
      settingsFeatures: settings,
      agentFeatures: agents,
      pluginFeatures: plugins,
      skills: skills,
      skillScore: (skill, needle) =>
          skillHubSearchScore(skill, needle).toDouble(),
      conversations: hits,
    );
  }

  test('chat ranking keeps features ahead of skills and conversations', () {
    final hits = rank(ClientSection.agents, 'Alpha', hits: conversations);
    expect(hits.primary, isEmpty);
    expect(hits.features, isEmpty);
    expect(hits.skills.map((skill) => skill['title']), [
      'Alpha Writer',
      'Other',
    ]);
    expect(hits.conversations, conversations);
  });

  test('settings ranking returns only settings functions', () {
    final matched = rank(
      ClientSection.settings,
      'Appearance',
      hits: conversations,
    );
    expect(matched.primary.map((entry) => entry.id), ['settings-appearance']);
    expect(matched.features, isEmpty);
    expect(matched.skills, isEmpty);
    expect(matched.conversations, isEmpty);

    final missed = rank(ClientSection.settings, 'Alpha', hits: conversations);
    expect(missed.resultCount, 0);
  });

  test('skill hub ranking puts prefix skill matches first', () {
    final hits = rank(ClientSection.skillHub, 'Alpha', hits: conversations);
    expect(hits.skills.map((skill) => skill['title']), [
      'Alpha Writer',
      'Other',
    ]);
    expect(hits.primary, isEmpty);
    expect(hits.conversations, conversations);
  });

  test('agent hub ranking puts agent matches first', () {
    final hits = rank(ClientSection.agentHub, 'Codex', hits: conversations);
    expect(hits.primary.map((entry) => entry.id), ['agent-codex']);
    expect(hits.features, isEmpty);
    expect(hits.conversations, conversations);
  });

  test('plugin ranking puts plugin matches first', () {
    final hits = rank(
      ClientSection.pluginManagement,
      'Plugin',
      hits: conversations,
    );
    expect(hits.primary.map((entry) => entry.id), ['plugin-adapter-codex']);
    expect(hits.conversations, conversations);
  });

  test('prefix field scoring prefers starts-with over contains', () {
    expect(scorePrefixSearchFields('Alpha', const ['Alpha Writer', 'x']), 2);
    expect(scorePrefixSearchFields('Alpha', const ['Helper Alpha']), 1);
    expect(scorePrefixSearchFields('Alpha', const ['Unrelated']), 0);
  });
}
