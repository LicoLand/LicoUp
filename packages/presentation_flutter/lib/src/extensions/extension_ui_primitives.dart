/// Host-compiled primitives a declarative contribution may bind to.
///
/// These widgets are compiled into the shell. A contribution supplies data and
/// names one of them; it never supplies a widget, a callback or a provider.
/// Focus, input-method editing, accessibility, theming and prepared-value
/// consistency belong here, not to the contribution.
///
/// Every primitive receives a mounted [ExtensionUiContributionSession]: it
/// renders the session's prepared value and dispatches the session's typed
/// action. A primitive never reads a source, and it never draws a host trust or
/// permission prompt — those are the host's own layer, above this content.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import '../graph/graph_resource_view.dart';
import 'extension_ui_binding.dart';
import 'extension_ui_contribution.dart';
import 'extension_ui_registry.dart';

/// Host-owned renderer for one prepared graph resource view.
///
/// The contribution names the format; the shell supplies the renderer. The
/// controller behind the session owns observation and preparation, so this
/// widget only renders installed values, forwards typed actions and shows the
/// waiting state until the native receipt arrives.
class GraphContributionPrimitive extends StatelessWidget {
  const GraphContributionPrimitive({super.key, required this.session});

  final ExtensionUiContributionSession session;

  @override
  Widget build(BuildContext context) {
    final controller = session.graph;
    if (controller == null) {
      return ExtensionUnavailablePrimitive(
        session: session,
        reason: session.localUnavailableReason ?? 'binding_unavailable',
      );
    }
    return StreamBuilder<GraphPreparedValue?>(
      stream: controller.displayed,
      initialData: controller.current,
      builder: (context, snapshot) {
        final value = snapshot.data;
        // The graph controller names its own cause (`source_unavailable`,
        // `binding_unavailable`); the contribution session's reason covers the
        // host-side cases.
        final reason =
            controller.localUnavailableReason ?? session.localUnavailableReason;
        return ValueListenableBuilder<Set<String>>(
          valueListenable: session.pendingGraphActions,
          builder: (context, pending, _) => GraphResourceView(
            key: Key('extension-graph-${session.contribution.id}'),
            value: value,
            unavailableReason: value == null ? (reason ?? 'loading') : null,
            pendingActions: pending,
            onAction: session.dispatchGraphAction,
          ),
        );
      },
    );
  }
}

/// Renders one mounted contribution through its compiled primitive.
class ExtensionContributionView extends StatelessWidget {
  const ExtensionContributionView({super.key, required this.session});

  final ExtensionUiContributionSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ExtensionUiResourceValue?>(
      valueListenable: session.displayed,
      builder: (context, value, _) {
        final reason = session.localUnavailableReason;
        if (reason != null && value == null) {
          return ExtensionUnavailablePrimitive(
            session: session,
            reason: reason,
          );
        }
        return switch (session.contribution.kind) {
          ExtensionContributionKind.settings => ExtensionSettingsFormPrimitive(
            session: session,
            value: value,
          ),
          ExtensionContributionKind.command => ExtensionCommandPrimitive(
            session: session,
          ),
          ExtensionContributionKind.navigation => ExtensionNavigationPrimitive(
            session: session,
          ),
          ExtensionContributionKind.metricPanel => ExtensionChartPrimitive(
            session: session,
            value: value,
          ),
          ExtensionContributionKind.resourceView => GraphContributionPrimitive(
            session: session,
          ),
        };
      },
    );
  }
}

/// Host-owned state for a contribution whose primitive or binding is absent.
///
/// The contribution shows its own bounded unavailable state; no other
/// contribution and no other page is affected.
class ExtensionUnavailablePrimitive extends StatelessWidget {
  const ExtensionUnavailablePrimitive({
    super.key,
    required this.session,
    required this.reason,
  });

  final ExtensionUiContributionSession session;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${session.contribution.title}: unavailable ($reason)',
      child: Padding(
        key: Key('extension-unavailable-${session.contribution.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          session.contribution.title,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }
}

/// Host-owned settings form primitive.
///
/// Fields come from the contribution declaration; current values come from the
/// prepared resource value. Typing stays local input state and cannot
/// invalidate a prepared value; only an explicit submit crosses into the
/// application. A `secret-ref` field is collected by this host control and
/// stored as a credential handle, so the contribution never sees the secret.
class ExtensionSettingsFormPrimitive extends StatefulWidget {
  const ExtensionSettingsFormPrimitive({
    super.key,
    required this.session,
    required this.value,
  });

  final ExtensionUiContributionSession session;
  final ExtensionUiResourceValue? value;

  @override
  State<ExtensionSettingsFormPrimitive> createState() =>
      _ExtensionSettingsFormPrimitiveState();
}

class _ExtensionSettingsFormPrimitiveState
    extends State<ExtensionSettingsFormPrimitive> {
  final Map<String, TextEditingController> _textControllers =
      <String, TextEditingController>{};
  final Map<String, bool> _booleans = <String, bool>{};
  final Map<String, String> _selects = <String, String>{};
  final Set<String> _edited = <String>{};
  final Map<String, String> _fieldErrors = <String, String>{};
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _adopt(widget.value);
  }

  @override
  void didUpdateWidget(ExtensionSettingsFormPrimitive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value)) {
      _adopt(widget.value);
    }
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Adopts prepared values for fields the user has not edited.
  ///
  /// A `secret-ref` field is never prefilled: a secret belongs to host custody,
  /// and a resource value must not put one back into a control.
  void _adopt(ExtensionUiResourceValue? value) {
    if (value == null) return;
    for (final field in widget.session.contribution.fields) {
      if (_edited.contains(field.id)) continue;
      final prepared = value.formValues[field.id];
      switch (field.type) {
        case ExtensionFieldType.boolean:
          final current = _booleans[field.id] ?? false;
          final next = prepared == 'true';
          if (current != next) _booleans[field.id] = next;
        case ExtensionFieldType.select:
          if (prepared != null && prepared.isNotEmpty) {
            _selects[field.id] = prepared;
          }
        case ExtensionFieldType.text:
        case ExtensionFieldType.number:
          if (prepared == null || prepared.isEmpty) continue;
          final controller = _textController(field.id);
          if (controller.text != prepared) controller.text = prepared;
        case ExtensionFieldType.secretRef:
          break;
      }
    }
  }

  TextEditingController _textController(String fieldId) =>
      _textControllers.putIfAbsent(fieldId, TextEditingController.new);

  /// Submits the form.
  ///
  /// Secrets are taken into host custody first and only their handles are
  /// dispatched. When the host refuses custody, nothing is dispatched and the
  /// control keeps the typed value so the user can retry. A withdrawal that
  /// lands while the host is storing drops the pending action.
  Future<void> _submit() async {
    final session = widget.session;
    final contribution = session.contribution;
    final errors = <String, String>{};
    final values = <String, String>{};
    final credentialRefs = <String, String>{};
    final secrets = <String, String>{};
    for (final field in contribution.fields) {
      switch (field.type) {
        case ExtensionFieldType.boolean:
          values[field.id] = (_booleans[field.id] ?? false).toString();
        case ExtensionFieldType.select:
          // A select without declared options falls back to the text control,
          // so both shapes are read here.
          final value =
              (_selects[field.id] ?? _textControllers[field.id]?.text ?? '')
                  .trim();
          if (field.isRequired && value.isEmpty) {
            errors[field.id] = 'required';
          } else if (value.isNotEmpty) {
            values[field.id] = value;
          }
        case ExtensionFieldType.text:
        case ExtensionFieldType.number:
          final value = _textController(field.id).text.trim();
          if (field.isRequired && value.isEmpty) {
            errors[field.id] = 'required';
          } else if (value.isNotEmpty) {
            values[field.id] = value;
          }
        case ExtensionFieldType.secretRef:
          final value = _textController(field.id).text;
          if (field.isRequired && value.isEmpty) {
            errors[field.id] = 'required';
            continue;
          }
          if (value.isEmpty) continue;
          if (!session.canStoreCredentials) {
            errors[field.id] = 'credential_unavailable';
            continue;
          }
          secrets[field.id] = value;
      }
    }
    if (errors.isNotEmpty) {
      setState(() {
        _fieldErrors
          ..clear()
          ..addAll(errors);
        _submitError = null;
      });
      return;
    }
    setState(() {
      _fieldErrors.clear();
      _submitError = null;
    });
    for (final entry in secrets.entries) {
      final outcome = await session.storeCredential(
        fieldId: entry.key,
        secret: entry.value,
      );
      if (!mounted) return;
      switch (outcome) {
        case ExtensionUiCredentialStored(:final handle):
          credentialRefs[entry.key] = handle;
        case ExtensionUiCredentialRefused(:final reason):
          if (reason == 'withdrawn') {
            // The epoch is gone; the pending action is dropped with it.
            return;
          }
          setState(() => _submitError = reason);
          return;
      }
    }
    if (!session.isActive) return;
    try {
      await Future<void>.sync(
        () => session.dispatch(values: values, credentialRefs: credentialRefs),
      );
      if (!mounted) return;
      // The secret now lives in host custody; the control does not keep it.
      for (final fieldId in secrets.keys) {
        _textController(fieldId).clear();
      }
    } on Object {
      if (!mounted) return;
      setState(() => _submitError = 'action_failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final contribution = session.contribution;
    final theme = Theme.of(context);
    return Padding(
      key: Key('extension-settings-${contribution.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(contribution.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final field in contribution.fields) _field(context, field),
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _submitError!,
                key: Key('extension-submit-error-${contribution.id}'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            key: Key('extension-submit-${contribution.id}'),
            onPressed: session.hasAction ? _submit : null,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, ExtensionContributionField field) {
    final contribution = widget.session.contribution;
    final key = Key('extension-field-${contribution.id}-${field.id}');
    final error = _fieldErrors[field.id];
    switch (field.type) {
      case ExtensionFieldType.boolean:
        return CheckboxListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(field.label),
          value: _booleans[field.id] ?? false,
          onChanged: widget.session.isActive
              ? (value) => setState(() {
                  _edited.add(field.id);
                  _booleans[field.id] = value ?? false;
                })
              : null,
        );
      case ExtensionFieldType.select:
        final options = _selectOptions(field);
        if (options.isEmpty) {
          return _textField(field, key, error);
        }
        final selected = _selects[field.id];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: field.label,
              errorText: error,
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: key,
                isDense: true,
                isExpanded: true,
                value: options.contains(selected) ? selected : null,
                items: [
                  for (final option in options)
                    DropdownMenuItem<String>(
                      value: option,
                      child: Text(option),
                    ),
                ],
                onChanged: widget.session.isActive
                    ? (value) => setState(() {
                        _edited.add(field.id);
                        if (value != null) _selects[field.id] = value;
                      })
                    : null,
              ),
            ),
          ),
        );
      case ExtensionFieldType.text:
      case ExtensionFieldType.number:
      case ExtensionFieldType.secretRef:
        return _textField(field, key, error);
    }
  }

  List<String> _selectOptions(ExtensionContributionField field) {
    final declared = widget.value?.fieldOptions[field.id] ?? const <String>[];
    if (declared.isNotEmpty) return declared;
    final current = _selects[field.id];
    return current == null || current.isEmpty
        ? const <String>[]
        : <String>[current];
  }

  Widget _textField(ExtensionContributionField field, Key key, String? error) {
    final secret = field.type == ExtensionFieldType.secretRef;
    // A secret field without a host credential port is locally unavailable: the
    // display layer never takes custody of a secret itself.
    final unavailable = secret && !widget.session.canStoreCredentials;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: key,
        controller: _textController(field.id),
        enabled: widget.session.isActive && !unavailable,
        obscureText: secret,
        autocorrect: !secret,
        enableSuggestions: !secret,
        keyboardType: field.type == ExtensionFieldType.number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: field.label,
          errorText: error,
          helperText: unavailable ? 'Credential host unavailable' : null,
          isDense: true,
        ),
        onChanged: (_) {
          if (!_edited.contains(field.id)) {
            setState(() => _edited.add(field.id));
          }
        },
      ),
    );
  }
}

/// Host-owned command primitive: one entry that invokes the contribution's
/// action.
class ExtensionCommandPrimitive extends StatelessWidget {
  const ExtensionCommandPrimitive({super.key, required this.session});

  final ExtensionUiContributionSession session;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          key: Key('extension-command-${session.contribution.id}'),
          onPressed: session.hasAction ? () => session.dispatch() : null,
          child: Text(session.contribution.title),
        ),
      ),
    );
  }
}

/// Host-owned navigation primitive for an optional navigation entry.
///
/// The entry exists only while its epoch and profile requirement hold; a
/// contribution whose profile is not served has no entry and no effect on the
/// local conversation pages.
class ExtensionNavigationPrimitive extends StatelessWidget {
  const ExtensionNavigationPrimitive({super.key, required this.session});

  final ExtensionUiContributionSession session;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('extension-navigation-${session.contribution.id}'),
      dense: true,
      title: Text(session.contribution.title),
      onTap: session.hasAction ? () => session.dispatch() : null,
    );
  }
}

/// Host-owned metric panel primitive.
///
/// A panel draws the standardized series the contribution declared from the
/// prepared resource value. It does not parse a vendor's files, and its bounded
/// layout plus a semantic value summary keep it readable and accessible.
class ExtensionChartPrimitive extends StatelessWidget {
  const ExtensionChartPrimitive({
    super.key,
    required this.session,
    required this.value,
  });

  final ExtensionUiContributionSession session;
  final ExtensionUiResourceValue? value;

  @override
  Widget build(BuildContext context) {
    final contribution = session.contribution;
    final theme = Theme.of(context);
    final samplesByMetric = value?.series ?? const <String, List<double>>{};
    final latest = <String, double>{};
    for (final series in contribution.series) {
      final samples = samplesByMetric[series.metric] ?? const <double>[];
      if (samples.isNotEmpty) latest[series.metric] = samples.last;
    }
    final summary = contribution.series
        .map(
          (series) =>
              '${series.label}: ${latest[series.metric] == null ? 'unknown' : _format(latest[series.metric]!)} ${series.unit}',
        )
        .join(', ');
    return Semantics(
      container: true,
      label: summary,
      child: Padding(
        key: Key('extension-chart-${contribution.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(contribution.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final series in contribution.series)
              _seriesRow(context, series, samplesByMetric[series.metric]),
          ],
        ),
      ),
    );
  }

  Widget _seriesRow(
    BuildContext context,
    ExtensionMetricSeries series,
    List<double>? samples,
  ) {
    final theme = Theme.of(context);
    final values = samples ?? const <double>[];
    final peak = values.fold<double>(
      0,
      (max, value) => value > max ? value : max,
    );
    final label = values.isEmpty
        ? 'unknown'
        : '${_format(values.last)} ${series.unit}';
    return Padding(
      key: Key('extension-series-${session.contribution.id}-${series.metric}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${series.label}: $label', style: theme.textTheme.bodySmall),
          if (values.isNotEmpty) ...[
            const SizedBox(height: 4),
            SizedBox(
              height: 24,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final sample in values)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Container(
                        width: 6,
                        height: peak <= 0 ? 2 : 2 + (sample / peak) * 20,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _format(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}
