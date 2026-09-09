import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// Fire-and-forget command intent. Flutter does not mutate Goal truth.
///
/// [command] is the generated ContinuityCommand. [goalId] is the Goal already
/// present on the typed DTO that rendered the control.
final class ContinuousAssistantCommandIntent {
  const ContinuousAssistantCommandIntent({
    required this.command,
    required this.goalId,
  });

  final ContinuityCommand command;
  final String goalId;
}
