import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AgentTargetProjection {
  const AgentTargetProjection({
    required this.id,
    required this.displayName,
    required this.available,
    required this.pinned,
    required this.capabilityLabel,
    this.latestConversationPreview = '',
    this.latestConversationSortTimeMillis = 0,
  });

  final String id;
  final String displayName;
  final bool available;
  final bool pinned;
  final String capabilityLabel;
  final String latestConversationPreview;
  final int latestConversationSortTimeMillis;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTargetProjection &&
          other.id == id &&
          other.displayName == displayName &&
          other.available == available &&
          other.pinned == pinned &&
          other.capabilityLabel == capabilityLabel &&
          other.latestConversationPreview == latestConversationPreview &&
          other.latestConversationSortTimeMillis ==
              latestConversationSortTimeMillis;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    available,
    pinned,
    capabilityLabel,
    latestConversationPreview,
    latestConversationSortTimeMillis,
  );
}

final class AgentsProjection {
  AgentsProjection({
    required Iterable<AgentTargetProjection> targets,
    required this.selectedAgentId,
    required this.workingDirectoryLabel,
    required this.phase,
    Iterable<TargetCandidate> targetDetails = const <TargetCandidate>[],
    this.mobileRuntime = false,
    this.scanning = false,
    this.adding = false,
    this.notice,
    AdaptiveFlywheelProjection? adaptiveFlywheel,
  }) : targets = immutablePresentationList(targets),
       targetDetails = immutablePresentationList(targetDetails),
       adaptiveFlywheel =
           adaptiveFlywheel ?? AdaptiveFlywheelProjection.empty();

  final List<AgentTargetProjection> targets;
  final String selectedAgentId;
  final String workingDirectoryLabel;
  final PresentationPhase phase;
  final List<TargetCandidate> targetDetails;
  final bool mobileRuntime;
  final bool scanning;
  final bool adding;
  final PresentationNotice? notice;
  final AdaptiveFlywheelProjection adaptiveFlywheel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentsProjection &&
          samePresentationList(other.targets, targets) &&
          other.selectedAgentId == selectedAgentId &&
          other.workingDirectoryLabel == workingDirectoryLabel &&
          other.phase == phase &&
          samePresentationList(other.targetDetails, targetDetails) &&
          other.mobileRuntime == mobileRuntime &&
          other.scanning == scanning &&
          other.adding == adding &&
          other.notice == notice &&
          other.adaptiveFlywheel == adaptiveFlywheel;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(targets),
    selectedAgentId,
    workingDirectoryLabel,
    phase,
    Object.hashAll(targetDetails),
    mobileRuntime,
    scanning,
    adding,
    notice,
    adaptiveFlywheel,
  );
}
