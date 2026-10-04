/// The host's compiled primitive renderers.
///
/// Every widget here is compiled into the shell. A contribution supplies data
/// and names one of them; it never supplies a widget, a callback or a builder,
/// so the mounted contribution is the only thing that crosses the boundary and
/// it carries plain values only. Focus, input-method editing, accessibility and
/// theming stay with these widgets, not with the contribution.
library;

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

/// Renders one mounted contribution through its registered primitive.
///
/// The primitive decides which compiled widget renders; a contribution whose
/// primitive this build did not compile shows the bounded unavailable state
/// instead of a neighbouring primitive's output.
class HostPrimitiveView extends StatelessWidget {
  const HostPrimitiveView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) => switch (contribution.primitive) {
    DeclarativePrimitive.text => HostTextView(contribution: contribution),
    DeclarativePrimitive.progress => HostProgressView(
      contribution: contribution,
    ),
    DeclarativePrimitive.table => HostTableView(contribution: contribution),
    DeclarativePrimitive.form => HostFormView(contribution: contribution),
    DeclarativePrimitive.command => HostCommandView(contribution: contribution),
    DeclarativePrimitive.action => HostActionView(contribution: contribution),
    // `chart` is a resource view: it renders through the host's bounded
    // pure-data renderer for its declared format, which is not compiled in this
    // build. The contribution stays visible as unavailable rather than being
    // drawn as a different primitive.
    DeclarativePrimitive.chart => HostUnavailableView(
      contribution: contribution,
      reason: 'chart_renderer_uncompiled',
    ),
  };
}

/// The host-owned unavailable state of one contribution.
///
/// The state is visible and bounded: it names the contribution and its stable
/// reason, and it affects nothing else on the page.
class HostUnavailableView extends StatelessWidget {
  const HostUnavailableView({
    super.key,
    required this.contribution,
    required this.reason,
  });

  final MountedContribution contribution;
  final String reason;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${contribution.id}: unavailable ($reason)',
    child: Padding(
      key: Key('host-unavailable-${contribution.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        reason,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Theme.of(context).disabledColor),
      ),
    ),
  );
}

/// The host's text primitive.
///
/// The value is a plain string the plan carried; the primitive interprets no
/// markup and renders no contribution-supplied node.
class HostTextView extends StatelessWidget {
  const HostTextView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) {
    final value = contribution.inputs['text'];
    if (value is! String || value.isEmpty) {
      return HostUnavailableView(
        contribution: contribution,
        reason: 'value_missing',
      );
    }
    return Text(
      value,
      key: Key('host-text-${contribution.id}'),
      style: Theme.of(context).textTheme.bodyMedium,
    );
  }
}

/// The host's progress primitive.
///
/// The value is a fraction between zero and one. A value outside that range is
/// clamped, so a plan cannot render an impossible bar.
class HostProgressView extends StatelessWidget {
  const HostProgressView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) {
    final value = contribution.inputs['value'];
    if (value is! num) {
      return HostUnavailableView(
        contribution: contribution,
        reason: 'value_missing',
      );
    }
    return LinearProgressIndicator(
      key: Key('host-progress-${contribution.id}'),
      value: value.toDouble().clamp(0, 1),
    );
  }
}

/// The host's table primitive.
///
/// Rows are plain string lists of equal length; the primitive owns header,
/// dividers and selection styling.
class HostTableView extends StatelessWidget {
  const HostTableView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) {
    final rows = _rows(contribution.inputs['rows']);
    if (rows == null) {
      return HostUnavailableView(
        contribution: contribution,
        reason: 'value_missing',
      );
    }
    return Column(
      key: Key('host-table-${contribution.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < rows.length; index++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                for (final cell in rows[index])
                  Expanded(
                    child: Text(
                      cell,
                      style: index == 0
                          ? Theme.of(context).textTheme.labelLarge
                          : Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static List<List<String>>? _rows(Object? value) {
    if (value is! List || value.isEmpty) return null;
    final rows = <List<String>>[];
    for (final row in value) {
      if (row is! List || row.isEmpty) return null;
      final cells = <String>[];
      for (final cell in row) {
        if (cell is! String) return null;
        cells.add(cell);
      }
      rows.add(cells);
    }
    return rows;
  }
}

/// The host's form primitive.
///
/// A form shows the field values the prepared resource carries. Typing stays
/// local input state in this widget and never invalidates a prepared value;
/// only an explicit submit crosses into the application through the action the
/// plan bound.
class HostFormView extends StatefulWidget {
  const HostFormView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  State<HostFormView> createState() => _HostFormViewState();
}

class _HostFormViewState extends State<HostFormView> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  @override
  void didUpdateWidget(HostFormView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.contribution, widget.contribution)) _adopt();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _adopt() {
    final fields = widget.contribution.inputs['fields'];
    if (fields is! List) return;
    for (final field in fields) {
      if (field is! Map) continue;
      final id = field['id'];
      if (id is! String || id.isEmpty) continue;
      final value = field['value'];
      _controllers.putIfAbsent(id, () => TextEditingController()).text =
          value is String ? value : '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.contribution.inputs['fields'];
    if (fields is! List || fields.isEmpty) {
      return HostUnavailableView(
        contribution: widget.contribution,
        reason: 'value_missing',
      );
    }
    final rows = <Widget>[];
    for (final field in fields) {
      if (field is! Map) continue;
      final id = field['id'];
      final label = field['label'];
      if (id is! String || id.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextField(
            key: Key('host-form-${widget.contribution.id}-$id'),
            controller: _controllers.putIfAbsent(
              id,
              () => TextEditingController(),
            ),
            decoration: InputDecoration(
              labelText: label is String && label.isNotEmpty ? label : id,
            ),
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return HostUnavailableView(
        contribution: widget.contribution,
        reason: 'value_missing',
      );
    }
    return Column(
      key: Key('host-form-${widget.contribution.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// The host's command primitive.
///
/// A command is a labelled entry point. It renders only a name; the action it
/// invokes stays with the mounted contribution and is dispatched by the
/// application, never by this widget.
class HostCommandView extends StatelessWidget {
  const HostCommandView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) {
    final label = contribution.inputs['label'];
    if (label is! String || label.isEmpty) {
      return HostUnavailableView(
        contribution: contribution,
        reason: 'value_missing',
      );
    }
    return Padding(
      key: Key('host-command-${contribution.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

/// The host's action primitive.
///
/// The action primitive renders the host-owned outcome of an action the plan
/// bound. It shows a label and dispatches nothing itself: dispatch belongs to
/// the mounted contribution's session, so a renderer can never invoke an
/// unregistered action.
class HostActionView extends StatelessWidget {
  const HostActionView({super.key, required this.contribution});

  final MountedContribution contribution;

  @override
  Widget build(BuildContext context) {
    final label = contribution.inputs['label'];
    final actionRef = contribution.actionRef;
    if (label is! String || label.isEmpty || actionRef == null) {
      return HostUnavailableView(
        contribution: contribution,
        reason: 'value_missing',
      );
    }
    return Semantics(
      label: '$label ($actionRef)',
      child: Padding(
        key: Key('host-action-${contribution.id}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }
}
