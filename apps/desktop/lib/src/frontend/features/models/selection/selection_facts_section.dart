import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/projections/model_selection/model_selection_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Why one Agent's route was selected, as the four separate dimensions.
///
/// Support, availability, credential and per-scope execution are rendered as
/// four facts with their own reason codes, never as one readiness badge, so a
/// reader can tell "not supported" from "not observed" from "blocked here".
/// Every reason code is shown verbatim: a reader comparing two hosts needs the
/// code, not a paraphrase.
final class SelectionFactsSection extends StatelessWidget {
  const SelectionFactsSection({super.key, required this.projection});

  final ModelSelectionProjection projection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            strings.selectionFactsTitle,
            key: const Key('selection-facts-title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            strings.selectionFactsCaption(projection.agent),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (projection.phase == PresentationPhase.loading)
            _LoadingRow(label: strings.selectionFactsLoading)
          else if (projection.notice != null &&
              projection.phase == PresentationPhase.failed)
            _NoticeRow(notice: projection.notice!)
          else if (projection.entries.isEmpty)
            Text(
              strings.selectionFactsEmpty,
              key: const Key('selection-facts-empty'),
            )
          else
            for (final entry in projection.entries)
              _SelectionEntryTile(entry: entry),
        ],
      ),
    );
  }
}

final class _SelectionEntryTile extends StatelessWidget {
  const _SelectionEntryTile({required this.entry});

  final ModelSelectionViewItem entry;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
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
                entry.displayName,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              _FactRow(label: strings.selectionSupport, value: entry.supportLabel, reason: entry.supportReason),
              _FactRow(
                label: strings.selectionAvailability,
                value: entry.availabilityLabel,
                reason: entry.availabilityReason,
              ),
              _FactRow(
                label: strings.selectionCredentials,
                value: entry.credentialLabel,
                reason: entry.credentialReason,
              ),
              for (final outcome in entry.outcomes)
                _FactRow(
                  label: outcome.scopeLabel,
                  value: outcome.label,
                  reason: outcome.reason,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value, required this.reason});

  final String label;
  final String value;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              reason.trim().isEmpty ? value : '$value · $reason',
              key: Key('selection-fact-$label'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

final class _LoadingRow extends StatelessWidget {
  const _LoadingRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(label, key: const Key('selection-facts-loading')),
  );
}

final class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice});

  final PresentationNotice notice;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      notice.reasonCode.trim().isEmpty
          ? notice.message
          : '${notice.message} (${notice.reasonCode})',
      key: const Key('selection-facts-notice'),
    ),
  );
}
