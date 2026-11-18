import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/features/plugin_window/ui/plugin_window_actions.dart';
import 'package:licoup/src/frontend/features/plugin_window/ui/plugin_window_view.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_binding.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/projections/plugin_window/plugin_window_presentation_source.dart';

import 'support/plugin_window_fixture.dart';

const _pluginId = 'sketch.board';

final class _Harness {
  _Harness() : this._(FakePluginWindowHostPort());

  _Harness._(this.port) : source = PluginWindowPresentationSource(port: port) {
    binding = PluginWindowBinding(
      projection: source,
      intents: source,
      effects: source,
    );
  }

  final FakePluginWindowHostPort port;
  final PluginWindowPresentationSource source;
  late final PluginWindowBinding binding;
  final List<PluginWindowContentView> built = [];
  int permissionSettings = 0;
  int closes = 0;

  FakePluginWindowSession get session => port.sessions[_pluginId]!;

  Widget app({bool reducedMotion = false}) => MaterialApp(
    theme: buildLicoTheme(platformBrightness: Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(900, 640),
        disableAnimations: reducedMotion,
      ),
      child: Scaffold(
        body: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: PluginWindowTitleActions(
                binding: binding,
                pluginId: _pluginId,
                onOpenPermissionSettings: () => permissionSettings += 1,
                onClose: () => closes += 1,
              ),
            ),
            Expanded(
              child: PluginWindowView(
                binding: binding,
                pluginId: _pluginId,
                contentBuilder: (context, content) {
                  built.add(content);
                  return ColoredBox(
                    key: const Key('fake-platform-view'),
                    color: Colors.black12,
                    child: Text(content.viewType),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() async {
    await harness.source.dispose();
    await harness.port.close();
  });

  Future<void> install(
    WidgetTester tester, {
    PluginWindowManifest? manifest,
    bool open = true,
    bool reducedMotion = false,
  }) async {
    await tester.pumpWidget(harness.app(reducedMotion: reducedMotion));
    harness.port.publish([manifest ?? pluginManifest(_pluginId)]);
    await tester.pump();
    if (open) harness.source.send(const OpenPluginWindow(_pluginId));
    await _frames(tester);
  }

  LinearProgressIndicator progress(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('plugin-window-progress')),
      );

  group('window states', () {
    testWidgets('loads while the catalog is unknown', (tester) async {
      await tester.pumpWidget(harness.app());
      await tester.pump();

      expect(find.byKey(const Key('plugin-window-loading')), findsOneWidget);
      expect(find.byKey(const Key('plugin-window-sandbox-chip')), findsNothing);
    });

    testWidgets('reports a plugin that is not installed', (tester) async {
      await tester.pumpWidget(harness.app());
      harness.port.publish(const []);
      await _frames(tester);

      expect(
        find.byKey(const Key('plugin-window-not-installed')),
        findsOneWidget,
      );
      expect(find.text('This plugin is not installed'), findsOneWidget);
    });

    testWidgets('an indeterminate load loops, and stays static under '
        'reduced motion', (tester) async {
      await install(tester);
      expect(progress(tester).value, isNull);

      await tester.pumpWidget(harness.app(reducedMotion: true));
      await tester.pump();
      expect(progress(tester).value, 0.3);
    });

    testWidgets('determinate progress follows the adapter', (tester) async {
      await install(tester);

      harness.session.emit(PluginWindowLoading(progress: 0.65));
      await _frames(tester);

      expect(progress(tester).value, 0.65);
    });

    testWidgets('a ready window hosts the adapter view', (tester) async {
      await install(tester);
      final view = PluginWindowContentView(
        viewType: 'licoup/plugin-web-view',
        parameters: const {'partition': 'sketch.board'},
      );

      harness.session.emit(PluginWindowReady(view));
      await _frames(tester);

      expect(find.byKey(const Key('plugin-window-ready')), findsOneWidget);
      expect(find.byKey(const Key('fake-platform-view')), findsOneWidget);
      expect(harness.built.last, same(view));
      expect(find.byKey(const Key('plugin-window-loading')), findsNothing);
    });

    testWidgets('an error shows its code and reloads', (tester) async {
      await install(tester);

      harness.session.emit(PluginWindowError('plugin_window_crashed'));
      await _frames(tester);

      expect(find.byKey(const Key('plugin-window-error')), findsOneWidget);
      expect(find.text('The plugin could not load'), findsOneWidget);
      expect(find.text('Error code plugin_window_crashed'), findsOneWidget);

      await tester.tap(find.byKey(const Key('plugin-window-error-reload')));
      await tester.pump();
      expect(harness.session.reloads, 1);
    });

    testWidgets('offline offers a reload', (tester) async {
      await install(tester);

      harness.session.emit(const PluginWindowOffline());
      await _frames(tester);

      expect(find.byKey(const Key('plugin-window-offline')), findsOneWidget);
      await tester.tap(find.byKey(const Key('plugin-window-offline-reload')));
      await tester.pump();
      expect(harness.session.reloads, 1);
    });

    testWidgets('an unsupported platform says so', (tester) async {
      await install(tester);

      harness.session.emit(const PluginWindowUnsupported());
      await _frames(tester);

      expect(
        find.byKey(const Key('plugin-window-unsupported')),
        findsOneWidget,
      );
      expect(
        find.text('Plugin windows are not supported on this device yet'),
        findsOneWidget,
      );
    });
  });

  group('permission sheet', () {
    for (final (key, decision) in const [
      ('plugin-window-permission-deny', PluginPermissionDecision.deny),
      ('plugin-window-permission-once', PluginPermissionDecision.allowOnce),
      ('plugin-window-permission-always', PluginPermissionDecision.allowAlways),
    ]) {
      testWidgets('$key sends ${decision.name}', (tester) async {
        await install(tester);
        harness.session.emit(
          PluginWindowPermissionRequest(
            capability: 'notes.read',
            detail: 'Show your recent notes on the board',
          ),
        );
        await _frames(tester);

        expect(
          find.byKey(const Key('plugin-window-permission-sheet')),
          findsOneWidget,
        );
        expect(
          find.text('“Sketch Board” asks to use notes.read'),
          findsOneWidget,
        );
        expect(
          find.text('Show your recent notes on the board'),
          findsOneWidget,
        );

        await tester.tap(find.byKey(Key(key)));
        await tester.pump();

        expect(harness.session.decisions, [decision]);
      });
    }

    testWidgets('clipboard requests are named in plain words', (tester) async {
      await install(
        tester,
        manifest: pluginManifest(
          _pluginId,
          clipboard: PluginClipboardAccess.ask,
        ),
      );
      harness.session.emit(
        PluginWindowPermissionRequest(capability: pluginClipboardCapability),
      );
      await _frames(tester);

      expect(
        find.text('“Sketch Board” asks to use the clipboard'),
        findsOneWidget,
      );
    });
  });

  group('title actions', () {
    testWidgets('the sandbox chip lists the declared permissions', (
      tester,
    ) async {
      await install(
        tester,
        manifest: pluginManifest(
          _pluginId,
          network: const ['https://api.sketch.example'],
          clipboard: PluginClipboardAccess.ask,
          capabilities: const ['notes.read', 'agents.list'],
        ),
      );

      await tester.tap(find.byKey(const Key('plugin-window-sandbox-chip')));
      await _frames(tester);

      expect(
        find.byKey(const Key('plugin-window-sandbox-permissions')),
        findsOneWidget,
      );
      expect(find.text('Sketch Board · Sandbox permissions'), findsOneWidget);
      expect(find.text('Allows api.sketch.example'), findsOneWidget);
      expect(find.text('Ask every time'), findsOneWidget);
      expect(find.text('notes.read, agents.list'), findsOneWidget);
      // Local files are never granted.
      expect(find.text('None'), findsOneWidget);
    });

    testWidgets('reload reaches the session', (tester) async {
      await install(tester);

      await tester.tap(find.byKey(const Key('plugin-window-reload')));
      await tester.pump();

      expect(harness.session.reloads, 1);
    });

    testWidgets('the window menu opens permission settings and closes', (
      tester,
    ) async {
      await install(tester);

      await tester.tap(find.byKey(const Key('plugin-window-menu')));
      await _frames(tester);
      expect(find.byKey(const Key('plugin-window-menu-card')), findsOneWidget);
      await tester.tap(find.text('Permission settings'));
      await _frames(tester);
      expect(harness.permissionSettings, 1);

      await tester.tap(find.byKey(const Key('plugin-window-menu')));
      await _frames(tester);
      await tester.tap(find.text('Close window'));
      await _frames(tester);
      expect(harness.closes, 1);
      expect(find.byKey(const Key('plugin-window-menu-card')), findsNothing);
    });
  });
}
