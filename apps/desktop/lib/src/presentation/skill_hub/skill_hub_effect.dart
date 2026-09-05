import 'package:presentation_contract/presentation_contract.dart';

sealed class SkillHubEffect {
  const SkillHubEffect({this.trace});

  final TraceContext? trace;
}

final class SkillRemovalPreviewReady extends SkillHubEffect {
  const SkillRemovalPreviewReady(
    this.skillId,
    this.path,
    this.confirmation,
    this.summary, {
    super.trace,
  });

  final String skillId;
  final String path;
  final String confirmation;
  final String summary;
}

final class SkillRemovalCompleted extends SkillHubEffect {
  const SkillRemovalCompleted(this.skillId, {super.trace});

  final String skillId;
}

final class SkillHubActionRejected extends SkillHubEffect {
  const SkillHubActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
