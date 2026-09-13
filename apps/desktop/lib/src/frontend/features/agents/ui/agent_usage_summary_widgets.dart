import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_globe.dart';

import 'agent_usage_formatters.dart';
import 'agent_usage_timeline_data.dart';
import 'agent_usage_source_hover.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

class AgentUsagePanelHeader extends StatelessWidget {
  const AgentUsagePanelHeader({
    super.key,
    this.title,
    this.trailing = const <Widget>[],
  });

  final String? title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final heading = title?.trim();
    return Row(
      children: [
        if (heading != null && heading.isNotEmpty)
          Expanded(
            child: Text(
              heading,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.text,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          )
        else
          const Spacer(),
        ...trailing,
      ],
    );
  }
}

class AgentUsageLoadingState extends StatelessWidget {
  const AgentUsageLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = (constraints.maxHeight - 72)
            .clamp(64.0, 240.0)
            .clamp(0.0, constraints.maxWidth)
            .toDouble();
        return Center(
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConversationParticleGlobe(diameter: diameter),
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    LicoStrings.of(context).usageLoading,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.licoColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class AgentUsageEmptyState extends StatelessWidget {
  const AgentUsageEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        strings.noUsageReportYet,
        style: TextStyle(color: colors.textMuted, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class AgentUsageBarSection extends StatelessWidget {
  const AgentUsageBarSection({
    super.key,
    this.title,
    required this.rows,
    required this.emptyLabel,
    this.valueHeader,
  });

  final String? title;
  final List<AgentUsageBarData> rows;
  final String emptyLabel;
  final String? valueHeader;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (rows.isNotEmpty && valueHeader != null) ...[
          _UsageBarHeader(valueHeader: valueHeader!),
          const SizedBox(height: 6),
        ],
        if (rows.isEmpty)
          Text(
            emptyLabel,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          )
        else
          for (final row in rows) ...[
            _UsageBarRow(
              key: ValueKey(row.seriesKey),
              data: row,
              reserveDisclosure: rows.any((row) => row.sources.length > 1),
            ),
            if (row != rows.last) const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _UsageBarHeader extends StatelessWidget {
  const _UsageBarHeader({required this.valueHeader});

  final String valueHeader;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: context.licoColors.textMuted,
      fontSize: 10,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(valueHeader, style: style),
              const SizedBox(width: 64),
            ],
          );
        }
        return Row(
          children: [
            const SizedBox(width: 150),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox.shrink()),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: Text(
                valueHeader,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: style,
              ),
            ),
            const SizedBox(width: 10),
            const SizedBox(width: 64),
          ],
        );
      },
    );
  }
}

class _UsageBarRow extends StatefulWidget {
  const _UsageBarRow({
    super.key,
    required this.data,
    required this.reserveDisclosure,
  });

  final AgentUsageBarData data;
  final bool reserveDisclosure;

  @override
  State<_UsageBarRow> createState() => _UsageBarRowState();
}

class _UsageBarRowState extends State<_UsageBarRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final expandable = data.sources.length > 1;
    Widget summary = _UsageBarSummary(data: data);
    if (!expandable) {
      if (widget.reserveDisclosure) {
        summary = Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 0, 6),
          child: summary,
        );
      }
      return data.sources.isEmpty
          ? summary
          : AgentUsageSourceHover(source: data.sources.single, child: summary);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: _expanded,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('usage-model-expand-${data.seriesKey}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    AnimatedRotation(
                      key: ValueKey('usage-model-chevron-${data.seriesKey}'),
                      turns: _expanded ? 0.25 : 0,
                      duration: context.motion(LicoMotion.short),
                      curve: LicoMotion.standard,
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: context.licoColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(child: summary),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: context.motion(LicoMotion.medium),
          curve: LicoMotion.standard,
          alignment: Alignment.topCenter,
          child: _expanded
              ? _UsageModelSources(model: data.seriesKey, sources: data.sources)
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _UsageModelSources extends StatelessWidget {
  const _UsageModelSources({required this.model, required this.sources});

  final String model;
  final List<AgentUsageModelSource> sources;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final total = sources.fold<double>(
      0,
      (sum, source) => sum + source.usage.totalTokens,
    );
    final tokenSources = sources
        .where((source) => source.usage.totalTokens > 0)
        .toList();
    return Padding(
      key: ValueKey('usage-model-sources-$model'),
      padding: const EdgeInsets.fromLTRB(20, 8, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tokenSources.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Row(
                children: [
                  for (final source in tokenSources)
                    Expanded(
                      flex: (source.usage.totalTokens / total * 100000)
                          .round()
                          .clamp(1, 100000),
                      child: AgentUsageSourceHover(
                        key: ValueKey(
                          'usage-source-tooltip-$model-${source.agentId}',
                        ),
                        source: source,
                        child: SizedBox(
                          height: 14,
                          child: ColoredBox(
                            key: ValueKey(
                              'usage-source-segment-$model-${source.agentId}',
                            ),
                            color: agentUsageSeriesColor(colors, source.label),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              for (final source in sources)
                AgentUsageSourceHover(
                  source: source,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: agentUsageSeriesColor(colors, source.label),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        source.label,
                        style: TextStyle(color: colors.textMuted, fontSize: 11),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        source.usage.totalTokens > 0
                            ? '${formatAgentUsageNumber(source.usage.totalTokens)} · ${formatAgentUsagePercent(source.usage.totalTokens, total)}'
                            : LicoStrings.of(
                                context,
                              ).agentUsageIncludedRequests(
                                source.usage.requestCount,
                              ),
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UsageBarSummary extends StatelessWidget {
  const _UsageBarSummary({required this.data});

  final AgentUsageBarData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final fraction = data.fraction.clamp(0.0, 1.0).toDouble();
    final label = Text(
      data.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: colors.textMuted, fontSize: 12),
    );
    final value = _UsageBarValue(
      value: data.value,
      color: colors.text,
      width: 96,
      weight: FontWeight.w800,
    );
    final trailing = _UsageBarValue(
      value: data.trailing,
      color: colors.textMuted,
      width: 64,
      weight: FontWeight.w400,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final progress = KeyedSubtree(
          key: ValueKey('usage-progress-${data.seriesKey}'),
          child: _UsageProgressBar(
            fraction: fraction,
            accent: data.accent ?? colors.primary,
          ),
        );
        if (constraints.maxWidth < 640) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 8),
                  value,
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
              const SizedBox(height: 5),
              FractionallySizedBox(
                widthFactor: 0.72,
                alignment: Alignment.centerLeft,
                child: progress,
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 150, child: label),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: SizedBox(width: double.infinity, child: progress),
                ),
              ),
            ),
            const SizedBox(width: 10),
            value,
            const SizedBox(width: 10),
            trailing,
          ],
        );
      },
    );
  }
}

class _UsageProgressBar extends StatelessWidget {
  const _UsageProgressBar({required this.fraction, required this.accent});

  final double fraction;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillWidth = constraints.maxWidth * fraction;
        return Stack(
          children: [
            Container(
              key: const ValueKey('usage-progress-track'),
              height: 10,
              decoration: BoxDecoration(
                color: colors.surfaceLow,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Container(
              key: const ValueKey('usage-progress-fill'),
              width: fillWidth,
              height: 10,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UsageBarValue extends StatelessWidget {
  const _UsageBarValue({
    required this.value,
    required this.color,
    required this.width,
    required this.weight,
  });

  final String value;
  final Color color;
  final double width;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: TextStyle(color: color, fontSize: 12, fontWeight: weight),
      ),
    );
  }
}

class AgentUsageBarData {
  const AgentUsageBarData({
    required this.label,
    String? seriesKey,
    required this.value,
    required this.trailing,
    required this.fraction,
    this.accent,
    this.sources = const [],
  }) : seriesKey = seriesKey ?? label;

  final String label;
  final String seriesKey;
  final String value;
  final String trailing;
  final double fraction;
  final Color? accent;
  final List<AgentUsageModelSource> sources;
}
