import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The route-selection policy a reader may inspect, approve or revoke.
///
/// Three facts stay apart on this surface and are never collapsed into one
/// control: what was *suggested*, what is *adopted*, and what actually
/// *executes*. A suggestion is shown with its evaluating Agent, its rationale
/// and the limits of its evidence before any approve control appears, so a
/// reader never approves a change whose basis they cannot see.
///
/// Every action is dispatched to the bound [SelectionPolicyActions]. When the
/// host composes no policy owner the actions refuse with an explicit reason
/// instead of reporting a change that did not happen, and the surface renders
/// that reason verbatim.
final class SelectionPolicySection extends StatefulWidget {
  const SelectionPolicySection({
    super.key,
    required this.view,
    required this.actions,
  });

  final SelectionPolicyView view;

  final SelectionPolicyActions actions;

  @override
  State<SelectionPolicySection> createState() => _SelectionPolicySectionState();
}

final class _SelectionPolicySectionState extends State<SelectionPolicySection> {
  /// The last refusal the durable owner reported, or `null` when the last
  /// action was accepted or none was taken.
  String? _refusalCode;

  /// Whether a dismissal was accepted. A dismissal is not a refusal and is
  /// reported separately, because the policy deliberately stays in force.
  bool _dismissed = false;

  bool _busy = false;

  /// A read in progress owns the surface: no action is offered against a
  /// revision the reader has not seen yet.
  bool get _locked => _busy || widget.view.phase == PresentationPhase.loading;

  Future<void> _run(Future<SelectionPolicyOutcome> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _refusalCode = null;
      _dismissed = false;
    });
    final outcome = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _refusalCode = outcome.accepted ? null : outcome.reasonCode;
    });
  }

  Future<void> _dismiss(String suggestionId) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _refusalCode = null;
      _dismissed = false;
    });
    final outcome = await widget.actions.dismiss(suggestionId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _refusalCode = outcome.accepted ? null : outcome.reasonCode;
      _dismissed = outcome.accepted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final theme = Theme.of(context);
    final view = widget.view;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            strings.selectionPolicyTitle,
            key: const Key('selection-policy-title'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _FactLine(
            label: strings.selectionPolicyRevisionInForce,
            value: view.hasAdoptedPolicy
                ? view.revisionInForce
                : strings.selectionPolicyUnadopted,
            valueKey: const Key('selection-policy-revision'),
          ),
          // A revoke is offered only for a revision the reader has actually
          // seen: while a read is in progress the revision on screen may
          // already be stale, so the control is not offered against it.
          if (view.hasAdoptedPolicy && view.phase != PresentationPhase.loading)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('selection-policy-revoke'),
                onPressed: _busy
                    ? null
                    : () =>
                          _run(() => widget.actions.revoke(view.revisionInForce)),
                child: Text(strings.selectionPolicyRevoke),
              ),
            ),
          if (_refusalCode != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _refusalCode == selectionPolicyOwnerAbsentCode
                    ? strings.selectionPolicyOwnerAbsent
                    : strings.selectionPolicyRefused(_refusalCode!),
                key: const Key('selection-policy-refusal'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_dismissed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                strings.selectionPolicyKeptCurrent,
                key: const Key('selection-policy-kept'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          Text(
            strings.selectionPolicySuggestions,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          if (view.phase == PresentationPhase.loading)
            Text(
              strings.selectionFactsLoading,
              key: const Key('selection-policy-loading'),
            )
          else if (view.notice != null && view.phase == PresentationPhase.failed)
            Text(
              view.notice!.reasonCode.trim().isEmpty
                  ? view.notice!.message
                  : '${view.notice!.message} (${view.notice!.reasonCode})',
              key: const Key('selection-policy-notice'),
            )
          else if (view.suggestions.isEmpty)
            Text(
              strings.selectionPolicyNoSuggestions,
              key: const Key('selection-policy-no-suggestions'),
            )
          else
            for (final suggestion in view.suggestions)
              _SuggestionCard(
                suggestion: suggestion,
                busy: _locked,
                onAdopt: () =>
                    _run(() => widget.actions.adopt(suggestion.suggestionId)),
                onDismiss: () => _dismiss(suggestion.suggestionId),
              ),
        ],
      ),
    );
  }
}

final class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.busy,
    required this.onAdopt,
    required this.onDismiss,
  });

  final SelectionSuggestionView suggestion;
  final bool busy;
  final VoidCallback onAdopt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: context.licoColors.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                suggestion.suggestionId,
                key: Key('selection-suggestion-${suggestion.suggestionId}'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              // The evaluating Agent is shown before any approve control: a
              // proposal without an author is not attributable evidence.
              _FactLine(
                label: strings.selectionPolicyEvaluatorLabel,
                value: suggestion.evaluatorId,
                valueKey: Key(
                  'selection-suggestion-evaluator-${suggestion.suggestionId}',
                ),
              ),
              _FactLine(
                label: strings.selectionPolicyRationaleLabel,
                value: suggestion.rationale,
                valueKey: Key(
                  'selection-suggestion-rationale-${suggestion.suggestionId}',
                ),
              ),
              _FactLine(
                label: strings.selectionPolicyEvidenceLimitsLabel,
                value: suggestion.evidenceLimits,
                valueKey: Key(
                  'selection-suggestion-limits-${suggestion.suggestionId}',
                ),
              ),
              _FactLine(
                label: strings.selectionPolicyEvidenceDigestLabel,
                value: suggestion.evidenceDigest,
                valueKey: Key(
                  'selection-suggestion-digest-${suggestion.suggestionId}',
                ),
              ),
              _FactLine(
                label: strings.selectionPolicyEffectsLabel,
                value: suggestion.proposedEffects.isEmpty
                    ? strings.selectionPolicyNoSuggestions
                    : suggestion.proposedEffects.join(' · '),
                valueKey: Key(
                  'selection-suggestion-effects-${suggestion.suggestionId}',
                ),
              ),
              if (!suggestion.speaksToContext)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.selectionPolicyRoutingOnlyNote,
                    key: Key(
                      'selection-suggestion-routing-only-'
                      '${suggestion.suggestionId}',
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (suggestion.invalidated)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    strings.selectionPolicyInvalidated,
                    key: Key(
                      'selection-suggestion-invalidated-'
                      '${suggestion.suggestionId}',
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  // Approve is offered only for a usable, still-current
                  // evaluation. A rejected, uncertain or missing judgment is
                  // evidence about the sample, never a proposal.
                  if (suggestion.proposesPolicyChange &&
                      !suggestion.invalidated)
                    TextButton(
                      key: Key(
                        'selection-suggestion-adopt-'
                        '${suggestion.suggestionId}',
                      ),
                      onPressed: busy ? null : onAdopt,
                      child: Text(strings.selectionPolicyAdopt),
                    ),
                  TextButton(
                    key: Key(
                      'selection-suggestion-dismiss-'
                      '${suggestion.suggestionId}',
                    ),
                    onPressed: busy ? null : onDismiss,
                    child: Text(strings.selectionPolicyDismiss),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _FactLine extends StatelessWidget {
  const _FactLine({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 112,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
