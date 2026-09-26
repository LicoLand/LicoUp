/// The compact list, the node/gate detail and the advanced inspector.
///
/// All three read the same prepared value: there is no second lifecycle and no
/// second fact store. The list and the inspector can be open at the same time
/// as the board, and they show the same statuses, reasons and references.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'graph_resource_view.dart';
import 'graph_view_state.dart';
import 'graph_view_strings.dart';

/// The right-hand detail panel: node detail, shared-gate detail, or the
/// advanced inspector.
class GraphInspectorPanel extends StatelessWidget {
  const GraphInspectorPanel({
    super.key,
    required this.value,
    required this.state,
    required this.update,
    required this.pendingActions,
    required this.onAction,
    required this.onClose,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final Set<String> pendingActions;
  final void Function(GraphActionRequest request) onAction;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final nodeId = state.selectedNodeId;
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            graphSpaceMd,
            graphSpaceSm,
            graphSpaceXs,
            graphSpaceSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  state.showInspector
                      ? strings.inspectorTitle
                      : nodeId == null
                      ? strings.detailsTitle
                      : strings.unitDetailTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                key: const Key('project-collaboration-detail-close'),
                onPressed: onClose,
                icon: const Icon(Icons.close),
                tooltip: strings.closeDetails,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: state.showInspector
              ? AdvancedInspector(
                  value: value,
                  state: state,
                  pendingActions: pendingActions,
                  onAction: onAction,
                )
              : nodeId == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(graphSpaceLg),
                    child: Text(
                      strings.detailEmpty,
                      key: const Key('project-collaboration-detail-empty'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : NodeDetail(
                  nodeId: nodeId,
                  value: value,
                  state: state,
                  update: update,
                  pendingActions: pendingActions,
                  onAction: onAction,
                ),
        ),
      ],
    );
  }
}

/// One node's real facts and the actions its owner declared.
class NodeDetail extends StatelessWidget {
  const NodeDetail({
    super.key,
    required this.nodeId,
    required this.value,
    required this.state,
    required this.update,
    required this.pendingActions,
    required this.onAction,
  });

  final String nodeId;
  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final Set<String> pendingActions;
  final void Function(GraphActionRequest request) onAction;

  @override
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    final index = value.document.index;
    final node = index.nodeById[nodeId];
    final status = value.statusById[nodeId];
    if (node == null || status == null) {
      return const SizedBox.shrink();
    }
    final gateId = node.gateId;
    final gate = gateId == null ? null : index.gateById[gateId];
    return ListView(
      key: Key('project-collaboration-detail-$nodeId'),
      padding: const EdgeInsets.all(graphSpaceMd),
      children: [
        Text(node.title, style: theme.textTheme.titleSmall),
        const SizedBox(height: graphSpaceXs),
        Text(
          strings.roleName(node.role),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: graphSpaceMd),
        _FactRow(
          key: Key('project-collaboration-detail-execution'),
          label: strings.factExecution,
          value: strings.execution(status.execution),
        ),
        _FactRow(
          key: Key('project-collaboration-detail-acceptance'),
          label: strings.factAcceptance,
          value: strings.acceptance(status.acceptance),
        ),
        _FactRow(
          key: Key('project-collaboration-detail-observation'),
          label: strings.factObservation,
          value: strings.observation(status.observation),
        ),
        _FactRow(
          key: Key('project-collaboration-detail-ready'),
          label: strings.factReady,
          value: status.ready ? strings.ready : strings.blocked,
        ),
        _FactRow(
          key: Key('project-collaboration-detail-startable'),
          label: strings.factStartable,
          value: status.startable ? strings.startableNow : strings.blocked,
        ),
        if (!status.startable) ...[
          const Divider(height: graphSpaceLg),
          Text(strings.whyCannotStart, style: theme.textTheme.labelLarge),
          for (final blocker in status.blockers)
            Padding(
              key: Key(
                'project-collaboration-blocker-${blocker.code.wireName}',
              ),
              padding: const EdgeInsets.only(top: graphSpaceSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.blocker(blocker.code),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (blocker.detail != null)
                    Text(
                      blocker.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (blocker.affects.isNotEmpty)
                    TextButton.icon(
                      key: Key(
                        'project-collaboration-highlight-${blocker.code.wireName}',
                      ),
                      onPressed: () => update(
                        state.copyWith(
                          highlightedNodeIds: blocker.affects.toSet(),
                        ),
                      ),
                      icon: const Icon(Icons.highlight_alt, size: 16),
                      label: Text(
                        GraphViewStrings.fill(
                          strings.highlightAffected,
                          <String, String>{
                            'count': '${blocker.affects.length}',
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
        const Divider(height: graphSpaceLg),
        Text(strings.affectedUnits, style: theme.textTheme.labelLarge),
        if (index.consumersOf(nodeId).isEmpty)
          Text(
            strings.noDependents,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: graphSpaceXs,
            runSpacing: graphSpaceXs,
            children: [
              for (final consumer in index.consumersOf(nodeId))
                ActionChip(
                  key: Key('project-collaboration-consumer-$consumer'),
                  label: Text(
                    _shortTitle(index.nodeById[consumer]?.title ?? consumer),
                  ),
                  onPressed: () => update(
                    state.copyWith(
                      selectedNodeId: consumer,
                      highlightedNodeIds: <String>{consumer},
                    ),
                  ),
                ),
            ],
          ),
        const Divider(height: graphSpaceLg),
        Text(strings.actionsTitle, style: theme.textTheme.labelLarge),
        const SizedBox(height: graphSpaceSm),
        if (node.actions.isEmpty)
          Text(
            strings.noActions,
            key: const Key('project-collaboration-no-actions'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: graphSpaceSm,
            runSpacing: graphSpaceSm,
            children: [
              for (final actionRef in node.actions)
                _ActionButton(
                  key: Key('project-collaboration-action-$actionRef'),
                  label: strings.action(actionRef),
                  waitingLabel: strings.waitingForReceipt,
                  pending: _isPending(pendingActions, actionRef, nodeId),
                  requiresConfirmation: _needsConfirmation(actionRef),
                  onPressed: () => _dispatchAction(context, actionRef, node),
                ),
            ],
          ),
        if (gate != null) ...[
          const Divider(height: graphSpaceLg),
          Text(strings.sharedGate, style: theme.textTheme.labelLarge),
          Text(
            '${gate.title} · '
            '${GraphViewStrings.fill(strings.gateSummary, <String, String>{'runs': '${gate.runCount}', 'anchors': '${gate.anchors.length}'})}',
            key: const Key('project-collaboration-gate-count'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const Divider(height: graphSpaceLg),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(strings.inspectorTitle),
          children: [
            _FactRow(
              label: strings.factAttempts,
              value: '${status.attemptCount}',
            ),
            _FactRow(label: strings.factVisits, value: '${status.visitCount}'),
            _FactRow(label: strings.factEvents, value: '${status.eventCount}'),
            _FactRow(
              label: strings.factEvidence,
              value: '${status.evidenceCount}',
            ),
          ],
        ),
        if (status.lastErrorCode != null)
          _FactRow(
            label: strings.factLastError,
            value: status.lastErrorCode!,
            mono: true,
          ),
        if (status.lastEventKind != null)
          _FactRow(
            label: strings.factLastEvent,
            value: status.lastEventKind!,
            mono: true,
          ),
        const SizedBox(height: graphSpaceMd),
      ],
    );
  }

  Future<void> _dispatchAction(
    BuildContext context,
    String actionRef,
    GraphNode node,
  ) async {
    if (_needsConfirmation(actionRef)) {
      final strings = GraphViewStrings.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const Key('project-collaboration-takeover-confirm'),
          title: Text(strings.action(actionRef)),
          content: Text(strings.takeoverBody),
          actions: [
            TextButton(
              key: const Key('project-collaboration-takeover-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('project-collaboration-takeover-confirm-button'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.takeoverConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    onAction(GraphActionRequest(actionRef: actionRef, nodeId: node.id));
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.waitingLabel,
    required this.pending,
    required this.requiresConfirmation,
    required this.onPressed,
  });

  final String label;
  final String waitingLabel;
  final bool pending;
  final bool requiresConfirmation;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final child = Text(pending ? waitingLabel : label);
    if (requiresConfirmation) {
      return FilledButton.tonal(
        onPressed: pending ? null : onPressed,
        child: child,
      );
    }
    return OutlinedButton(onPressed: pending ? null : onPressed, child: child);
  }
}

/// The advanced inspector: real attempts, visits, events, errors and evidence.
class AdvancedInspector extends StatelessWidget {
  const AdvancedInspector({
    super.key,
    required this.value,
    required this.state,
    required this.pendingActions,
    required this.onAction,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final Set<String> pendingActions;
  final void Function(GraphActionRequest request) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    final nodeId = state.selectedNodeId;
    final node = nodeId == null ? null : value.document.index.nodeById[nodeId];
    if (node == null) {
      return Center(
        key: const Key('project-collaboration-inspector-empty'),
        child: Padding(
          padding: const EdgeInsets.all(graphSpaceLg),
          child: Text(
            strings.inspectorEmpty,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final status = value.statusById[nodeId];
    return ListView(
      key: Key('project-collaboration-inspector-$nodeId'),
      padding: const EdgeInsets.all(12),
      children: [
        Text(node.title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _FactRow(label: 'Status', value: status?.acceptance.wireName ?? '—'),
        _FactRow(label: 'Execution', value: status?.execution.wireName ?? '—'),
        _FactRow(
          label: 'Observation',
          value: status?.observation.wireName ?? '—',
        ),
        const Divider(height: 20),
        Text('Attempts', style: theme.textTheme.labelLarge),
        if (node.attempts.isEmpty)
          Text('No attempt recorded', style: theme.textTheme.bodySmall)
        else
          for (final attempt in node.attempts)
            ListTile(
              key: Key('project-collaboration-attempt-${attempt.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${attempt.id} · ${attempt.state.wireName}'),
              subtitle: Text(
                '${attempt.role}${attempt.route == null ? '' : ' · ${attempt.route}'}'
                '${attempt.errorCode == null ? '' : ' · ${attempt.errorCode}: ${attempt.errorDetail ?? ''}'}',
              ),
            ),
        const Divider(height: 20),
        Text('Visits and joins', style: theme.textTheme.labelLarge),
        if (node.visits.isEmpty)
          Text('No visit recorded', style: theme.textTheme.bodySmall)
        else
          for (final visit in node.visits)
            ListTile(
              key: Key('project-collaboration-visit-${visit.id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${visit.id} · ${visit.kind.wireName}'),
              subtitle: visit.at == null ? null : Text(visit.at!),
            ),
        const Divider(height: 20),
        Text('Events', style: theme.textTheme.labelLarge),
        if (node.events.isEmpty)
          Text('No event recorded', style: theme.textTheme.bodySmall)
        else
          for (final event in node.events)
            ListTile(
              key: Key(
                'project-collaboration-event-${event.kind}-${event.at ?? ''}',
              ),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(event.kind),
              subtitle: Text(
                '${event.at ?? ''}${event.detail == null ? '' : ' · ${event.detail}'}',
              ),
            ),
        const Divider(height: 20),
        Text('Evidence', style: theme.textTheme.labelLarge),
        if (node.evidence.isEmpty)
          Text(
            'No evidence reference recorded',
            style: theme.textTheme.bodySmall,
          )
        else
          for (final evidence in node.evidence)
            ListTile(
              key: Key('project-collaboration-evidence-${evidence.ref}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(evidence.ref),
              subtitle: Text(evidence.kind),
            ),
        const Divider(height: 20),
        Text('Consumes and produces', style: theme.textTheme.labelLarge),
        if (node.consumes.isEmpty && node.results.isEmpty)
          Text(
            'No typed result reference declared',
            style: theme.textTheme.bodySmall,
          )
        else ...[
          for (final consumed in node.consumes)
            _FactRow(
              label: 'consumes',
              value: '${consumed.nodeId} (${consumed.kind.wireName})',
            ),
          for (final result in node.results)
            _FactRow(
              label: 'produces',
              value: '${result.nodeId} (${result.kind.wireName})',
            ),
        ],
      ],
    );
  }
}

/// The compact list: the same facts as the board, one row per unit.
class GraphCompactList extends StatelessWidget {
  const GraphCompactList({
    super.key,
    required this.value,
    required this.state,
    required this.onSelect,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = value.document.index;
    final rows = <String>[
      for (final id in value.layout.visibleNodeIds)
        if (state.draws(index.nodeById[id]!, value.statusById[id], index)) id,
    ];
    return ListView.builder(
      key: const Key('project-collaboration-list'),
      itemCount: rows.length,
      itemBuilder: (context, position) {
        final id = rows[position];
        final node = index.nodeById[id]!;
        final status = value.statusById[id];
        return ListTile(
          key: Key('project-collaboration-list-row-$id'),
          dense: true,
          selected: state.selectedNodeId == id,
          onTap: () => onSelect(id),
          title: Text(node.title, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${status?.execution.wireName ?? '—'} · '
            '${status?.acceptance.wireName ?? '—'} · '
            '${status?.observation.wireName ?? '—'}'
            '${status?.mainBlocker == null ? '' : ' · ${status!.mainBlocker!.code.wireName}'}',
            style: theme.textTheme.bodySmall,
          ),
          trailing: Text(
            status?.startable == true
                ? 'startable'
                : status?.ready == true
                ? 'ready'
                : 'blocked',
            style: theme.textTheme.labelSmall,
          ),
        );
      },
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;

  /// Exact values and identifiers use the mono face, per the type system.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'Geist Mono',
                    )
                  : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether the same action is already waiting for its native receipt.
bool _isPending(Set<String> pending, String actionRef, String nodeId) => pending
    .contains(GraphActionRequest(actionRef: actionRef, nodeId: nodeId).key);

bool _needsConfirmation(String actionRef) =>
    actionRef.contains('takeover') ||
    actionRef.contains('import') ||
    actionRef.contains('insert') ||
    actionRef.contains('cancel') ||
    actionRef.contains('pause');

String _shortTitle(String id) {
  final slash = id.lastIndexOf('/');
  return slash < 0 ? id : id.substring(slash + 1);
}
