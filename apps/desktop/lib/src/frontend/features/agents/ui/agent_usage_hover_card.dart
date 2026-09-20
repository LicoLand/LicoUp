import 'package:flutter/material.dart';

import 'agent_usage_formatters.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared usage detail card. Chart and source hover presentations supply only
/// their header and rows; material, typography and numeric alignment stay one.
abstract class AgentUsageHoverCard extends StatelessWidget {
  const AgentUsageHoverCard({super.key});

  String get tooltipKeyPrefix;
  String headerLabel(BuildContext context);
  num get totalTokens;
  String semanticLabel(BuildContext context) => headerLabel(context);
  List<AgentUsageHoverRow> buildRows(BuildContext context);
  String? footerLabel(BuildContext context) => null;

  /// Where the reported total belongs. The daily chart tooltip keeps its
  /// header to a single date and totals under a divider; the source card keeps
  /// header and total on one line above its breakdown rows.
  bool get totalBelowDivider => false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = buildRows(context);
    final footer = footerLabel(context);
    final borderRadius = BorderRadius.circular(12);
    final headerStyle = TextStyle(
      color: colors.text,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
    final labelStyle = TextStyle(color: colors.textSecondary, fontSize: 12);
    final amountStyle = TextStyle(
      color: colors.text,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      container: true,
      label: semanticLabel(context),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: colors.isDark ? 0.42 : 0.18,
              ),
              blurRadius: 28,
              spreadRadius: -4,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: AppleGlassSurface(
          key: ValueKey(tooltipKeyPrefix),
          borderRadius: borderRadius,
          blurSigma: 24,
          fillAlpha: colors.isDark ? 12 : 18,
          borderAlpha: colors.isDark ? 54 : 84,
          child: ColoredBox(
            key: ValueKey('$tooltipKeyPrefix-glass-fill'),
            color: colors.surfaceRaised.withValues(
              alpha: colors.isDark ? 0.72 : 0.84,
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    key: ValueKey('$tooltipKeyPrefix-header'),
                    children: [
                      Expanded(
                        child: Text(
                          headerLabel(context),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: headerStyle,
                        ),
                      ),
                      if (!totalBelowDivider) ...[
                        const SizedBox(width: 10),
                        Text(
                          formatAgentUsageTooltipNumber(totalTokens),
                          style: amountStyle,
                        ),
                      ],
                    ],
                  ),
                  if (rows.isNotEmpty) const SizedBox(height: 10),
                  for (final (index, row) in rows.indexed) ...[
                    Row(
                      key: ValueKey('$tooltipKeyPrefix-row-${row.seriesKey}'),
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: row.color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            row.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          formatAgentUsageTooltipNumber(row.totalTokens),
                          style: amountStyle,
                        ),
                      ],
                    ),
                    if (index < rows.length - 1) const SizedBox(height: 6),
                  ],
                  if (totalBelowDivider) ...[
                    const SizedBox(height: 10),
                    const _HairlineDivider(),
                    const SizedBox(height: 10),
                    Row(
                      key: ValueKey('$tooltipKeyPrefix-total'),
                      children: [
                        Expanded(
                          child: Text(
                            LicoStrings.of(context).totalTokens,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          formatAgentUsageTooltipNumber(totalTokens),
                          style: amountStyle,
                        ),
                      ],
                    ),
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      footer,
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HairlineDivider extends StatelessWidget {
  const _HairlineDivider();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: ColoredBox(color: context.licoColors.line),
    );
  }
}

class AgentUsageHoverRow {
  const AgentUsageHoverRow({
    required this.label,
    String? seriesKey,
    required this.totalTokens,
    required this.color,
  }) : seriesKey = seriesKey ?? label;

  final String label;
  final String seriesKey;
  final num totalTokens;
  final Color color;
}
