import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

import 'fixtures/plugin_management_presentation_fixture.dart';
import 'fixtures/skill_hub_binding_fixture.dart';
import 'fixtures/skill_hub_presentation_fixture.dart';
import 'support/agent_hub_panel_test_support.dart';
import 'support/bundled_font_loader.dart';

void main() {
  testWidgets('official agent detail page matches macOS golden baseline', (
    tester,
  ) async {
    await loadBundledVisualFonts();
    final skillFixture = SkillHubBindingFixture(
      skills: [
        skillHubFixtureSkill(
          id: 'codex-review',
          name: 'Codex Review',
          isPublic: false,
          path: '/synthetic/skills/codex-review',
          agents: const [SkillAgentProjection(id: 'codex', label: 'Codex')],
        ),
        skillHubFixtureSkill(
          id: 'cursor-review',
          name: 'Cursor Review',
          isPublic: false,
          path: '/synthetic/skills/cursor-review',
          agents: const [SkillAgentProjection(id: 'cursor', label: 'Cursor')],
        ),
      ],
    );
    final effects = SemanticEffectChannel<PluginManagementEffect>();
    addTearDown(skillFixture.dispose);
    addTearDown(effects.dispose);
    final plugins = PluginManagementBinding(
      projection: StaticAgentHubProjection(
        PluginManagementProjection(
          plugins: const [],
          workflows: const [],
          phase: PresentationPhase.loading,
        ),
      ),
      intents: SemanticIntentChannel<PluginManagementIntent>((_) {}),
      effects: effects,
    );
    final pluginPresentation = PluginManagementPresentationFixture(
      projection: PluginManagementProjection(
        plugins: const [],
        workflows: const [],
        phase: PresentationPhase.loading,
      ),
    );
    final skillPresentation = SkillHubPresentationFixture(
      projection: skillFixture.binding.projection.current,
    );
    addTearDown(pluginPresentation.dispose);
    addTearDown(skillPresentation.dispose);
    await pumpAgentHubPanel(
      tester,
      buildAgentHubHarness(
        FakeAgentHubEngine(),
        plugins: plugins,
        skills: skillFixture.binding,
        pluginPresentation: pluginPresentation,
        skillPresentation: skillPresentation,
      ),
    );
    await openAgentHubDetail(tester, 'codex');
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/agent_hub_official_detail.png'),
    );
    expect(tester.takeException(), isNull);
  });
}
