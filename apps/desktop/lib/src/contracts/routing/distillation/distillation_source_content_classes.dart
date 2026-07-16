import 'package:flutter/foundation.dart';

import 'distillation_input_window.dart';
import 'distillation_semantics.dart';

@immutable
class DistillationSourceContentClasses {
  const DistillationSourceContentClasses({
    this.hasObjective = false,
    this.hasCurrentState = false,
    this.hasDecisions = false,
    this.hasConstraints = false,
    this.hasOpenItems = false,
    this.semanticAnchors = const {},
  });

  final bool hasObjective;
  final bool hasCurrentState;
  final bool hasDecisions;
  final bool hasConstraints;
  final bool hasOpenItems;
  final Map<String, Set<String>> semanticAnchors;

  factory DistillationSourceContentClasses.detect(
    List<DistillationConversationTurn> turns,
  ) {
    final bySection = <String, Set<String>>{};
    for (final turn in turns) {
      for (final section in distillationSemanticSections(turn.text)) {
        bySection
            .putIfAbsent(section, () => <String>{})
            .addAll(distillationSemanticAnchors(turn.text));
      }
    }
    if (!(bySection['objective']?.isNotEmpty ?? false)) {
      for (final turn in turns) {
        if (turn.role.toLowerCase() == 'user' && turn.text.trim().isNotEmpty) {
          bySection['objective'] = distillationSemanticAnchors(turn.text);
          break;
        }
      }
    }
    if (!(bySection['currentState']?.isNotEmpty ?? false)) {
      for (final turn in turns.reversed) {
        if (turn.role.toLowerCase() == 'assistant' &&
            turn.text.trim().isNotEmpty) {
          bySection['currentState'] = distillationSemanticAnchors(turn.text);
          break;
        }
      }
    }
    return DistillationSourceContentClasses(
      hasObjective: bySection['objective']?.isNotEmpty ?? false,
      hasCurrentState: bySection['currentState']?.isNotEmpty ?? false,
      hasDecisions: bySection['decisions']?.isNotEmpty ?? false,
      hasConstraints: bySection['constraints']?.isNotEmpty ?? false,
      hasOpenItems: bySection['openItems']?.isNotEmpty ?? false,
      semanticAnchors: Map.unmodifiable({
        for (final entry in bySection.entries)
          entry.key: Set.unmodifiable(entry.value),
      }),
    );
  }
}
