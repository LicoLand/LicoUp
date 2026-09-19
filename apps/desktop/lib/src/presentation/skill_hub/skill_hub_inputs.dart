import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

/// Narrow immutable Inputs consumed by the skill hub catalog region.
///
/// The catalog is one cohesive read of the hub, its deletion plans, and the
/// usage ledger, so the region carries the whole slice with a value-equality
/// contract instead of reusing [SkillHubProjection] itself.
final class SkillHubCatalogInputs {
  SkillHubCatalogInputs({
    required Iterable<SkillProjectionItem> skills,
    required this.query,
    required this.phase,
    required this.usageAvailable,
    this.notice,
  }) : skills = immutablePresentationList(skills);

  final List<SkillProjectionItem> skills;
  final String query;
  final PresentationPhase phase;
  final bool usageAvailable;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillHubCatalogInputs &&
          samePresentationList(other.skills, skills) &&
          other.query == query &&
          other.phase == phase &&
          other.usageAvailable == usageAvailable &&
          other.notice == notice;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(skills), query, phase, usageAvailable, notice);
}

/// Maps the skill hub projection onto the catalog region slice.
SkillHubCatalogInputs skillHubCatalogInputsOf(SkillHubProjection projection) {
  return SkillHubCatalogInputs(
    skills: projection.skills,
    query: projection.query,
    phase: projection.phase,
    usageAvailable: projection.usageAvailable,
    notice: projection.notice,
  );
}
