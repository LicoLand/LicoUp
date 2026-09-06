import 'package:presentation_contract/presentation_contract.dart';

sealed class SkillHubIntent {
  const SkillHubIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshSkillHub extends SkillHubIntent {
  const RefreshSkillHub({this.agentId = 'codex', super.trace});

  final String agentId;
}

final class SearchSkills extends SkillHubIntent {
  const SearchSkills(this.query, {super.trace});

  final String query;
}

final class PreviewSkillRemoval extends SkillHubIntent {
  const PreviewSkillRemoval(this.skillId, this.path, {super.trace});

  final String skillId;
  final String path;
}

final class ConfirmSkillRemoval extends SkillHubIntent {
  const ConfirmSkillRemoval(
    this.skillId,
    this.path,
    this.confirmation, {
    super.trace,
  });

  final String skillId;
  final String path;
  final String confirmation;
}

final class SetSkillVisual extends SkillHubIntent {
  const SetSkillVisual(
    this.skillId,
    this.iconId,
    this.colorToken, {
    super.trace,
  });

  final String skillId;
  final String iconId;
  final String colorToken;
}
