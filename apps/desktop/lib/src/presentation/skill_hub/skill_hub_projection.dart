import 'package:licoup/src/presentation/presentation_semantics.dart';

final class SkillAgentProjection {
  const SkillAgentProjection({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillAgentProjection && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

final class SkillProjectionItem {
  SkillProjectionItem({
    required this.id,
    required this.name,
    required this.author,
    required this.description,
    required this.content,
    required this.sourceLabel,
    required this.version,
    required this.pathLabel,
    required this.public,
    required this.usageCount,
    required this.windowedUsageCount,
    required this.iconId,
    required this.colorToken,
    required Iterable<SkillAgentProjection> agents,
  }) : agents = immutablePresentationList(agents);

  final String id;
  final String name;
  final String author;
  final String description;
  final String content;
  final String sourceLabel;
  final String version;
  final String pathLabel;
  final bool public;
  final int usageCount;
  final int windowedUsageCount;
  final String iconId;
  final String colorToken;
  final List<SkillAgentProjection> agents;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillProjectionItem &&
          other.id == id &&
          other.name == name &&
          other.author == author &&
          other.description == description &&
          other.content == content &&
          other.sourceLabel == sourceLabel &&
          other.version == version &&
          other.pathLabel == pathLabel &&
          other.public == public &&
          other.usageCount == usageCount &&
          other.windowedUsageCount == windowedUsageCount &&
          other.iconId == iconId &&
          other.colorToken == colorToken &&
          samePresentationList(other.agents, agents);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    author,
    description,
    content,
    sourceLabel,
    version,
    pathLabel,
    public,
    usageCount,
    windowedUsageCount,
    iconId,
    colorToken,
    Object.hashAll(agents),
  );
}

final class SkillHubProjection {
  SkillHubProjection({
    required Iterable<SkillProjectionItem> skills,
    required this.query,
    required this.phase,
    this.usageAvailable = false,
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
      other is SkillHubProjection &&
          samePresentationList(other.skills, skills) &&
          other.query == query &&
          other.phase == phase &&
          other.usageAvailable == usageAvailable &&
          other.notice == notice;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(skills), query, phase, usageAvailable, notice);
}
