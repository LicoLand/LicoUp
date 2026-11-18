typedef SkillHubStatusSink = void Function(SkillHubStatusUpdate update);

class SkillHubStatusUpdate {
  const SkillHubStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String errorCode;
}
