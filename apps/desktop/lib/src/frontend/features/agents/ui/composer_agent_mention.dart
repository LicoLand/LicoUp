import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

export 'package:licoup/src/application/features/agents/conversation/composer_agent_mention_parsing.dart';

/// One configured Adaptive Flywheel agent shown in the mention picker.
@immutable
final class ComposerFlywheelMentionEntry {
  const ComposerFlywheelMentionEntry({
    required this.agentId,
    required this.displayLabel,
    this.target,
    this.modelName = '',
  });

  final String agentId;
  final String displayLabel;
  final TargetCandidate? target;
  final String modelName;
}

/// Role section in the flywheel mention picker (Assistant / Designer / …).
@immutable
final class ComposerFlywheelMentionSection {
  const ComposerFlywheelMentionSection({
    required this.id,
    required this.title,
    required this.entries,
  });

  final String id;
  final String title;
  final List<ComposerFlywheelMentionEntry> entries;
}

/// Bridge so the flywheel picker can insert into [RuntimeMessageComposer]
/// without lifting the text controller into the workspace.
final class ComposerMentionBridge {
  void Function({
    required String agentId,
    required String displayLabel,
    TargetCandidate? target,
  })?
  _insert;

  void bind(
    void Function({
      required String agentId,
      required String displayLabel,
      TargetCandidate? target,
    })
    insert,
  ) {
    _insert = insert;
  }

  void unbind(
    void Function({
      required String agentId,
      required String displayLabel,
      TargetCandidate? target,
    })
    insert,
  ) {
    if (identical(_insert, insert)) {
      _insert = null;
    }
  }

  void insertMention({
    required String agentId,
    required String displayLabel,
    TargetCandidate? target,
  }) {
    _insert?.call(
      agentId: agentId,
      displayLabel: displayLabel,
      target: target,
    );
  }
}

/// Build mention sections from the saved Adaptive Flywheel policy only.
List<ComposerFlywheelMentionSection> buildComposerFlywheelMentionSections({
  required AgentOrchestrationPolicy policy,
  required List<TargetCandidate> scannedTargets,
  required LicoStrings strings,
}) {
  TargetCandidate? targetFor(String agentId) {
    final id = agentId.trim();
    if (id.isEmpty) return null;
    for (final target in scannedTargets) {
      if (target.target == id) return target;
    }
    return null;
  }

  List<ComposerFlywheelMentionEntry> entriesFor(
    Iterable<DailyConversationAgentAssignment> assignments,
  ) {
    final seen = <String>{};
    final entries = <ComposerFlywheelMentionEntry>[];
    for (final assignment in assignments) {
      if (!assignment.configured) continue;
      final agentId = assignment.agentId.trim();
      if (!seen.add(agentId)) continue;
      final target = targetFor(agentId);
      final label = target != null
          ? agentConversationTargetDisplayName(target)
          : (agentId.isNotEmpty ? agentId : strings.notConfigured);
      entries.add(
        ComposerFlywheelMentionEntry(
          agentId: agentId,
          displayLabel: label,
          target: target,
          modelName: assignment.modelName.trim(),
        ),
      );
    }
    return entries;
  }

  final sections = <ComposerFlywheelMentionSection>[];
  void addSection(String id, String title, List<ComposerFlywheelMentionEntry> entries) {
    if (entries.isEmpty) return;
    sections.add(
      ComposerFlywheelMentionSection(id: id, title: title, entries: entries),
    );
  }

  addSection(
    'daily-conversation',
    strings.dailyConversation,
    entriesFor(policy.dailyConversationAgents),
  );
  addSection(
    'designer',
    strings.codeEngineeringDesigner,
    entriesFor(policy.designerAgents),
  );
  addSection(
    'worker',
    strings.codeEngineeringWorker,
    entriesFor(policy.workerAgents),
  );
  addSection(
    'reviewer',
    strings.codeEngineeringReviewer,
    entriesFor(policy.reviewerAgents),
  );

  // Current Conversation owner may differ from the first daily capsule.
  final commanderId = policy.commanderAgentId.trim();
  if (commanderId.isNotEmpty) {
    final alreadyListed = sections.any(
      (section) => section.entries.any((entry) => entry.agentId == commanderId),
    );
    if (!alreadyListed) {
      final target = targetFor(commanderId);
      final label = target != null
          ? agentConversationTargetDisplayName(target)
          : commanderId;
      addSection(
        'current-conversation',
        strings.currentConversation,
        [
          ComposerFlywheelMentionEntry(
            agentId: commanderId,
            displayLabel: label,
            target: target,
            modelName: policy.commanderModelName.trim(),
          ),
        ],
      );
    }
  }

  return sections;
}
