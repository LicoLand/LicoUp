import 'dart:ui' show Rect;

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_paint.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';

/// One phase header above the cards.
final class CollaborationPhaseLabel {
  const CollaborationPhaseLabel(this.rect, this.title);

  final Rect rect;
  final String title;
}

/// Everything the canvas draws for one projection: display plan, card
/// content, geometry and route styles.
final class CollaborationFlowchartScene {
  CollaborationFlowchartScene._({
    required this.plan,
    required this.models,
    required this.layout,
    required this.edgeStyles,
    required this.routes,
    required this.phases,
  });

  factory CollaborationFlowchartScene.of(
    CollaborationProjection projection, {
    required bool compare,
    required LicoStrings strings,
    required CollaborationCardMetrics metrics,
  }) {
    final plan = CollaborationDisplayPlan.of(projection, compare: compare);
    final models = collaborationCardModels(plan, strings);
    final layout = collaborationGraphLayout(
      plan.structure,
      sizes: {
        for (final entry in models.entries)
          entry.key: metrics.sizeOf(entry.value),
      },
    );
    return CollaborationFlowchartScene._(
      plan: plan,
      models: models,
      layout: layout,
      edgeStyles: collaborationEdgeStyles(plan),
      routes: List.unmodifiable(
        layout.edges.map(CollaborationRouteGeometry.new),
      ),
      phases: List.unmodifiable(_phaseLabels(plan, layout, strings)),
    );
  }

  final CollaborationDisplayPlan plan;

  /// Card content keyed by display id.
  final Map<String, CollaborationCardModel> models;
  final CollaborationGraphLayout layout;
  final Map<String, CollaborationEdgeStyle> edgeStyles;
  final List<CollaborationRouteGeometry> routes;
  final List<CollaborationPhaseLabel> phases;

  late final Set<String> activeRouteKeys = {
    for (final entry in edgeStyles.entries)
      if (entry.value.active) entry.key,
  };

  /// Whether any card shows live work, which is what the ambient loops are
  /// for.
  late final bool live = models.values.any((model) => model.inProgress);

  late final List<(Rect, CollaborationMinimapTone)> minimapCards = [
    for (final card in layout.cards)
      (
        card.rect,
        switch (models[card.id]!) {
          final model when model.inProgress => CollaborationMinimapTone.active,
          final model
              when model.status == CollaborationNodeStatus.waitingUser =>
            CollaborationMinimapTone.waiting,
          final model when model.status == CollaborationNodeStatus.failed =>
            CollaborationMinimapTone.failed,
          final model when model.status == CollaborationNodeStatus.succeeded =>
            CollaborationMinimapTone.done,
          _ => CollaborationMinimapTone.idle,
        },
      ),
  ];

  /// The card follow-latest keeps in view: a decision waiting on the user
  /// first, then the furthest card with live work.
  late final String? followTarget = () {
    CollaborationCardPlacement? best;
    var bestWaiting = false;
    for (final card in layout.cards) {
      final model = models[card.id]!;
      if (!model.inProgress) continue;
      final waiting = model.status == CollaborationNodeStatus.waitingUser;
      if (best == null ||
          (waiting && !bestWaiting) ||
          (waiting == bestWaiting && card.rank > best.rank)) {
        best = card;
        bestWaiting = waiting;
      }
    }
    return best?.id;
  }();

  /// The graph node a card's details describe: for a stack, the step that
  /// needs attention first.
  String detailNodeFor(String displayId) {
    final members = plan.structure.nodeFor(displayId)?.memberIds;
    if (members == null || members.isEmpty) return displayId;
    if (members.length == 1) return members.single;
    const priority = [
      CollaborationNodeStatus.waitingUser,
      CollaborationNodeStatus.failed,
      CollaborationNodeStatus.retrying,
      CollaborationNodeStatus.running,
      CollaborationNodeStatus.waitingAssistant,
    ];
    for (final status in priority) {
      for (final id in members) {
        if (plan.statusOf(id) == status) return id;
      }
    }
    for (final id in members) {
      if (plan.statusOf(id) != CollaborationNodeStatus.succeeded) return id;
    }
    return members.last;
  }

  /// Route keys whose contract edges include one of [edges].
  Set<String> routeKeysFor(Iterable<CollaborationGraphEdge> edges) {
    final keys = {for (final edge in edges) edge.key};
    return {
      for (final route in layout.edges)
        if (route.edge.edges.any((edge) => keys.contains(edge.key))) route.key,
    };
  }

  /// Display ids rendering any of [nodeIds].
  Set<String> displayIdsFor(Iterable<String> nodeIds) => {
    for (final id in nodeIds) ?plan.structure.displayIdOf(id),
  };
}

List<CollaborationPhaseLabel> _phaseLabels(
  CollaborationDisplayPlan plan,
  CollaborationGraphLayout layout,
  LicoStrings strings,
) {
  final labels = <CollaborationPhaseLabel>[];
  for (var i = 0; i < layout.phases.length; i++) {
    final phase = layout.phases[i];
    var steps = 0;
    var stacked = false;
    final agents = <String>{};
    for (final cardId in phase.cardIds) {
      final display = plan.structure.nodeFor(cardId);
      if (display == null) continue;
      switch (display.kind) {
        case CollaborationCardKind.stack:
          stacked = true;
          steps += display.memberIds.length;
        case CollaborationCardKind.task:
          steps += 1;
          final node = plan.graph.nodeById(display.id);
          final fallback = plan.nodeStates[display.id]?.fallback;
          agents.add(fallback?.toAgentId ?? node?.agentId ?? 'lico');
        case CollaborationCardKind.connector:
        case CollaborationCardKind.terminal:
          break;
      }
    }
    if (steps == 0) continue;
    final summary = !stacked && agents.length > 1
        ? strings.collaborationPhaseAgents(agents.length)
        : strings.collaborationPhaseSteps(steps);
    labels.add(
      CollaborationPhaseLabel(
        phase.rect,
        strings.collaborationPhaseTitle(
          labels.length + 1,
          phase.group,
          summary,
        ),
      ),
    );
  }
  return labels;
}
