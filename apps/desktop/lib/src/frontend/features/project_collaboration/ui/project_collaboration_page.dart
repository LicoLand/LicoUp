/// The project collaboration page: the board, the insert flow and the receipt
/// line.
///
/// Every control on this page is a request. The page never writes execution
/// state, never marks a unit paused or cancelled on its own, and never applies
/// a preview: it dispatches through the session's validated port and renders
/// what the native owner answered.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import '../../../../presentation/project_collaboration/project_collaboration_surface.dart';
import 'project_collaboration_strings.dart';

/// The project collaboration surface.
class ProjectCollaborationPage extends StatefulWidget {
  const ProjectCollaborationPage({
    super.key,
    required this.surface,
    this.initialViewState = const GraphViewState(),
  });

  /// What the page may ask the host for. The composition owns the session.
  final ProjectCollaborationSurface surface;
  final GraphViewState initialViewState;

  @override
  State<ProjectCollaborationPage> createState() =>
      _ProjectCollaborationPageState();
}

class _ProjectCollaborationPageState extends State<ProjectCollaborationPage> {
  final Set<String> _pending = <String>{};
  String _insertLaneId = '';
  String _insertRole = '';

  Future<void> _dispatch(GraphActionRequest request) async {
    final revision = widget.surface.current?.document.planRevision;
    if (revision == null) return;
    setState(() => _pending.add(request.key));
    try {
      // The surface validates the revision and forwards the request; the
      // receipt the native owner answers with is published on its stream.
      await widget.surface.request(
        actionRef: request.actionRef,
        revision: revision,
        nodeId: request.nodeId,
        values: request.values,
      );
    } finally {
      if (mounted) setState(() => _pending.remove(request.key));
    }
  }

  Future<void> _openInsertDialog() async {
    final project =
        widget.surface.current?.document.projects ?? const <GraphProject>[];
    final roles = <String>{
      for (final entry in project)
        for (final node in entry.nodes) node.role,
    }.toList()..sort();
    final lanes = <String>{
      for (final entry in project)
        for (final lane in entry.lanes) lane.id,
    }.toList()..sort();
    // Defaults are chosen when the dialog opens: the first revision may not
    // have been admitted yet when the page was constructed.
    final request = await showDialog<_InsertRequest>(
      context: context,
      builder: (context) => InsertUnitDialog(
        lanes: lanes,
        roles: roles,
        initialLaneId: lanes.contains(_insertLaneId)
            ? _insertLaneId
            : (lanes.isEmpty ? null : lanes.first),
        initialRole: roles.contains(_insertRole)
            ? _insertRole
            : (roles.isEmpty ? null : roles.first),
      ),
    );
    if (request == null || !mounted) return;
    _insertLaneId = request.laneId;
    _insertRole = request.role;
    await _previewInsert(request);
  }

  Future<void> _previewInsert(_InsertRequest request) async {
    setState(() => _pending.add('insert-preview'));
    try {
      final preview = await widget.surface.previewInsert(
        unitRef: request.unitRef,
        laneId: request.laneId,
        role: request.role,
      );
      if (!mounted) return;
      if (preview == null) return;
      await showDialog<bool>(
        context: context,
        builder: (context) {
          final strings = GraphViewStrings.of(context);
          return AlertDialog(
            key: const Key('project-collaboration-insert-impact'),
            title: Text(strings.insertImpactTitle),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    GraphViewStrings.fill(
                      strings.planRevision,
                      <String, String>{'revision': '${preview.revision}'},
                    ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: graphSpaceSm),
                  Text(
                    preview.affectedNodeIds.isEmpty
                        ? strings.insertImpactNone
                        : GraphViewStrings.fill(
                            strings.insertImpactAffected,
                            <String, String>{
                              'count': '${preview.affectedNodeIds.length}',
                            },
                          ),
                    key: const Key('project-collaboration-insert-affected'),
                  ),
                  for (final id in preview.affectedNodeIds)
                    Text(
                      id,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontFamily: 'Geist Mono',
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                key: const Key('project-collaboration-insert-commit-cancel'),
                onPressed: () {
                  widget.surface.cancelInsert();
                  Navigator.of(context).pop();
                },
                child: Text(strings.insertDiscard),
              ),
              FilledButton(
                key: const Key('project-collaboration-insert-commit'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(
                  GraphViewStrings.fill(strings.insertCommit, <String, String>{
                    'revision': '${preview.revision}',
                  }),
                ),
              ),
            ],
          );
        },
      ).then((commit) async {
        if (commit != true || !mounted) return;
        setState(() => _pending.add('insert-commit'));
        try {
          await widget.surface.commitInsert();
        } finally {
          if (mounted) setState(() => _pending.remove('insert-commit'));
        }
      });
    } finally {
      if (mounted) setState(() => _pending.remove('insert-preview'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = graphViewStringsFor(
      Localizations.localeOf(context).languageCode,
    );
    return GraphViewStringsScope(
      strings: strings,
      child: Column(
        key: const Key('project-collaboration-page'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: graphSpaceMd,
              vertical: graphSpaceSm,
            ),
            child: Row(
              children: [
                StreamBuilder<GraphPreparedValue?>(
                  key: ValueKey(('availability', widget.surface)),
                  stream: widget.surface.displayed,
                  initialData: widget.surface.current,
                  builder: (context, snapshot) => FilledButton.tonalIcon(
                    key: const Key('project-collaboration-insert'),
                    onPressed: widget.surface.canRequestActions
                        ? _openInsertDialog
                        : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(strings.insertUnit),
                  ),
                ),
                const SizedBox(width: graphSpaceMd),
                Expanded(
                  child: StreamBuilder<ProjectCollaborationReceipt>(
                    key: ValueKey(('receipts', widget.surface)),
                    stream: widget.surface.receipts,
                    initialData: widget.surface.lastReceipt,
                    builder: (context, snapshot) {
                      final receipt = snapshot.data;
                      if (receipt == null) return const SizedBox.shrink();
                      // The line states the outcome in words and names the plan
                      // revision as a value; no internal code is shown.
                      final message = GraphViewStrings.fill(
                        strings.receiptLine,
                        <String, String>{
                          'message': strings.receipt(receipt.code),
                          'revision': '${receipt.revision}',
                        },
                      );
                      return Text(
                        message,
                        key: const Key('project-collaboration-receipt'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: !receipt.accepted
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<GraphPreparedValue?>(
              stream: widget.surface.displayed,
              initialData: widget.surface.current,
              builder: (context, snapshot) {
                final value = snapshot.data;
                return GraphResourceView(
                  value: value,
                  initialState: widget.initialViewState,
                  // A withdrawn authority names its own reason, so the surface
                  // says `source_unavailable` instead of a generic loading state.
                  unavailableReason: value == null
                      ? (widget.surface.unavailableReason ?? 'loading')
                      : null,
                  pendingActions: _pending,
                  onAction: _dispatch,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The value one insert dialog collects.
final class _InsertRequest {
  const _InsertRequest({
    required this.unitRef,
    required this.laneId,
    required this.role,
  });

  final String unitRef;
  final String laneId;
  final String role;
}

/// The insert dialog: a bounded unit reference plus the lane and role the
/// native owner resolves. Nothing is inserted here; the preview answers with
/// the impact and the revision a commit must cite.
class InsertUnitDialog extends StatefulWidget {
  const InsertUnitDialog({
    super.key,
    required this.lanes,
    required this.roles,
    this.initialLaneId,
    this.initialRole,
  });

  final List<String> lanes;
  final List<String> roles;
  final String? initialLaneId;
  final String? initialRole;

  @override
  State<InsertUnitDialog> createState() => _InsertUnitDialogState();
}

class _InsertUnitDialogState extends State<InsertUnitDialog> {
  late final TextEditingController _unitRef = TextEditingController();
  late String? _laneId = widget.initialLaneId;
  late String? _role = widget.initialRole;

  @override
  void dispose() {
    _unitRef.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = GraphViewStrings.of(context);
    return AlertDialog(
      key: const Key('project-collaboration-insert-dialog'),
      title: Text(strings.insertTitle),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('project-collaboration-insert-unit-ref'),
              controller: _unitRef,
              decoration: InputDecoration(
                labelText: strings.insertUnitRef,
                helperText: strings.insertUnitRefHelp,
              ),
              // The button follows the controller itself, so a programmatic
              // change (an IME composition, a test injection) enables it just
              // like typing does.
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('project-collaboration-insert-lane'),
              initialValue: _laneId,
              items: <DropdownMenuItem<String>>[
                for (final lane in widget.lanes)
                  DropdownMenuItem<String>(value: lane, child: Text(lane)),
              ],
              onChanged: (value) => setState(() => _laneId = value),
              decoration: InputDecoration(labelText: strings.insertLane),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('project-collaboration-insert-role'),
              initialValue: _role,
              items: <DropdownMenuItem<String>>[
                for (final role in widget.roles)
                  DropdownMenuItem<String>(value: role, child: Text(role)),
              ],
              onChanged: (value) => setState(() => _role = value),
              decoration: InputDecoration(labelText: strings.insertRole),
            ),
            const SizedBox(height: 12),
            Text(
              strings.insertNote,
              key: const Key('project-collaboration-insert-note'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('project-collaboration-insert-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _unitRef,
          builder: (context, value, _) => FilledButton(
            key: const Key('project-collaboration-insert-preview'),
            onPressed:
                value.text.trim().isEmpty || _laneId == null || _role == null
                ? null
                : () => Navigator.of(context).pop(
                    _InsertRequest(
                      unitRef: value.text.trim(),
                      laneId: _laneId!,
                      role: _role!,
                    ),
                  ),
            child: Text(strings.insertPreview),
          ),
        ),
      ],
    );
  }
}
