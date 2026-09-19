import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_inputs.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_providers.dart';
import 'package:licoup/src/projections/skill_hub/skill_hub_presentation_sources.dart';

import 'presentation_source_fixture.dart';

/// Synthetic skill hub presentation source wired as a provider override for
/// feature widget tests. The region value derives from a [SkillHubProjection]
/// fixture value so test data setup stays unchanged.
final class SkillHubPresentationFixture {
  SkillHubPresentationFixture({SkillHubProjection? projection})
    : catalog = PresentationSourceFixture<SkillHubCatalogInputs>(
        fieldGroup: skillHubCatalogFieldGroup,
        initial: skillHubCatalogInputsOf(projection ?? emptyProjection),
      );

  static final emptyProjection = SkillHubProjection(
    skills: const <SkillProjectionItem>[],
    query: '',
    phase: PresentationPhase.ready,
  );

  final PresentationSourceFixture<SkillHubCatalogInputs> catalog;

  SkillHubCatalogInputs get inputs => catalog.value;

  int get openCount => catalog.openCount;

  int get closeCount => catalog.closeCount;

  List<Override> get overrides => <Override>[
    skillHubCatalogSourceProvider.overrideWithValue(catalog),
  ];

  /// Republishes one projection fixture value as the catalog region slice.
  void publish(SkillHubProjection projection) =>
      catalog.publish(skillHubCatalogInputsOf(projection));

  /// Republishes the catalog without the given skill, mirroring the production
  /// republish that follows a completed removal.
  void removeSkill(String skillId) {
    final current = catalog.value;
    publish(
      SkillHubProjection(
        skills: current.skills.where((skill) => skill.id != skillId),
        query: current.query,
        phase: current.phase,
        usageAvailable: current.usageAvailable,
        notice: current.notice,
      ),
    );
  }

  Future<void> dispose() => catalog.dispose();
}
