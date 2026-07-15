part of 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';

const int _usageTimelineDayCount = 30;
const double _usageChartHeight = 178;
const double _usageChartLeftPadding = 44;
const double _usageChartRightPadding = 10;
const double _usageChartTopPadding = 8;
const double _usageChartBottomPadding = 28;

class _UsageCharts extends StatefulWidget {
  const _UsageCharts({required this.report, required this.detectedAgentIds});

  final AgentUsageReport? report;
  final Set<String> detectedAgentIds;

  @override
  State<_UsageCharts> createState() => _UsageChartsState();
}

class _UsageChartsState extends State<_UsageCharts> {
  _UsageChartGrouping _grouping = _UsageChartGrouping.agent;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final report = widget.report;
    if (report == null) {
      return const _UsageEmptyState();
    }
    final agents = [
      for (final agent in report.agents)
        if (_shouldShowUsageAgent(agent, widget.detectedAgentIds)) agent,
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    final totalTokens = agents.fold<int>(
      0,
      (total, agent) => total + agent.totalTokens,
    );
    final timeline = _timelineData(report, _grouping, widget.detectedAgentIds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report.attribution.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _usageTrafficAttributionLabel(report.attribution, strings),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.licoColors.textMuted,
              ),
            ),
          ),
        _UsageWaveOverview(
          grouping: _grouping,
          timeline: timeline,
          onGroupingChanged: (grouping) {
            setState(() {
              _grouping = grouping;
            });
          },
        ),
        const SizedBox(height: 16),
        Builder(
          builder: (context) {
            final colors = context.licoColors;
            final sectionTotal = switch (_grouping) {
              _UsageChartGrouping.agent => totalTokens.toDouble(),
              _UsageChartGrouping.model => timeline.groupTotal,
            };
            final detailRows = switch (_grouping) {
              _UsageChartGrouping.agent => [
                for (final agent in agents.take(8))
                  _UsageBarData(
                    label: _usageAgentDisplayName(agent),
                    value: _number(agent.totalTokens),
                    price: _usagePriceLabel(
                      timeline.priceFor(_usageAgentDisplayName(agent)),
                      strings.priceNotEstimable,
                    ),
                    trailing: _percent(agent.totalTokens, totalTokens),
                    fraction: _usageShareFraction(
                      agent.totalTokens,
                      totalTokens,
                    ),
                    accent: _usageSeriesColor(
                      colors,
                      _usageAgentDisplayName(agent),
                    ),
                  ),
              ],
              _UsageChartGrouping.model => [
                for (final series in timeline.series)
                  _UsageBarData(
                    label: series.label,
                    value: _number(timeline.totalFor(series.label)),
                    price: _usagePriceLabel(
                      timeline.priceFor(series.label),
                      strings.priceNotEstimable,
                    ),
                    trailing: _percent(
                      timeline.totalFor(series.label),
                      timeline.groupTotal,
                    ),
                    fraction: _usageShareFraction(
                      timeline.totalFor(series.label),
                      timeline.groupTotal,
                    ),
                    accent: _usageSeriesColor(colors, series.label),
                  ),
              ],
            };
            final hasDetailRows = detailRows.isNotEmpty;
            return _UsageBarSection(
              key: const ValueKey('agent-usage-token-share'),
              title: strings.tokenUsage,
              valueHeader: strings.tokenConsumption,
              priceHeader: strings.apiPriceEstimate,
              rows: [
                if (hasDetailRows)
                  _UsageBarData(
                    label: strings.totalTokens,
                    value: _number(sectionTotal),
                    price: _usagePriceLabel(
                      _timelineTotalPrice(timeline),
                      strings.priceNotEstimable,
                    ),
                    trailing: '100%',
                    fraction: sectionTotal > 0 ? 1 : 0,
                    accent: colors.primary,
                  ),
                ...detailRows,
              ],
              emptyLabel: switch (_grouping) {
                _UsageChartGrouping.agent => strings.noAgentUsageInLatestReport,
                _UsageChartGrouping.model => strings.noModelUsageInLatestReport,
              },
            );
          },
        ),
        if (report.warnings.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            report.warnings
                .map((warning) => _usageWarningLabel(warning, strings))
                .toSet()
                .join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: context.licoColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  _UsageTimelineData _timelineData(
    AgentUsageReport report,
    _UsageChartGrouping grouping,
    Set<String> detectedAgentIds,
  ) {
    final bucketDates = _recentDayBuckets();
    final bucketKeys = bucketDates.map(_dateKey).toSet();
    final valuesByDay = {for (final key in bucketKeys) key: <String, double>{}};
    final pricesBySeries = <String, _UsagePriceAccumulator>{};
    final modelShareTotals = <String, double>{};

    void addModelShare(
      String model,
      _UsageModelTokens usage, {
      required bool estimated,
    }) {
      final label = _usageModelDisplayName(model);
      _addUsageValue(modelShareTotals, label, usage.totalTokens);
      final price = pricesBySeries.putIfAbsent(
        label,
        _UsagePriceAccumulator.new,
      );
      if (estimated) {
        price.addUnavailable(usage.totalTokens);
      } else {
        price.add(
          tokens: usage.totalTokens,
          estimate: AgentUsageApiPricing.estimate(
            model: model,
            usage: usage.breakdown,
          ),
        );
      }
    }

    var hasDailyBreakdown = false;
    for (final agent in report.agents) {
      if (!_shouldShowUsageAgent(agent, detectedAgentIds)) {
        continue;
      }
      final dailyUsage = agent.history['dailyUsage'];
      hasDailyBreakdown =
          hasDailyBreakdown || dailyUsage is List || dailyUsage is Map;
      final dailyEntries = _dailyUsageEntries(dailyUsage);
      if (dailyEntries.isEmpty) {
        if (grouping == _UsageChartGrouping.model) {
          for (final model in _modelUsageMap(agent.history).entries) {
            addModelShare(model.key, model.value, estimated: false);
          }
        }
        continue;
      }
      for (final entry in dailyEntries) {
        final date = entry.date;
        if (!bucketKeys.contains(date)) {
          continue;
        }
        switch (grouping) {
          case _UsageChartGrouping.agent:
            final label = _usageAgentDisplayName(agent);
            _addUsageValue(valuesByDay[date]!, label, entry.totalTokens);
            final price = pricesBySeries.putIfAbsent(
              label,
              _UsagePriceAccumulator.new,
            );
            if (entry.hasEstimatedRecords || entry.modelUsage.isEmpty) {
              price.addUnavailable(entry.totalTokens);
            } else {
              var attributedTokens = 0.0;
              for (final model in entry.modelUsage.entries) {
                attributedTokens += model.value.totalTokens;
                price.add(
                  tokens: model.value.totalTokens,
                  estimate: AgentUsageApiPricing.estimate(
                    model: model.key,
                    usage: model.value.breakdown,
                  ),
                );
              }
              if ((attributedTokens - entry.totalTokens).abs() > 0.5) {
                price.addUnavailable(
                  (entry.totalTokens - attributedTokens).abs(),
                );
              }
            }
          case _UsageChartGrouping.model:
            for (final model in entry.modelUsage.entries) {
              final label = _usageModelDisplayName(model.key);
              _addUsageValue(
                valuesByDay[date]!,
                label,
                model.value.totalTokens,
              );
              addModelShare(
                model.key,
                model.value,
                estimated: entry.hasEstimatedRecords,
              );
            }
        }
      }
    }

    if (grouping == _UsageChartGrouping.model && modelShareTotals.isEmpty) {
      for (final model in _modelUsageMap(report.summary).entries) {
        addModelShare(model.key, model.value, estimated: false);
      }
    }

    final rawSnapshots = [
      for (final day in bucketDates)
        _UsageSnapshot(
          time: day,
          values: valuesByDay[_dateKey(day)] ?? const {},
        ),
    ];
    final totals = <String, double>{};
    for (final snapshot in rawSnapshots) {
      for (final entry in snapshot.values.entries) {
        totals.update(
          entry.key,
          (value) => value + entry.value,
          ifAbsent: () => entry.value,
        );
      }
    }
    final shareTotals = grouping == _UsageChartGrouping.model
        ? modelShareTotals
        : totals;
    final seriesLabels = shareTotals.entries.toList()
      ..sort((a, b) {
        final byTokens = b.value.compareTo(a.value);
        return byTokens != 0 ? byTokens : a.key.compareTo(b.key);
      });
    final visibleLabels = [
      for (final entry in seriesLabels.take(10)) entry.key,
    ];
    final visibleLabelSet = visibleLabels.toSet();
    final snapshots = [
      for (final snapshot in rawSnapshots)
        _UsageSnapshot(
          time: snapshot.time,
          values: {
            for (final entry in snapshot.values.entries)
              if (visibleLabelSet.contains(entry.key)) entry.key: entry.value,
          },
        ),
    ];
    return _UsageTimelineData(
      snapshots: snapshots,
      series: [for (final label in visibleLabels) _UsageSeries(label: label)],
      seriesTotals: Map.unmodifiable(shareTotals),
      seriesPrices: Map.unmodifiable({
        for (final label in visibleLabels)
          label:
              pricesBySeries[label]?.estimate ??
              const AgentUsageApiPriceEstimate.unavailable(),
      }),
      groupTotal: shareTotals.values.fold<double>(
        0,
        (sum, value) => sum + value,
      ),
      hasDailyBreakdown: hasDailyBreakdown,
    );
  }
}

AgentUsageApiPriceEstimate _timelineTotalPrice(_UsageTimelineData timeline) {
  if (timeline.series.isEmpty) {
    return const AgentUsageApiPriceEstimate.unavailable();
  }
  var totalUsd = 0.0;
  for (final series in timeline.series) {
    final estimate = timeline.priceFor(series.label);
    final usd = estimate.usd;
    if (usd == null) {
      return const AgentUsageApiPriceEstimate.unavailable();
    }
    totalUsd += usd;
  }
  return AgentUsageApiPriceEstimate.available(totalUsd);
}

enum _UsageChartGrouping { agent, model }

class _UsageWaveOverview extends StatefulWidget {
  const _UsageWaveOverview({
    required this.grouping,
    required this.timeline,
    required this.onGroupingChanged,
  });

  final _UsageChartGrouping grouping;
  final _UsageTimelineData timeline;
  final ValueChanged<_UsageChartGrouping> onGroupingChanged;

  @override
  State<_UsageWaveOverview> createState() => _UsageWaveOverviewState();
}

class _UsageWaveOverviewState extends State<_UsageWaveOverview> {
  int? _hoveredSnapshotIndex;
  Offset? _hoverGlobalPosition;
  OverlayEntry? _tooltipOverlay;

  @override
  void didUpdateWidget(covariant _UsageWaveOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.grouping != widget.grouping ||
        oldWidget.timeline != widget.timeline) {
      _clearHover(rebuild: false);
    }
  }

  @override
  void dispose() {
    _removeTooltipOverlay();
    super.dispose();
  }

  void _handleHover(PointerHoverEvent event, Size size) {
    final index = _snapshotIndexAt(event.localPosition, size);
    if (index == null) {
      _clearHover();
      return;
    }
    final indexChanged = _hoveredSnapshotIndex != index;
    _hoverGlobalPosition = event.position;
    if (indexChanged) {
      setState(() {
        _hoveredSnapshotIndex = index;
      });
    }
    _showOrUpdateTooltipOverlay();
  }

  int? _snapshotIndexAt(Offset position, Size size) {
    if (widget.timeline.snapshots.isEmpty) {
      return null;
    }
    final plotRight = size.width - _usageChartRightPadding;
    final plotBottom = size.height - _usageChartBottomPadding;
    if (position.dx < _usageChartLeftPadding ||
        position.dx > plotRight ||
        position.dy < _usageChartTopPadding ||
        position.dy > plotBottom) {
      return null;
    }
    final count = widget.timeline.snapshots.length;
    if (count == 1) {
      return 0;
    }
    final chartWidth = math.max(
      1.0,
      size.width - _usageChartLeftPadding - _usageChartRightPadding,
    );
    return (((position.dx - _usageChartLeftPadding) / chartWidth) * (count - 1))
        .round()
        .clamp(0, count - 1);
  }

  void _showOrUpdateTooltipOverlay() {
    if (_hoveredSnapshotIndex == null || _hoverGlobalPosition == null) {
      return;
    }
    if (_tooltipOverlay == null) {
      final overlay = Overlay.of(context);
      _tooltipOverlay = OverlayEntry(builder: _buildTooltipOverlay);
      overlay.insert(_tooltipOverlay!);
    } else {
      _tooltipOverlay!.markNeedsBuild();
    }
  }

  Widget _buildTooltipOverlay(BuildContext context) {
    final index = _hoveredSnapshotIndex;
    final pointer = _hoverGlobalPosition;
    if (index == null ||
        pointer == null ||
        index < 0 ||
        index >= widget.timeline.snapshots.length) {
      return const SizedBox.shrink();
    }
    final screenSize = MediaQuery.sizeOf(context);
    final tooltipWidth = math.min(
      340.0,
      math.max(240.0, screenSize.width - 16),
    );
    final visibleSeriesCount = widget.timeline.series.where((series) {
      return (widget.timeline.snapshots[index].values[series.label] ?? 0) > 0;
    }).length;
    final estimatedHeight = 58.0 + visibleSeriesCount * 26.0;
    const gap = 12.0;
    const viewportPadding = 8.0;
    var left = pointer.dx + gap;
    if (left + tooltipWidth > screenSize.width - viewportPadding) {
      left = pointer.dx - tooltipWidth - gap;
    }
    left = left
        .clamp(
          viewportPadding,
          math.max(
            viewportPadding,
            screenSize.width - tooltipWidth - viewportPadding,
          ),
        )
        .toDouble();
    var top = pointer.dy + gap;
    if (top + estimatedHeight > screenSize.height - viewportPadding) {
      top = pointer.dy - estimatedHeight - gap;
    }
    top = top
        .clamp(
          viewportPadding,
          math.max(
            viewportPadding,
            screenSize.height - estimatedHeight - viewportPadding,
          ),
        )
        .toDouble();
    return Positioned(
      left: left,
      top: top,
      width: tooltipWidth,
      child: IgnorePointer(
        child: _UsageChartTooltip(
          timeline: widget.timeline,
          snapshot: widget.timeline.snapshots[index],
        ),
      ),
    );
  }

  void _clearHover({bool rebuild = true}) {
    final hadHover = _hoveredSnapshotIndex != null;
    _hoveredSnapshotIndex = null;
    _hoverGlobalPosition = null;
    _removeTooltipOverlay();
    if (rebuild && hadHover && mounted) {
      setState(() {});
    }
  }

  void _removeTooltipOverlay() {
    _tooltipOverlay?.remove();
    _tooltipOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final emptyLabel = !widget.timeline.hasDailyBreakdown
        ? strings.dailyUsageBreakdownUnavailable
        : widget.grouping == _UsageChartGrouping.model
        ? strings.noModelUsageInLatestDailyBreakdown
        : strings.noAgentUsageInLatestDailyBreakdown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      strings.usageOverTime,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    strings.lastDays(_usageTimelineDayCount),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            _UsageGroupingSwitch(
              grouping: widget.grouping,
              onChanged: widget.onGroupingChanged,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (widget.timeline.isEmpty)
          SizedBox(
            height: _usageChartHeight,
            child: Center(
              child: Text(
                emptyLabel,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: _usageChartHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return MouseRegion(
                  key: const ValueKey('usage-wave-chart-interaction'),
                  cursor: SystemMouseCursors.precise,
                  onHover: (event) => _handleHover(event, size),
                  onExit: (_) => _clearHover(),
                  child: CustomPaint(
                    size: size,
                    painter: _UsageWaveChartPainter(
                      timeline: widget.timeline,
                      colors: colors,
                      hoveredSnapshotIndex: _hoveredSnapshotIndex,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _UsageChartLegend(timeline: widget.timeline),
        ],
      ],
    );
  }
}

class _UsageChartTooltip extends StatelessWidget {
  const _UsageChartTooltip({required this.timeline, required this.snapshot});

  final _UsageTimelineData timeline;
  final _UsageSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final visibleSeries = [
      for (final series in timeline.series)
        if ((snapshot.values[series.label] ?? 0) > 0) series,
    ];
    return Semantics(
      container: true,
      label: strings.dailyTokenUsage(_dateKey(snapshot.time)),
      child: Material(
        key: const ValueKey('usage-wave-tooltip'),
        color: colors.surfaceHigh,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _dateKey(snapshot.time),
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    _usageTooltipNumber(snapshot.total),
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              for (final series in visibleSeries) ...[
                Row(
                  key: ValueKey('usage-wave-tooltip-row-${series.label}'),
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _usageSeriesColor(colors, series.label),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        series.label,
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
                      _usageTooltipNumber(snapshot.values[series.label] ?? 0),
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (series != visibleSeries.last) const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageGroupingSwitch extends StatelessWidget {
  const _UsageGroupingSwitch({required this.grouping, required this.onChanged});

  final _UsageChartGrouping grouping;
  final ValueChanged<_UsageChartGrouping> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _UsageGroupingButton(
            label: strings.byAgent,
            selected: grouping == _UsageChartGrouping.agent,
            onPressed: () => onChanged(_UsageChartGrouping.agent),
          ),
          _UsageGroupingButton(
            label: strings.byModel,
            selected: grouping == _UsageChartGrouping.model,
            onPressed: () => onChanged(_UsageChartGrouping.model),
          ),
        ],
      ),
    );
  }
}

class _UsageGroupingButton extends StatelessWidget {
  const _UsageGroupingButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      color: selected ? colors.surfaceHighest : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: selected ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.text : colors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageChartLegend extends StatelessWidget {
  const _UsageChartLegend({required this.timeline});

  final _UsageTimelineData timeline;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (var index = 0; index < timeline.series.length; index += 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: _usageSeriesColor(
                    colors,
                    timeline.series[index].label,
                  ),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  timeline.series[index].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                _number(timeline.totalFor(timeline.series[index].label)),
                style: TextStyle(
                  color: colors.text,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _UsageWaveChartPainter extends CustomPainter {
  const _UsageWaveChartPainter({
    required this.timeline,
    required this.colors,
    required this.hoveredSnapshotIndex,
  });

  final _UsageTimelineData timeline;
  final LicoThemeColors colors;
  final int? hoveredSnapshotIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || timeline.isEmpty) {
      return;
    }
    final chartWidth = math.max(
      1.0,
      size.width - _usageChartLeftPadding - _usageChartRightPadding,
    );
    final chartHeight = math.max(
      1.0,
      size.height - _usageChartTopPadding - _usageChartBottomPadding,
    );
    final baseline = _usageChartTopPadding + chartHeight;
    final maxValue = math.max(1.0, timeline.maxStackTotal);

    final gridPaint = Paint()
      ..color = colors.line.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    final mutedGridPaint = Paint()
      ..color = colors.line.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = baseline - chartHeight * fraction;
      canvas.drawLine(
        Offset(_usageChartLeftPadding, y),
        Offset(size.width - _usageChartRightPadding, y),
        fraction == 1.0 ? gridPaint : mutedGridPaint,
      );
    }

    _paintAxisLabel(
      canvas,
      _compactNumber(maxValue),
      const Offset(0, _usageChartTopPadding - 2),
    );
    _paintAxisLabel(canvas, '0', Offset(0, baseline - 10));

    final xPositions = <double>[];
    final count = timeline.snapshots.length;
    final firstTime = timeline.snapshots.first.time;
    final lastTime = timeline.snapshots.last.time;
    final timeSpan = lastTime.difference(firstTime).inMilliseconds;
    for (var index = 0; index < count; index += 1) {
      final snapshot = timeline.snapshots[index];
      final x = count == 1 || timeSpan <= 0
          ? _usageChartLeftPadding + chartWidth / 2
          : _usageChartLeftPadding +
                chartWidth *
                    snapshot.time.difference(firstTime).inMilliseconds /
                    timeSpan;
      xPositions.add(x);
    }

    if (count == 1) {
      _paintSingleStack(
        canvas,
        xPositions.single,
        baseline,
        chartHeight,
        maxValue,
      );
    } else {
      final cumulative = List<double>.filled(count, 0);
      for (
        var seriesIndex = 0;
        seriesIndex < timeline.series.length;
        seriesIndex += 1
      ) {
        final series = timeline.series[seriesIndex];
        final bottomValues = List<double>.from(cumulative);
        for (var pointIndex = 0; pointIndex < count; pointIndex += 1) {
          cumulative[pointIndex] +=
              timeline.snapshots[pointIndex].values[series.label] ?? 0;
        }
        final topValues = List<double>.from(cumulative);
        final bottomOffsets = [
          for (var index = 0; index < bottomValues.length; index += 1)
            Offset(
              xPositions[index],
              baseline - chartHeight * (bottomValues[index] / maxValue),
            ),
        ];
        final topOffsets = [
          for (var index = 0; index < topValues.length; index += 1)
            Offset(
              xPositions[index],
              baseline - chartHeight * (topValues[index] / maxValue),
            ),
        ];
        _paintSeriesArea(
          canvas,
          topOffsets: topOffsets,
          bottomOffsets: bottomOffsets,
          color: _usageSeriesColor(colors, series.label),
        );
      }
    }

    _paintHoverIndicator(
      canvas,
      xPositions: xPositions,
      baseline: baseline,
      chartHeight: chartHeight,
      maxValue: maxValue,
    );
    _paintXAxisLabels(canvas, size, xPositions, baseline + 8);
  }

  void _paintHoverIndicator(
    Canvas canvas, {
    required List<double> xPositions,
    required double baseline,
    required double chartHeight,
    required double maxValue,
  }) {
    final index = hoveredSnapshotIndex;
    if (index == null || index < 0 || index >= xPositions.length) {
      return;
    }
    final x = xPositions[index];
    final linePaint = Paint()
      ..color = colors.text.withValues(alpha: 0.64)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var y = _usageChartTopPadding; y < baseline; y += 7) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + 3.5, baseline)),
        linePaint,
      );
    }
    final total = timeline.snapshots[index].total;
    final pointY = baseline - chartHeight * (total / maxValue);
    canvas.drawCircle(
      Offset(x, pointY),
      4.2,
      Paint()
        ..color = colors.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(x, pointY),
      3,
      Paint()
        ..color = colors.text
        ..style = PaintingStyle.fill,
    );
  }

  void _paintSingleStack(
    Canvas canvas,
    double x,
    double baseline,
    double chartHeight,
    double maxValue,
  ) {
    var cumulative = 0.0;
    final width = 32.0;
    for (
      var seriesIndex = 0;
      seriesIndex < timeline.series.length;
      seriesIndex += 1
    ) {
      final series = timeline.series[seriesIndex];
      final value = timeline.snapshots.single.values[series.label] ?? 0;
      if (value <= 0) {
        continue;
      }
      final bottom = baseline - chartHeight * (cumulative / maxValue);
      cumulative += value;
      final top = baseline - chartHeight * (cumulative / maxValue);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x - width / 2, top, x + width / 2, bottom),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = _usageSeriesColor(
            colors,
            series.label,
          ).withValues(alpha: 0.72)
          ..style = PaintingStyle.fill,
      );
    }
  }

  void _paintSeriesArea(
    Canvas canvas, {
    required List<Offset> topOffsets,
    required List<Offset> bottomOffsets,
    required Color color,
  }) {
    final areaPath = _smoothPath(topOffsets)
      ..lineTo(bottomOffsets.last.dx, bottomOffsets.last.dy);
    for (var index = bottomOffsets.length - 2; index >= 0; index -= 1) {
      final previous = bottomOffsets[index + 1];
      final current = bottomOffsets[index];
      final controlX = (previous.dx + current.dx) / 2;
      areaPath.cubicTo(
        controlX,
        previous.dy,
        controlX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    areaPath.close();
    final topPath = _smoothPath(topOffsets);
    canvas.drawPath(
      areaPath,
      Paint()
        ..color = color.withValues(alpha: 0.38)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      topPath,
      Paint()
        ..color = color.withValues(alpha: 0.92)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  Path _smoothPath(List<Offset> offsets) {
    final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (var index = 1; index < offsets.length; index += 1) {
      final previous = offsets[index - 1];
      final current = offsets[index];
      final controlX = (previous.dx + current.dx) / 2;
      path.cubicTo(
        controlX,
        previous.dy,
        controlX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    return path;
  }

  void _paintAxisLabel(Canvas canvas, String label, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 40);
    painter.paint(canvas, offset);
  }

  void _paintXAxisLabels(
    Canvas canvas,
    Size size,
    List<double> xPositions,
    double y,
  ) {
    final painted = <Rect>[];
    for (final index in _axisLabelCandidates(xPositions.length)) {
      final label = _timeLabel(timeline.snapshots[index].time);
      final painter = _xAxisLabelPainter(label)..layout(maxWidth: 88);
      final maxLeft = math.max(0.0, size.width - painter.width);
      final left = (xPositions[index] - painter.width / 2)
          .clamp(0.0, maxLeft)
          .toDouble();
      final rect = Rect.fromLTWH(left, y, painter.width, painter.height);
      final collides = painted.any((existing) {
        return existing.inflate(10).overlaps(rect);
      });
      if (collides) {
        continue;
      }
      painter.paint(canvas, rect.topLeft);
      painted.add(rect);
    }
  }

  List<int> _axisLabelCandidates(int count) {
    if (count <= 0) {
      return const [];
    }
    if (count == 1) {
      return const [0];
    }
    final ordered = <int>[];
    void add(int index) {
      var clamped = index;
      if (clamped < 0) {
        clamped = 0;
      }
      if (clamped > count - 1) {
        clamped = count - 1;
      }
      if (!ordered.contains(clamped)) {
        ordered.add(clamped);
      }
    }

    add(0);
    add(count - 1);
    add(((count - 1) * 0.5).round());
    add(((count - 1) * 0.25).round());
    add(((count - 1) * 0.75).round());
    if (count <= 8) {
      for (var index = 0; index < count; index += 1) {
        add(index);
      }
    }
    return ordered;
  }

  TextPainter _xAxisLabelPainter(String label) {
    return TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
  }

  @override
  bool shouldRepaint(covariant _UsageWaveChartPainter oldDelegate) {
    return oldDelegate.timeline != timeline ||
        oldDelegate.colors != colors ||
        oldDelegate.hoveredSnapshotIndex != hoveredSnapshotIndex;
  }
}

class _UsageTimelineData {
  const _UsageTimelineData({
    required this.snapshots,
    required this.series,
    required this.seriesTotals,
    required this.seriesPrices,
    required this.groupTotal,
    required this.hasDailyBreakdown,
  });

  final List<_UsageSnapshot> snapshots;
  final List<_UsageSeries> series;
  final Map<String, double> seriesTotals;
  final Map<String, AgentUsageApiPriceEstimate> seriesPrices;
  final double groupTotal;
  final bool hasDailyBreakdown;

  bool get isEmpty {
    return snapshots.isEmpty ||
        series.isEmpty ||
        snapshots.every((snapshot) => snapshot.total <= 0);
  }

  double get maxStackTotal {
    var maxValue = 0.0;
    for (final snapshot in snapshots) {
      maxValue = math.max(maxValue, snapshot.total);
    }
    return maxValue;
  }

  double totalFor(String label) => seriesTotals[label] ?? 0;

  AgentUsageApiPriceEstimate priceFor(String label) =>
      seriesPrices[label] ?? const AgentUsageApiPriceEstimate.unavailable();
}

class _UsageSnapshot {
  const _UsageSnapshot({required this.time, required this.values});

  final DateTime time;
  final Map<String, double> values;

  double get total {
    var total = 0.0;
    for (final value in values.values) {
      total += value;
    }
    return total;
  }
}

class _UsageSeries {
  const _UsageSeries({required this.label});

  final String label;
}

class _DailyUsageEntry {
  const _DailyUsageEntry({
    required this.date,
    required this.totalTokens,
    required this.modelUsage,
    required this.breakdown,
    required this.hasEstimatedRecords,
  });

  final String date;
  final double totalTokens;
  final Map<String, _UsageModelTokens> modelUsage;
  final AgentUsageTokenBreakdown breakdown;
  final bool hasEstimatedRecords;
}

class _UsageModelTokens {
  const _UsageModelTokens({required this.totalTokens, required this.breakdown});

  final double totalTokens;
  final AgentUsageTokenBreakdown breakdown;

  _UsageModelTokens merge(_UsageModelTokens other) {
    return _UsageModelTokens(
      totalTokens: totalTokens + other.totalTokens,
      breakdown: breakdown.merge(other.breakdown),
    );
  }

  _UsageModelTokens withBreakdown(AgentUsageTokenBreakdown value) {
    return _UsageModelTokens(totalTokens: totalTokens, breakdown: value);
  }
}

class _UsagePriceAccumulator {
  double _usd = 0;
  bool _hasUsage = false;
  bool _isComplete = true;

  void add({
    required double tokens,
    required AgentUsageApiPriceEstimate estimate,
  }) {
    if (tokens <= 0) {
      return;
    }
    _hasUsage = true;
    final usd = estimate.usd;
    if (usd == null) {
      _isComplete = false;
      return;
    }
    _usd += usd;
  }

  void addUnavailable(double tokens) {
    if (tokens <= 0) {
      return;
    }
    _hasUsage = true;
    _isComplete = false;
  }

  AgentUsageApiPriceEstimate get estimate {
    if (!_hasUsage || !_isComplete) {
      return const AgentUsageApiPriceEstimate.unavailable();
    }
    return AgentUsageApiPriceEstimate.available(_usd);
  }
}

bool _shouldShowUsageAgent(
  AgentUsageAgentSummary agent,
  Set<String> detectedAgentIds,
) {
  final agentId = agent.agentId.trim().toLowerCase();
  if (agentId.isEmpty ||
      agentId == 'code' ||
      agentId == 'vscode' ||
      agentId == 'vs-code' ||
      agent.status == 'not-detected') {
    return false;
  }
  if (detectedAgentIds.isEmpty) {
    return agent.totalTokens > 0 || agent.status != 'pending';
  }
  return detectedAgentIds.contains(agent.agentId) || agent.totalTokens > 0;
}

String _usageAgentDisplayName(AgentUsageAgentSummary agent) {
  final agentId = agent.agentId.trim().toLowerCase();
  final known = switch (agentId) {
    'antigravity' => 'Antigravity - IDE',
    'claude' || 'claude-code' => 'Claude Code - CLI',
    'codex' => 'ChatGPT - Desktop',
    'copilot' || 'github-copilot' => 'GitHub Copilot - Plugin',
    'cursor' => 'Cursor - IDE',
    'hermes' || 'hermes-agent' => 'Hermes Agent - CLI',
    'kilo' || 'kilo-code' => 'Kilo Code - CLI',
    'kimi' => 'Kimi - Desktop',
    'kimi-code' => 'Kimi Code - CLI',
    'openclaw' => 'OpenClaw - CLI',
    'opencode' => 'OpenCode - CLI',
    'pi' || 'pi-agent' || 'pi-coding-agent' => 'Pi Agent - CLI',
    _ => null,
  };
  if (known != null) {
    return known;
  }
  final fallback = agent.label.trim().isEmpty
      ? agent.agentId.trim()
      : agent.label.trim();
  return _usageTitleCase(fallback.replaceAll(RegExp(r'[-_]+'), ' '));
}

List<DateTime> _recentDayBuckets({DateTime? anchor}) {
  final today = _dateOnly((anchor ?? DateTime.now()).toLocal());
  return [
    for (var offset = _usageTimelineDayCount - 1; offset >= 0; offset -= 1)
      DateTime(today.year, today.month, today.day - offset),
  ];
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _dateKey(DateTime value) {
  final day = _dateOnly(value);
  return '${day.year}-${_twoDigits(day.month)}-${_twoDigits(day.day)}';
}

void _addUsageValue(Map<String, double> values, String label, num tokens) {
  final normalized = label.trim();
  if (normalized.isEmpty || tokens <= 0) {
    return;
  }
  values.update(
    normalized,
    (value) => value + tokens.toDouble(),
    ifAbsent: () => tokens.toDouble(),
  );
}

List<_DailyUsageEntry> _dailyUsageEntries(Object? source) {
  if (source == null) {
    return const [];
  }
  if (source is List) {
    return [for (final item in source) ..._dailyUsageEntries(item)];
  }
  if (source is Map) {
    final directEntry = _dailyUsageEntryFromMap(source);
    if (directEntry != null) {
      return [directEntry];
    }
    final entries = <_DailyUsageEntry>[];
    for (final entry in source.entries) {
      final date = _usageDateKey(entry.key);
      if (date.isEmpty) {
        continue;
      }
      final parsed = _dailyUsageEntryFromValue(date, entry.value);
      if (parsed != null) {
        entries.add(parsed);
      }
    }
    return entries;
  }
  return const [];
}

_DailyUsageEntry? _dailyUsageEntryFromMap(Map<dynamic, dynamic> source) {
  final date = _usageDateKey(
    source['date'] ??
        source['day'] ??
        source['bucket'] ??
        source['generatedAt'] ??
        source['time'] ??
        source['timestamp'],
  );
  if (date.isEmpty) {
    return null;
  }
  return _dailyUsageEntryFromValue(date, source);
}

_DailyUsageEntry? _dailyUsageEntryFromValue(String date, Object? value) {
  final modelUsage = _modelUsageMap(value);
  var totalTokens = _usageTokens(value);
  if (totalTokens <= 0 && modelUsage.isNotEmpty) {
    totalTokens = modelUsage.values.fold<double>(
      0,
      (sum, item) => sum + item.totalTokens,
    );
  }
  if (totalTokens <= 0 && modelUsage.isEmpty) {
    return null;
  }
  final breakdown = _usageTokenBreakdown(value, totalTokens: totalTokens);
  if (modelUsage.length == 1 && breakdown.isExact) {
    final entry = modelUsage.entries.single;
    if (!entry.value.breakdown.isExact &&
        (entry.value.totalTokens - totalTokens).abs() <= 0.5) {
      modelUsage[entry.key] = entry.value.withBreakdown(breakdown);
    }
  }
  return _DailyUsageEntry(
    date: date,
    totalTokens: totalTokens,
    modelUsage: Map.unmodifiable(modelUsage),
    breakdown: breakdown,
    hasEstimatedRecords:
        value is Map &&
        _usageTokens(value['estimatedRecords'] ?? value['estimated_records']) >
            0,
  );
}

Map<String, _UsageModelTokens> _modelUsageMap(Object? source) {
  final values = <String, _UsageModelTokens>{};
  if (source is List) {
    _mergeModelUsage(values, source);
    return values;
  }
  if (source is Map) {
    for (final key in const ['modelTokenUsage', 'model_token_usage']) {
      _mergeModelUsage(values, source[key]);
    }
    if (values.isNotEmpty) {
      return values;
    }
    for (final key in const [
      'modelUsage',
      'model_usage',
      'models',
      'modelBreakdown',
      'model_breakdown',
      'byModel',
      'by_model',
    ]) {
      _mergeModelUsage(values, source[key]);
    }
    if (_modelName(source).isNotEmpty) {
      _mergeModelUsage(values, source);
    }
    return values;
  }
  _mergeModelUsage(values, source);
  return values;
}

String _usageDateKey(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is DateTime) {
    return _dateKey(value);
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(text);
  if (parsed != null) {
    return _dateKey(parsed);
  }
  final dateMatch = RegExp(r'^\d{4}-\d{2}-\d{2}$').firstMatch(text);
  return dateMatch?.group(0) ?? '';
}

Color _usageSeriesColor(LicoThemeColors colors, String label) {
  final key = _usageColorKey(label);
  if (key.isEmpty) {
    return colors.primaryStrong;
  }
  final known = switch (key) {
    'codex' || 'chatgptdesktop' => const Color(0xFF38BDF8),
    'claude' || 'claudecode' || 'claudecodecli' => const Color(0xFFF59E0B),
    'opencode' || 'opencodecli' => const Color(0xFF22C55E),
    'kilocode' || 'kilocodecli' || 'kilo' => const Color(0xFFA78BFA),
    'antigravity' || 'antigravityide' => const Color(0xFFF472B6),
    'githubcopilot' ||
    'githubcopilotplugin' ||
    'copilot' => const Color(0xFF06B6D4),
    'cursor' || 'cursoride' => const Color(0xFFF97316),
    'kimicodecli' => const Color(0xFF84CC16),
    'kimidesktop' => const Color(0xFF60A5FA),
    'vscode' || 'visualstudiocode' => const Color(0xFF3B82F6),
    _ => null,
  };
  if (known != null) {
    return known;
  }
  const palette = [
    Color(0xFF38BDF8),
    Color(0xFFF59E0B),
    Color(0xFF22C55E),
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFFF97316),
    Color(0xFFEC4899),
    Color(0xFF84CC16),
    Color(0xFF60A5FA),
    Color(0xFFF43F5E),
  ];
  return palette[_stableUsageColorIndex(key, palette.length)];
}

String _usageColorKey(String label) {
  return label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();
}

int _stableUsageColorIndex(String key, int paletteLength) {
  var hash = 0;
  for (final codeUnit in key.codeUnits) {
    hash = 0x1fffffff & (hash + codeUnit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
  hash ^= hash >> 11;
  hash = 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  return hash.abs() % paletteLength;
}

String _timeLabel(DateTime time) {
  return '${time.month}-${time.day}';
}

String _twoDigits(int value) {
  return value.toString().padLeft(2, '0');
}

void _mergeModelUsage(Map<String, _UsageModelTokens> values, Object? source) {
  if (source == null) {
    return;
  }
  if (source is List) {
    for (final item in source) {
      _mergeModelUsage(values, item);
    }
    return;
  }
  if (source is Map) {
    final modelName = _modelName(source);
    if (modelName.isNotEmpty) {
      final tokens = _usageTokens(source);
      if (tokens > 0) {
        final usage = _UsageModelTokens(
          totalTokens: tokens,
          breakdown: _usageTokenBreakdown(source, totalTokens: tokens),
        );
        values.update(
          modelName,
          (value) => value.merge(usage),
          ifAbsent: () => usage,
        );
      }
      return;
    }
    for (final entry in source.entries) {
      final label = _modelLabel(entry.key);
      if (label.isEmpty) {
        continue;
      }
      final tokens = _usageTokens(entry.value);
      if (tokens > 0) {
        final usage = _UsageModelTokens(
          totalTokens: tokens,
          breakdown: _usageTokenBreakdown(entry.value, totalTokens: tokens),
        );
        values.update(
          label,
          (value) => value.merge(usage),
          ifAbsent: () => usage,
        );
      }
    }
  }
}

AgentUsageTokenBreakdown _usageTokenBreakdown(
  Object? source, {
  required double totalTokens,
}) {
  if (source is! Map) {
    return AgentUsageTokenBreakdown.unavailable(totalTokens: totalTokens);
  }
  var candidate = source;
  const promptKeys = [
    'promptTokens',
    'prompt_tokens',
    'inputTokens',
    'input_tokens',
  ];
  const cachedKeys = [
    'cachedInputTokens',
    'cached_input_tokens',
    'cacheReadInputTokens',
    'cache_read_input_tokens',
  ];
  const completionKeys = [
    'completionTokens',
    'completion_tokens',
    'outputTokens',
    'output_tokens',
  ];
  var hasPrompt = _usageMapHasAnyKey(candidate, promptKeys);
  var hasCached = _usageMapHasAnyKey(candidate, cachedKeys);
  var hasCompletion = _usageMapHasAnyKey(candidate, completionKeys);
  if (!hasPrompt && !hasCompletion) {
    for (final key in const [
      'usage',
      'tokenUsage',
      'token_usage',
      'responseUsage',
      'response_usage',
    ]) {
      final nested = candidate[key];
      if (nested is! Map) {
        continue;
      }
      final nestedHasPrompt = _usageMapHasAnyKey(nested, promptKeys);
      final nestedHasCompletion = _usageMapHasAnyKey(nested, completionKeys);
      if (nestedHasPrompt || nestedHasCompletion) {
        candidate = nested;
        hasPrompt = nestedHasPrompt;
        hasCached = _usageMapHasAnyKey(nested, cachedKeys);
        hasCompletion = nestedHasCompletion;
        break;
      }
    }
  }
  final prompt = _firstUsageToken(candidate, promptKeys);
  final cached = _firstUsageToken(candidate, cachedKeys);
  final completion = _firstUsageToken(candidate, completionKeys);
  final componentTotal = prompt + completion;
  final normalizedTotal = totalTokens > 0 ? totalTokens : componentTotal;
  final totalMatches = normalizedTotal <= 0
      ? componentTotal <= 0
      : (componentTotal - normalizedTotal).abs() <= 0.5;
  // Cached input is optional: many agent reports omit the key when there were
  // no cache hits. Treat a missing cache field as zero rather than blocking
  // the whole estimate.
  final exact =
      hasPrompt &&
      hasCompletion &&
      componentTotal > 0 &&
      totalMatches &&
      cached >= 0 &&
      cached <= prompt + 0.5 &&
      (!hasCached || cached >= 0);
  return AgentUsageTokenBreakdown(
    promptTokens: prompt,
    cachedInputTokens: hasCached ? cached : 0,
    completionTokens: completion,
    totalTokens: normalizedTotal,
    isExact: exact,
  );
}

bool _usageMapHasAnyKey(Map<dynamic, dynamic> source, List<String> keys) {
  return keys.any(source.containsKey);
}

double _firstUsageToken(Map<dynamic, dynamic> source, List<String> keys) {
  for (final key in keys) {
    if (!source.containsKey(key)) {
      continue;
    }
    final value = _usageTokens(source[key]);
    if (value >= 0) {
      return value;
    }
  }
  return 0;
}

String _modelName(Map<dynamic, dynamic> source) {
  for (final key in const [
    'model',
    'modelId',
    'model_id',
    'modelName',
    'model_name',
    'name',
    'label',
    'displayName',
    'display_name',
    'title',
    'id',
  ]) {
    final value = _modelLabel(source[key]);
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String _modelLabel(Object? value) {
  if (value == null) {
    return '';
  }
  if (value is Map) {
    final nested = _modelName(value);
    if (nested.isNotEmpty) {
      return nested;
    }
    return '';
  }
  if (value is List) {
    for (final item in value) {
      final nested = _modelLabel(item);
      if (nested.isNotEmpty) {
        return nested;
      }
    }
    return '';
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return '';
  }
  final parsed = _jsonObjectFromText(text);
  if (parsed != null) {
    final nested = _modelName(parsed);
    if (nested.isNotEmpty) {
      return nested;
    }
  }
  return _usageModelDisplayName(_plainModelName(text));
}

Map<dynamic, dynamic>? _jsonObjectFromText(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return null;
  }
  try {
    final parsed = jsonDecode(trimmed);
    return parsed is Map ? parsed : null;
  } catch (_) {
    return null;
  }
}

String _plainModelName(String value) {
  var text = value.trim();
  while (text.startsWith('~')) {
    text = text.substring(1).trimLeft();
  }
  if (text.contains('/')) {
    final parts = text.split('/');
    final last = parts.last.trim();
    if (last.isNotEmpty) {
      text = last;
    }
  }
  return text;
}

String _usageModelDisplayName(String value) {
  final plain = _plainModelName(value);
  if (plain.isEmpty) {
    return '';
  }
  final lower = plain.toLowerCase();
  final knownName = switch (lower) {
    'cursor-auto' || 'default' => 'Cursor Auto',
    'composer-2.5-fast' || 'composer-2-5-fast' => 'Composer 2.5 Fast',
    'others' => 'Others',
    _ => null,
  };
  if (knownName != null) {
    return knownName;
  }
  final words = plain
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .split(' ');
  return words.map(_usageModelWord).join(' ');
}

String _usageModelWord(String word) {
  final lower = word.toLowerCase();
  final known = switch (lower) {
    'api' => 'API',
    'cli' => 'CLI',
    'glm' => 'GLM',
    'gpt' => 'GPT',
    'ide' => 'IDE',
    'llm' => 'LLM',
    'mcp' => 'MCP',
    'ai' => 'AI',
    'deepseek' => 'DeepSeek',
    'chatgpt' => 'ChatGPT',
    _ => null,
  };
  if (known != null) {
    return known;
  }
  final version = RegExp(
    r'^([vr])([0-9].*)$',
    caseSensitive: false,
  ).firstMatch(word);
  if (version != null) {
    return '${version.group(1)!.toUpperCase()}${version.group(2)}';
  }
  final brandedVersion = RegExp(
    r'^(gpt|glm)([0-9].*)$',
    caseSensitive: false,
  ).firstMatch(word);
  if (brandedVersion != null) {
    return '${brandedVersion.group(1)!.toUpperCase()}${brandedVersion.group(2)}';
  }
  if (RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(word)) {
    return word;
  }
  return _usageTitleCase(word);
}

String _usageTitleCase(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  return '${trimmed[0].toUpperCase()}${trimmed.substring(1).toLowerCase()}';
}

String _usageTooltipNumber(num value) {
  if (value <= 0) {
    return '0';
  }
  return _number(value);
}

double _usageTokens(Object? value) {
  if (value == null) {
    return 0;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is num) {
    return value.toDouble();
  }
  final parsed = double.tryParse(value.toString().replaceAll(',', ''));
  if (parsed != null) {
    return parsed;
  }
  if (value is List) {
    var total = 0.0;
    for (final item in value) {
      total += _usageTokens(item);
    }
    return total;
  }
  if (value is Map) {
    for (final key in const [
      'totalTokens',
      'total_tokens',
      'tokens',
      'tokenCount',
      'token_count',
      'usageTokens',
      'usage_tokens',
    ]) {
      final tokens = _usageTokens(value[key]);
      if (tokens > 0) {
        return tokens;
      }
    }
    final prompt =
        _usageTokens(value['promptTokens']) +
        _usageTokens(value['prompt_tokens']) +
        _usageTokens(value['inputTokens']) +
        _usageTokens(value['input_tokens']);
    final completion =
        _usageTokens(value['completionTokens']) +
        _usageTokens(value['completion_tokens']) +
        _usageTokens(value['outputTokens']) +
        _usageTokens(value['output_tokens']);
    if (prompt + completion > 0) {
      return prompt + completion;
    }
    for (final key in const [
      'usage',
      'tokenUsage',
      'token_usage',
      'responseUsage',
      'response_usage',
    ]) {
      final tokens = _usageTokens(value[key]);
      if (tokens > 0) {
        return tokens;
      }
    }
  }
  return 0;
}

class _UsageEmptyState extends StatelessWidget {
  const _UsageEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        LicoStrings.of(context).noUsageReportYet,
        style: TextStyle(color: colors.textMuted, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _UsageBarSection extends StatelessWidget {
  const _UsageBarSection({
    super.key,
    required this.title,
    required this.rows,
    required this.emptyLabel,
    this.valueHeader,
    this.priceHeader,
  });

  final String title;
  final List<_UsageBarData> rows;
  final String emptyLabel;
  final String? valueHeader;
  final String? priceHeader;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.text,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        if (rows.isNotEmpty && priceHeader != null) ...[
          _UsageBarHeader(
            valueHeader: valueHeader ?? '',
            priceHeader: priceHeader!,
          ),
          const SizedBox(height: 6),
        ],
        if (rows.isEmpty)
          Text(
            emptyLabel,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          )
        else
          for (final row in rows) ...[
            _UsageBarRow(data: row, showPrice: priceHeader != null),
            if (row != rows.last) const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _UsageBarHeader extends StatelessWidget {
  const _UsageBarHeader({required this.valueHeader, required this.priceHeader});

  final String valueHeader;
  final String priceHeader;

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
              const SizedBox(width: 18),
              Text(priceHeader, style: style),
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
            SizedBox(
              width: 118,
              child: Text(
                priceHeader,
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

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({required this.data, required this.showPrice});

  final _UsageBarData data;
  final bool showPrice;

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
    final price = _UsageBarValue(
      value: data.price ?? '',
      color: data.priceAvailable ? colors.text : colors.textMuted,
      width: 118,
      weight: data.priceAvailable ? FontWeight.w800 : FontWeight.w600,
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
          key: ValueKey('usage-progress-${data.label}'),
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
                  if (showPrice) ...[const SizedBox(width: 8), price],
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
            if (showPrice) ...[const SizedBox(width: 10), price],
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

class _UsageBarData {
  const _UsageBarData({
    required this.label,
    required this.value,
    required this.trailing,
    required this.fraction,
    this.price,
    this.accent,
  });

  final String label;
  final String value;
  final String? price;
  final String trailing;
  final double fraction;
  final Color? accent;

  bool get priceAvailable => price?.startsWith(r'$') == true;
}

String _number(num value) {
  if (value <= 0) {
    return '-';
  }
  if (value >= 1000000000000) {
    return '${_trimTrailingZero((value / 1000000000000).toStringAsFixed(1))}T';
  }
  if (value >= 1000000000) {
    return '${_trimTrailingZero((value / 1000000000).toStringAsFixed(1))}G';
  }
  if (value >= 1000000) {
    return '${_trimTrailingZero((value / 1000000).toStringAsFixed(1))}M';
  }
  if (value >= 1000) {
    return '${_trimTrailingZero((value / 1000).toStringAsFixed(1))}K';
  }
  final normalized = value is int || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return _withThousandsSeparators(normalized);
}

String _compactNumber(num value) {
  return _number(value);
}

String _trimTrailingZero(String value) {
  if (value.endsWith('.0')) {
    return value.substring(0, value.length - 2);
  }
  return value;
}

String _withThousandsSeparators(String value) {
  final parts = value.split('.');
  final text = parts.first;
  final buffer = StringBuffer();
  for (var index = 0; index < text.length; index += 1) {
    if (index > 0 && (text.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(text[index]);
  }
  if (parts.length > 1 && parts[1].isNotEmpty) {
    buffer.write('.');
    buffer.write(parts[1]);
  }
  return buffer.toString();
}

String _percent(num value, num total) {
  if (value <= 0 || total <= 0) {
    return '--%';
  }
  return '${((value / total) * 100).clamp(0, 999).round()}%';
}

/// Bar fill width as this row's share of the section total (not max among rows).
double _usageShareFraction(num value, num total) {
  if (value <= 0 || total <= 0) {
    return 0;
  }
  return (value / total).clamp(0.0, 1.0).toDouble();
}

String _usagePriceLabel(
  AgentUsageApiPriceEstimate estimate,
  String unavailableLabel,
) {
  final usd = estimate.usd;
  if (usd == null) {
    return unavailableLabel;
  }
  if (usd >= 1) {
    return '\$${_withThousandsSeparators(usd.toStringAsFixed(2))}';
  }
  if (usd >= 0.01) {
    return '\$${usd.toStringAsFixed(3)}';
  }
  if (usd >= 0.0001) {
    return '\$${usd.toStringAsFixed(4)}';
  }
  return r'<$0.0001';
}

String _usageWarningLabel(String value, LicoStrings strings) {
  return switch (value.trim().toLowerCase()) {
    'codex_local_token_event_scan_failed' =>
      strings.isChinese
          ? 'ChatGPT Token 历史扫描失败'
          : 'ChatGPT token history scan failed',
    'process_network_sample_without_delta' =>
      strings.isChinese ? '网络采样缺少有效增量' : 'Network sample has no usable delta',
    'native_history_scan_failed' =>
      strings.isChinese ? '原生历史扫描失败' : 'Native history scan failed',
    'codex_openai_dashboard_helper_failed' =>
      strings.isChinese
          ? 'ChatGPT API 用量查询失败'
          : 'ChatGPT API usage lookup failed',
    'codex_openai_dashboard_unavailable' =>
      strings.isChinese
          ? 'ChatGPT API 用量暂不可用'
          : 'ChatGPT API usage is unavailable',
    'target_scan_failed' =>
      strings.isChinese ? '智能体检测失败' : 'Agent detection failed',
    _ => strings.isChinese ? '用量统计存在未识别警告' : 'Unrecognized usage warning',
  };
}

String _usageTrafficAttributionLabel(String attribution, LicoStrings strings) {
  switch (attribution.trim()) {
    case 'process-metered':
      return strings.isChinese
          ? '流量：进程实时计量（非历史估算）'
          : 'Traffic: process-metered (live; not historical estimate)';
    case 'history-estimated':
      return strings.isChinese
          ? '流量：历史估算（与进程计量分开标注）'
          : 'Traffic: history-estimated (labeled separately from process meters)';
    case 'mixed':
      return strings.isChinese
          ? '流量：进程计量与历史估算并存'
          : 'Traffic: mixed process-metered and history-estimated';
    case 'unavailable':
      return strings.isChinese ? '流量：不可用' : 'Traffic: unavailable';
    default:
      return strings.isChinese
          ? '流量归属：$attribution'
          : 'Traffic attribution: $attribution';
  }
}
