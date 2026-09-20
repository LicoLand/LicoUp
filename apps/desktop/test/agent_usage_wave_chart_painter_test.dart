import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_chart_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_wave_chart_painter.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in Brightness.values) {
    final colors = buildLicoTheme(
      presetId: brightness == Brightness.light
          ? AppearancePresetIds.licoSodaLight
          : AppearancePresetIds.licoSoda,
      platformBrightness: brightness,
    ).extension<LicoThemeColors>()!;

    test('zero usage leaves no colored outline in $brightness', () async {
      const upper = [20.0, 0.0, 20.0, 0.0, 0.0, 0.0, 20.0, 0.0];
      final timeline = _timeline(upper);
      final upperColor = _rgba(agentUsageSeriesColor(colors, 'GitHub Copilot'));
      final withoutUnusedSeries = await _render(timeline, colors);
      final withUnusedSeries = await _render(
        _timeline(upper, includeUnusedSeries: true),
        colors,
      );
      expect(withUnusedSeries, orderedEquals(withoutUnusedSeries));

      // The x positions are 44, 144, ..., 744. Test the isolated zero
      // between positive days, the long zero interval, and the final zero.
      for (final x in [144, 344, 394, 444, 494, 544, 744]) {
        for (var y = 8; y < 208; y += 1) {
          final pixel = _pixel(withUnusedSeries, x, y);
          expect(
            (pixel.$1 - upperColor.$1).abs() <= 1 &&
                (pixel.$2 - upperColor.$2).abs() <= 1 &&
                (pixel.$3 - upperColor.$3).abs() <= 1,
            isFalse,
            reason: 'No purple usage at zero-day plot pixel ($x, $y).',
          );
        }
      }
      // The isolated positive day remains visible with its actual height,
      // now rendered as the translucent gradient fill in the series hue. The
      // lower-usage series hugs the baseline in the ascending stack order.
      final positivePixel = _pixel(withUnusedSeries, 644, 190);
      expect((positivePixel.$1 - upperColor.$1).abs(), lessThanOrEqualTo(6));
      expect((positivePixel.$2 - upperColor.$2).abs(), lessThanOrEqualTo(6));
      expect((positivePixel.$3 - upperColor.$3).abs(), lessThanOrEqualTo(6));
      expect(positivePixel.$4, greaterThan(10));
      expect(
        timeline.snapshots.map((point) => point.values['GitHub Copilot']),
        upper,
      );
    });

    test(
      'stacked and single-day data fills are translucent with a solid top edge in $brightness',
      () async {
        final stacked = await _render(_timeline(const [20, 20]), colors);
        final single = await _render(_timeline(const [20]), colors);
        for (final raster in [stacked, single]) {
          // Interiors carry the series hue at a translucent alpha. Ascending
          // stack order: the lower-usage Copilot band hugs the baseline and
          // Codex closes the top.
          for (final (x, y, label) in [
            (394, 35, 'Codex'),
            (394, 150, 'GitHub Copilot'),
          ]) {
            final expected = _rgba(agentUsageSeriesColor(colors, label));
            final pixel = _pixel(raster, x, y);
            expect((pixel.$1 - expected.$1).abs(), lessThanOrEqualTo(6));
            expect((pixel.$2 - expected.$2).abs(), lessThanOrEqualTo(6));
            expect((pixel.$3 - expected.$3).abs(), lessThanOrEqualTo(6));
            expect(pixel.$4, greaterThan(10));
            expect(
              pixel.$4,
              lessThan(140),
              reason: 'interior fills stay translucent at ($x, $y)',
            );
          }
          // The stack's top edge is a crisp line, clearly stronger than any
          // translucent fill (the fill caps at 0.34 alpha) and any grid
          // hairline (0.28 alpha); scan above the baseline row only.
          var strongestEdge = 0;
          for (var y = 8; y < 202; y += 1) {
            final pixel = _pixel(raster, 394, y);
            if (pixel.$4 > strongestEdge) strongestEdge = pixel.$4;
          }
          expect(
            strongestEdge,
            greaterThan(95),
            reason:
                'the band top edge exceeds the gradient fill\'s 0.34-alpha ceiling',
          );
        }
      },
    );
  }

  test('an entirely empty timeline paints no data', () async {
    final colors = buildLicoTheme().extension<LicoThemeColors>()!;
    final raster = await _render(_timeline(const [0, 0], base: 0), colors);
    expect(raster.every((channel) => channel == 0), isTrue);
  });

  testWidgets('native model names keep plot, legend and hover colors aligned', (
    tester,
  ) async {
    final theme = buildLicoTheme();
    final colors = theme.extension<LicoThemeColors>()!;
    const modelId = 'moonshotai/kimi-k3';
    final timeline = AgentUsageTimelineData(
      snapshots: [
        AgentUsageSnapshot(
          time: DateTime.utc(2026, 9, 1),
          values: const {modelId: 20},
        ),
      ],
      series: const [AgentUsageSeries(label: modelId)],
      seriesTotals: const {modelId: 20},
      shareSeriesLabels: const [modelId],
      groupTotal: 20,
      hasDailyBreakdown: true,
      grouping: AgentUsageChartGrouping.model,
      displayNames: const {modelId: 'Kimi K3'},
    );
    final expected = agentUsageSeriesColor(
      colors,
      'Kimi K3',
      grouping: AgentUsageChartGrouping.model,
    );
    final raster = await tester.runAsync(() => _render(timeline, colors));
    final plotPixel = _pixel(raster!, 394, 150);
    final expectedChannels = _rgba(expected);
    expect((plotPixel.$1 - expectedChannels.$1).abs(), lessThanOrEqualTo(6));
    expect((plotPixel.$2 - expectedChannels.$2).abs(), lessThanOrEqualTo(6));
    expect((plotPixel.$3 - expectedChannels.$3).abs(), lessThanOrEqualTo(6));
    expect(plotPixel.$4, greaterThan(10));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Column(
            children: [
              AgentUsageChartLegend(timeline: timeline),
              AgentUsageChartTooltip(
                timeline: timeline,
                snapshot: timeline.snapshots.single,
              ),
            ],
          ),
        ),
      ),
    );
    for (final type in [AgentUsageChartLegend, AgentUsageChartTooltip]) {
      final swatches = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(type),
          matching: find.byType(Container),
        ),
      );
      expect(
        swatches.map((widget) => (widget.decoration as BoxDecoration).color),
        [expected],
      );
    }
  });
}

AgentUsageTimelineData _timeline(
  List<double> upper, {
  double base = 40,
  bool includeUnusedSeries = false,
}) {
  final upperTotal = upper.fold(0.0, (sum, value) => sum + value);
  return AgentUsageTimelineData(
    snapshots: [
      for (var index = 0; index < upper.length; index += 1)
        AgentUsageSnapshot(
          time: DateTime.utc(2026, 9, index + 1),
          values: {'Codex': base, 'GitHub Copilot': upper[index]},
        ),
    ],
    series: [
      const AgentUsageSeries(label: 'Codex'),
      const AgentUsageSeries(label: 'GitHub Copilot'),
      if (includeUnusedSeries) const AgentUsageSeries(label: 'Kilo Code'),
    ],
    seriesTotals: {'Codex': base * upper.length, 'GitHub Copilot': upperTotal},
    shareSeriesLabels: const ['Codex', 'GitHub Copilot'],
    groupTotal: base * upper.length + upperTotal,
    hasDailyBreakdown: true,
  );
}

Future<Uint8List> _render(
  AgentUsageTimelineData timeline,
  LicoThemeColors colors,
) async {
  final recorder = ui.PictureRecorder();
  AgentUsageWaveChartPainter(
    timeline: timeline,
    colors: colors,
    hoveredSnapshotIndex: null,
    labelStyle: TextStyle(color: colors.textSecondary, fontSize: 10),
  ).paint(Canvas(recorder), const Size(754, 236));
  final picture = recorder.endRecording();
  final image = await picture.toImage(754, 236);
  final bytes = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

(int, int, int, int) _pixel(Uint8List bytes, int x, int y) {
  final offset = (y * 754 + x) * 4;
  return (
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
    bytes[offset + 3],
  );
}

(int, int, int, int) _rgba(Color color) => (
  (color.r * 255).round(),
  (color.g * 255).round(),
  (color.b * 255).round(),
  (color.a * 255).round(),
);
