import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Floating per-agent quota card shown while hovering a roster avatar. Lists
/// every quota window's used percentage and reset countdown (ticked from
/// `resetsAt`, falling back to the provider's `resetDescription`), the
/// provider identity labels, and — for stale snapshots — the capture age.
class MessagingQuotaUsageCard extends StatefulWidget {
  const MessagingQuotaUsageCard({
    super.key,
    required this.snapshot,
    this.clock,
  });

  final ProviderQuotaSnapshot snapshot;

  /// Clock override for deterministic tests and goldens; defaults to
  /// [DateTime.now].
  final DateTime Function()? clock;

  @override
  State<MessagingQuotaUsageCard> createState() =>
      _MessagingQuotaUsageCardState();
}

class _MessagingQuotaUsageCardState extends State<MessagingQuotaUsageCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final snapshot = widget.snapshot;
    final now = (widget.clock ?? DateTime.now)().toUtc();
    final identity = [
      snapshot.identity.accountLabel,
      snapshot.identity.plan,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return MessagingConversationOverlayGlass(
      borderRadius: BorderRadius.circular(
        MessagingDesktopMetrics.conversationListCardCornerRadius,
      ),
      readabilityVeil: true,
      child: SizedBox(
        width: MessagingDesktopMetrics.conversationListExtent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.quotaUsageCardTitle(
                  quotaProviderDisplayName(snapshot.provider),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (identity.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  identity,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                ),
              ],
              const SizedBox(height: 8),
              for (var index = 0; index < snapshot.windows.length; index++) ...[
                _QuotaWindowRow(window: snapshot.windows[index], now: now),
                if (index < snapshot.windows.length - 1)
                  const SizedBox(height: 8),
              ],
              if (snapshot.isStale) ...[
                const SizedBox(height: 8),
                Text(
                  strings.quotaSnapshotCapturedAgo(
                    formatQuotaDuration(
                      strings,
                      snapshot.captureAge(now: now) ?? Duration.zero,
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QuotaWindowRow extends StatelessWidget {
  const _QuotaWindowRow({required this.window, required this.now});

  final ProviderQuotaWindow window;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final resetsAt = window.resetsAtTime;
    final remaining = resetsAt == null
        ? null
        : resetsAt.difference(now).isNegative
        ? Duration.zero
        : resetsAt.difference(now);
    final resetText = remaining != null
        ? strings.quotaWindowResetCountdown(
            formatQuotaDuration(strings, remaining),
          )
        : window.resetDescription;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                window.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textSecondary, fontSize: 12),
              ),
            ),
            const SizedBox(width: 16),
            Text(
              '${window.usedPercent.round()}%',
              style: TextStyle(
                color: colors.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (resetText.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            resetText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.textMuted, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

/// Brand display names are proper nouns and stay unlocalized; unknown
/// provider ids fall back to the raw wire value so later providers slot in
/// without UI changes.
String quotaProviderDisplayName(String provider) {
  return switch (provider) {
    'codex' => 'Codex',
    'cursor' => 'Cursor',
    'antigravity' => 'Antigravity',
    _ => provider,
  };
}

/// Compact duration for reset countdowns and capture ages.
String formatQuotaDuration(LicoStrings strings, Duration value) {
  final minutes = value.inMinutes;
  if (minutes < 1) return strings.quotaDurationUnderMinute;
  if (minutes < 60) return strings.quotaDurationMinutes(minutes);
  final hours = value.inHours;
  if (hours < 48) {
    return strings.quotaDurationHoursMinutes(hours, minutes - hours * 60);
  }
  final days = value.inDays;
  return strings.quotaDurationDaysHours(days, hours - days * 24);
}
