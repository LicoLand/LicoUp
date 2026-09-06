import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/binding/frame_timing_telemetry.dart';

void main() {
  test('nearest-rank synthetic fixture reports exact percentiles', () {
    final summary = summarizeFrameMicroseconds(const <int>[
      5000,
      1000,
      3000,
      2000,
      4000,
    ]);

    expect(summary.sampleCount, 5);
    expect(summary.p50Microseconds, 3000);
    expect(summary.p95Microseconds, 5000);
    expect(summary.p99Microseconds, 5000);
  });

  test('empty samples are explicitly unavailable to the caller', () {
    expect(
      () => summarizeFrameMicroseconds(const <int>[]),
      throwsArgumentError,
    );
  });

  test('disabled telemetry does not require a Flutter binding', () {
    final telemetry = FrameTimingTelemetry(
      sampleLimit: 1,
      sink: (_) => fail('disabled telemetry must not emit'),
    );

    telemetry.dispose();
    telemetry.dispose();
  });

  testWidgets(
    'enabled telemetry bounds samples, emits once, and detaches callback',
    (tester) async {
      final summaries = <FrameTimingSummary>[];
      final telemetry = FrameTimingTelemetry(
        sampleLimit: 2,
        sink: summaries.add,
        enabled: true,
        binding: tester.binding,
      );
      addTearDown(telemetry.dispose);
      final reportTimings = tester.binding.platformDispatcher.onReportTimings!;

      reportTimings(<FrameTiming>[
        _timing(build: 1000, raster: 2000, total: 5000),
        _timing(build: 3000, raster: 1000, total: 7000),
        _timing(build: 9000, raster: 9000, total: 20000),
      ]);

      expect(summaries, hasLength(1));
      expect(summaries.single.build.sampleCount, 2);
      expect(summaries.single.build.p50Microseconds, 1000);
      expect(summaries.single.build.p95Microseconds, 3000);
      expect(summaries.single.raster.p50Microseconds, 1000);
      expect(summaries.single.raster.p95Microseconds, 2000);
      expect(summaries.single.total.p50Microseconds, 5000);
      expect(summaries.single.total.p99Microseconds, 7000);

      reportTimings(<FrameTiming>[
        _timing(build: 4000, raster: 4000, total: 10000),
      ]);
      expect(summaries, hasLength(1));

      telemetry.dispose();
      telemetry.dispose();
    },
  );
}

FrameTiming _timing({
  required int build,
  required int raster,
  required int total,
}) => FrameTiming(
  vsyncStart: 0,
  buildStart: 100,
  buildFinish: 100 + build,
  rasterStart: total - raster,
  rasterFinish: total,
  rasterFinishWallTime: total,
);
