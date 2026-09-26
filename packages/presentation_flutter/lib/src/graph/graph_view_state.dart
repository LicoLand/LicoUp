/// Local presentation state of one project collaboration graph view.
///
/// Everything here is interface-only: selection, spatial anchor, expansion,
/// filters, zoom and lane order. No member of this state is a lifecycle fact,
/// and changing it never dispatches an action or mutates execution — the
/// acceptance oracle asserts exactly that.
library;

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

/// Which nodes the drawing emphasizes.
///
/// A filter changes what is drawn, never what is counted: collapsed lanes,
/// filtered roles and history still contribute their complete totals.
enum GraphStatusFilter {
  all('all'),
  frontier('frontier'),
  anomalies('anomalies');

  const GraphStatusFilter(this.wireName);

  final String wireName;
}

/// The interface state of one mounted graph.
@immutable
final class GraphViewState {
  const GraphViewState({
    this.selectedNodeId,
    this.selectedGateId,
    this.collapsedProjectIds = const <String>{},
    this.collapsedLaneIds = const <String>{},
    this.highlightedNodeIds = const <String>{},
    this.roleFilter,
    this.filter = GraphStatusFilter.all,
    this.zoom = 1,
    this.panX = 0,
    this.panY = 0,
    this.showList = false,
    this.showInspector = false,
    this.showProjectPanel = false,
    this.showDetailPanel = false,
    this.laneOrder = const <String>[],
  });

  /// The node whose detail is shown, or null.
  final String? selectedNodeId;

  /// The shared gate behind the selection, or null.
  ///
  /// Selecting any anchor of a gate sets this to the gate identity, so the
  /// detail speaks about one gate rather than one reference.
  final String? selectedGateId;

  /// Projects the user folded away. Their nodes stay counted.
  final Set<String> collapsedProjectIds;

  /// Lanes the user folded away.
  final Set<String> collapsedLaneIds;

  /// Real consumers the user asked to locate, from a blocker's own scope.
  final Set<String> highlightedNodeIds;

  final String? roleFilter;
  final GraphStatusFilter filter;

  /// Zoom factor, clamped to the accessible range.
  final double zoom;
  final double panX;
  final double panY;

  /// Compact list instead of the lane drawing.
  final bool showList;

  /// Advanced state-machine inspector instead of the node detail.
  final bool showInspector;

  /// Narrow layout: the project panel is called out.
  final bool showProjectPanel;

  /// Narrow layout: the detail panel is called out.
  final bool showDetailPanel;

  /// Local lane order after a drag. Never written back to execution.
  final List<String> laneOrder;

  static const double minZoom = 0.6;
  static const double maxZoom = 2.4;

  GraphViewState copyWith({
    String? selectedNodeId,
    bool clearSelection = false,
    String? selectedGateId,
    bool clearGate = false,
    Set<String>? collapsedProjectIds,
    Set<String>? collapsedLaneIds,
    Set<String>? highlightedNodeIds,
    String? roleFilter,
    bool clearRoleFilter = false,
    GraphStatusFilter? filter,
    double? zoom,
    double? panX,
    double? panY,
    bool? showList,
    bool? showInspector,
    bool? showProjectPanel,
    bool? showDetailPanel,
    List<String>? laneOrder,
  }) => GraphViewState(
    selectedNodeId: clearSelection
        ? null
        : (selectedNodeId ?? this.selectedNodeId),
    selectedGateId: clearGate ? null : (selectedGateId ?? this.selectedGateId),
    collapsedProjectIds: collapsedProjectIds ?? this.collapsedProjectIds,
    collapsedLaneIds: collapsedLaneIds ?? this.collapsedLaneIds,
    highlightedNodeIds: highlightedNodeIds ?? this.highlightedNodeIds,
    roleFilter: clearRoleFilter ? null : (roleFilter ?? this.roleFilter),
    filter: filter ?? this.filter,
    zoom: zoom == null ? this.zoom : zoom.clamp(minZoom, maxZoom),
    panX: panX ?? this.panX,
    panY: panY ?? this.panY,
    showList: showList ?? this.showList,
    showInspector: showInspector ?? this.showInspector,
    showProjectPanel: showProjectPanel ?? this.showProjectPanel,
    showDetailPanel: showDetailPanel ?? this.showDetailPanel,
    laneOrder: laneOrder ?? this.laneOrder,
  );

  /// Whether a node is drawn under the current expansion, filter and role.
  bool draws(GraphNode node, GraphStatusEntry? status, GraphIndex index) {
    final projectId = index.projectOfNode[node.id];
    if (projectId != null && collapsedProjectIds.contains(projectId)) {
      return false;
    }
    if (node.laneId != null && collapsedLaneIds.contains(node.laneId)) {
      return false;
    }
    if (roleFilter != null && node.role != roleFilter) return false;
    if (filter == GraphStatusFilter.frontier) return status?.ready ?? false;
    if (filter == GraphStatusFilter.anomalies)
      return status?.isAnomaly ?? false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphViewState &&
          other.selectedNodeId == selectedNodeId &&
          other.selectedGateId == selectedGateId &&
          _sameSet(other.collapsedProjectIds, collapsedProjectIds) &&
          _sameSet(other.collapsedLaneIds, collapsedLaneIds) &&
          _sameSet(other.highlightedNodeIds, highlightedNodeIds) &&
          other.roleFilter == roleFilter &&
          other.filter == filter &&
          other.zoom == zoom &&
          other.panX == panX &&
          other.panY == panY &&
          other.showList == showList &&
          other.showInspector == showInspector &&
          other.showProjectPanel == showProjectPanel &&
          other.showDetailPanel == showDetailPanel &&
          _sameList(other.laneOrder, laneOrder);

  @override
  int get hashCode => Object.hash(
    selectedNodeId,
    selectedGateId,
    Object.hashAllUnordered(collapsedProjectIds),
    Object.hashAllUnordered(collapsedLaneIds),
    Object.hashAllUnordered(highlightedNodeIds),
    roleFilter,
    filter,
    zoom,
    showList,
    showInspector,
    showProjectPanel,
    showDetailPanel,
  );
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.every(right.contains);

bool _sameList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
