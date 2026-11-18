import 'package:flutter/foundation.dart';

/// Presentation-only runtime attribution for one Conversation participant.
/// The durable owners remain the workflow binding and Assistant Profile.
@immutable
final class AgentParticipantRuntimeProfile {
  const AgentParticipantRuntimeProfile({
    this.model = '',
    this.reasoningEffort = '',
  });

  final String model;
  final String reasoningEffort;

  bool get hasDetails =>
      model.trim().isNotEmpty || reasoningEffort.trim().isNotEmpty;
}
