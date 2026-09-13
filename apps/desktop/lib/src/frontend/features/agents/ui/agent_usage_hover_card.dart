import 'package:flutter/material.dart';

import 'agent_usage_formatters.dart';
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

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final rows = buildRows(context);
    final footer = footerLabel(context);
    final borderRadius = BorderRadius.circular(14);
    final neutralGlassTint = colors.isDark
        ? const Color(0xFF17191C)
        : const Color(0xFFE5E7EB);
    final headerStyle = TextStyle(
      color: colors.text,
      fontSize: 13,
      fontWeight: FontWeight.w800,
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
            color: neutralGlassTint.withValues(
              alpha: colors.isDark ? 0.72 : 0.84,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
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
                      const SizedBox(width: 10),
                      Text(
                        formatAgentUsageTooltipNumber(totalTokens),
                        style: headerStyle,
                      ),
                    ],
                  ),
                  if (rows.isNotEmpty) const SizedBox(height: 9),
                  for (final (index, row) in rows.indexed) ...[
                    Row(
                      key: ValueKey('$tooltipKeyPrefix-row-${row.seriesKey}'),
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: row.color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            row.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          formatAgentUsageTooltipNumber(row.totalTokens),
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    if (index < rows.length - 1) const SizedBox(height: 6),
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 9),
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
