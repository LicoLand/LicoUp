import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
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
            pixel.$3 - pixel.$1 > 25 && pixel.$3 - pixel.$2 > 60,
            isFalse,
            reason: 'No purple usage at zero-day plot pixel ($x, $y).',
          );
        }
      }
      // The isolated positive day remains visible with its actual height.
      expect(_pixel(withUnusedSeries, 644, 35), (140, 72, 255, 255));
      expect(
        timeline.snapshots.map((point) => point.values['GitHub Copilot']),
        upper,
      );
    });

    test(
      'stacked and single-day data fills are opaque in $brightness',
      () async {
        final stacked = await _render(_timeline(const [20, 20]), colors);
        final single = await _render(_timeline(const [20]), colors);
        for (final raster in [stacked, single]) {
          expect(_pixel(raster, 394, 35), (140, 72, 255, 255));
          expect(_pixel(raster, 394, 150), (16, 163, 127, 255));
        }
      },
    );
  }

  test('an entirely empty timeline paints no data', () async {
    final colors = buildLicoTheme().extension<LicoThemeColors>()!;
    final raster = await _render(_timeline(const [0, 0], base: 0), colors);
    expect(raster.every((channel) => channel == 0), isTrue);
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
