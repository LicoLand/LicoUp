import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'agent_usage_formatters.dart';
import 'agent_usage_hover_card.dart';
import 'agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Flutter owns pointer dismissal and touch-long-press timing;
/// the tooltip hosts the same glass card used by the daily wave chart.
class AgentUsageSourceHover extends StatelessWidget {
  const AgentUsageSourceHover({
    super.key,
    required this.source,
    required this.child,
  });

  final AgentUsageModelSource source;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    tooltip:
        '${source.label}, ${formatAgentUsageTooltipNumber(source.usage.totalTokens)} Tokens',
    child: Tooltip(
      excludeFromSemantics: true,
      waitDuration: LicoMotion.tooltipWait,
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(),
      richMessage: WidgetSpan(
        alignment: PlaceholderAlignment.top,
        child: SizedBox(
          width: math.min(
            340.0,
            math.max(0.0, MediaQuery.sizeOf(context).width - 16),
          ),
          child: AgentUsageSourceTooltip(source: source),
        ),
      ),
      child: child,
    ),
  );
}

class AgentUsageSourceTooltip extends AgentUsageHoverCard {
  const AgentUsageSourceTooltip({super.key, required this.source});

  final AgentUsageModelSource source;

  @override
  String get tooltipKeyPrefix => 'usage-source-hover-card-${source.agentId}';

  @override
  String headerLabel(BuildContext context) => source.label;

  /// This is the complete source total, including usage without effort data.
  /// Filtering presentation rows must never change the reported total.
  @override
  num get totalTokens => source.usage.totalTokens;

  @override
  List<AgentUsageHoverRow> buildRows(BuildContext context) {
    final color = agentUsageSeriesColor(context.licoColors, source.label);
    return [
      for (final variant in source.usage.variants.values)
        if (variant.label.isNotEmpty && variant.totalTokens > 0)
          AgentUsageHoverRow(
            label: variant.label,
            totalTokens: variant.totalTokens,
            color: color,
          ),
    ];
  }

  @override
  String? footerLabel(BuildContext context) =>
      source.usage.tokenUnavailableRequests > 0
      ? LicoStrings.of(
          context,
        ).agentUsageIncludedRequests(source.usage.tokenUnavailableRequests)
      : null;
}
