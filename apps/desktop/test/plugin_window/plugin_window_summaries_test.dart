import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/chrome_feature_apps.dart';
import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/projections/plugin_window/plugin_window_presentation_source.dart';

import 'support/plugin_window_fixture.dart';

void main() {
  late FakePluginWindowHostPort port;
  late PluginWindowPresentationSource source;
  late PluginWindowSummaries summaries;

  setUp(() {
    port = FakePluginWindowHostPort();
    source = PluginWindowPresentationSource(port: port);
    summaries = PluginWindowSummaries(projection: source);
  });

  tearDown(() async {
    await source.dispose();
    await port.close();
  });

  Future<void> install() async {
    port.publish([
      pluginManifest('sketch.board'),
      pluginManifest(
        'focus.timer',
        name: 'Focus Timer',
        publisher: PluginPublisher.thirdParty,
      ),
    ]);
    await pumpEventQueue();
  }

  test(
    'maps installed plugins in catalog order with their open state',
    () async {
      expect(summaries.value, isEmpty);
      await install();

      source.send(const OpenPluginWindow('focus.timer'));
      await pumpEventQueue();

      expect(summaries.value, const [
        LayoutPluginWindowSummary(
          id: 'sketch.board',
          name: 'Sketch Board',
          official: true,
          open: false,
        ),
        LayoutPluginWindowSummary(
          id: 'focus.timer',
          name: 'Focus Timer',
          official: false,
          open: true,
        ),
      ]);
    },
  );

  test('keeps the same list while nothing a summary shows changed', () async {
    await install();
    source.send(const OpenPluginWindow('sketch.board'));
    await pumpEventQueue();
    final before = summaries.value;

    port.sessions['sketch.board']!.emit(PluginWindowLoading(progress: 0.5));
    await pumpEventQueue();

    expect(summaries.value, same(before));
    expect(() => summaries.value.add(before.first), throwsUnsupportedError);
  });

  test('listeners follow the projection until removed', () async {
    var calls = 0;
    void listener() => calls += 1;
    summaries.addListener(listener);
    summaries.addListener(listener);

    await install();
    expect(calls, 1);

    summaries.removeListener(listener);
    source.send(const OpenPluginWindow('sketch.board'));
    await pumpEventQueue();
    expect(calls, 1);
    expect(summaries.value.first.open, isTrue);
  });
}
