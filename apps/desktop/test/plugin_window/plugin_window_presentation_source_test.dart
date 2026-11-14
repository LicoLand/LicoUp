import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_effect.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/plugin_window/plugin_window_presentation_source.dart';

import 'support/plugin_window_fixture.dart';

Future<void> _drain() async {
  for (var turn = 0; turn < 5; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Harness {
  _Harness() {
    source = PluginWindowPresentationSource(port: port);
    _updates = source.changes.listen(updates.add);
    _effectSubscription = source.effects.listen(effects.add);
  }

  final FakePluginWindowHostPort port = FakePluginWindowHostPort();
  late final PluginWindowPresentationSource source;
  final List<ProjectionUpdate<PluginWindowProjection>> updates = [];
  final List<PluginWindowEffect> effects = [];
  late final StreamSubscription<ProjectionUpdate<PluginWindowProjection>>
  _updates;
  late final StreamSubscription<PluginWindowEffect> _effectSubscription;

  PluginWindowProjection get current => source.current;

  Future<void> install(List<PluginWindowManifest> catalog) async {
    port.publish(catalog);
    await _drain();
  }

  Future<FakePluginWindowSession> open(String pluginId) async {
    source.send(OpenPluginWindow(pluginId));
    await _drain();
    return port.sessions[pluginId]!;
  }

  Future<void> dispose() async {
    await _updates.cancel();
    await _effectSubscription.cancel();
    await source.dispose();
    await port.close();
  }
}

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  group('catalog', () {
    test('stays loading until the host reports its first catalog', () async {
      expect(harness.current.phase, PresentationPhase.loading);
      expect(harness.current.catalog, isEmpty);

      final sketch = pluginManifest('sketch.board');
      await harness.install([sketch]);

      expect(harness.current.phase, PresentationPhase.ready);
      expect(harness.current.catalog.single, same(sketch));
      expect(harness.current.manifest('sketch.board'), same(sketch));
      expect(harness.current.manifest('missing'), isNull);
      expect(harness.updates, hasLength(1));
    });

    test('an empty catalog is ready, not loading', () async {
      await harness.install(const []);

      expect(harness.current.phase, PresentationPhase.ready);
      expect(harness.current.catalog, isEmpty);
    });

    test('a catalog failure is reported as the failed phase', () async {
      harness.port.failCatalog();
      await _drain();

      expect(harness.current.phase, PresentationPhase.failed);
    });

    test(
      'the same catalog instance does not publish a second update',
      () async {
        final catalog = [pluginManifest('sketch.board')];
        await harness.install(catalog);
        await harness.install(catalog);

        expect(harness.updates, hasLength(1));
      },
    );
  });

  group('open', () {
    test(
      'a plugin that is not installed is rejected with a stable code',
      () async {
        await harness.install(const []);
        const trace = TraceContext(traceId: 'trace-open');

        harness.source.send(
          const OpenPluginWindow('sketch.board', trace: trace),
        );
        await _drain();

        expect(harness.port.opens, 0);
        final rejected = harness.effects.single as PluginWindowOpenRejected;
        expect(rejected.pluginId, 'sketch.board');
        expect(rejected.code, pluginWindowNotInstalled);
        expect(rejected.trace, same(trace));
        expect(harness.current.sessions, isEmpty);
      },
    );

    test(
      'an adapter that cannot open the window rejects with failed',
      () async {
        await harness.install([pluginManifest('sketch.board')]);
        harness.port.failOpen = true;

        harness.source.send(const OpenPluginWindow('sketch.board'));
        await _drain();

        final rejected = harness.effects.single as PluginWindowOpenRejected;
        expect(rejected.code, pluginWindowFailed);
        expect(harness.current.sessions, isEmpty);
      },
    );

    test(
      'opens one loading session and keeps an open window as it is',
      () async {
        await harness.install([pluginManifest('sketch.board')]);

        await harness.open('sketch.board');
        harness.source.send(const OpenPluginWindow('sketch.board'));
        await _drain();

        expect(harness.port.opens, 1);
        final session = harness.current.session('sketch.board')!;
        expect(session.status, PluginWindowStatus.loading);
        expect(session.progress, isNull);
        expect(harness.effects, isEmpty);
      },
    );

    test('sessions keep the order in which windows were opened', () async {
      await harness.install([
        pluginManifest('sketch.board'),
        pluginManifest('focus.timer', name: 'Focus Timer'),
      ]);

      await harness.open('focus.timer');
      await harness.open('sketch.board');

      expect(harness.current.sessions.map((session) => session.pluginId), [
        'focus.timer',
        'sketch.board',
      ]);
    });
  });

  group('session states', () {
    late FakePluginWindowSession session;

    setUp(() async {
      await harness.install([pluginManifest('sketch.board')]);
      session = await harness.open('sketch.board');
    });

    PluginWindowSessionProjection projected() =>
        harness.current.session('sketch.board')!;

    test('loading progress is projected', () async {
      session.emit(PluginWindowLoading(progress: 0.4));
      await _drain();

      expect(projected().status, PluginWindowStatus.loading);
      expect(projected().progress, 0.4);
    });

    test('a ready session exposes its platform view', () async {
      final view = PluginWindowContentView(viewType: 'licoup/plugin-web-view');
      session.emit(PluginWindowReady(view));
      await _drain();

      expect(projected().status, PluginWindowStatus.ready);
      expect(projected().content, same(view));
    });

    test('a permission request carries its capability and detail', () async {
      session.emit(
        PluginWindowPermissionRequest(
          capability: 'notes.read',
          detail: 'Show your recent notes on the board',
        ),
      );
      await _drain();

      expect(projected().status, PluginWindowStatus.permissionRequest);
      expect(projected().permissionCapability, 'notes.read');
      expect(
        projected().permissionDetail,
        'Show your recent notes on the board',
      );
    });

    test('errors carry their stable code', () async {
      session.emit(PluginWindowError('plugin_window_crashed'));
      await _drain();

      expect(projected().status, PluginWindowStatus.error);
      expect(projected().errorCode, 'plugin_window_crashed');
    });

    test('a failing state stream becomes the generic failure', () async {
      session.emitError(
        StateError('adapter crashed at /private/tmp/example-path'),
      );
      await _drain();

      expect(projected().status, PluginWindowStatus.error);
      expect(projected().errorCode, pluginWindowFailed);
    });

    test('offline and unsupported are projected', () async {
      session.emit(const PluginWindowOffline());
      await _drain();
      expect(projected().status, PluginWindowStatus.offline);

      session.emit(const PluginWindowUnsupported());
      await _drain();
      expect(projected().status, PluginWindowStatus.unsupported);
    });
  });

  group('message bridge', () {
    late FakePluginWindowSession session;

    setUp(() async {
      await harness.install([
        pluginManifest('sketch.board', capabilities: const ['notes.read']),
      ]);
      session = await harness.open('sketch.board');
    });

    test('an undeclared capability is refused', () async {
      session.request(
        PluginBridgeRequest(requestId: 'r1', capability: 'files.write'),
      );
      await _drain();

      final (id, response) = session.responses.single;
      expect(id, 'r1');
      expect(
        (response as PluginBridgeFailure).code,
        pluginCapabilityUndeclared,
      );
    });

    test('an oversized payload is refused before capability service', () async {
      session.request(
        PluginBridgeRequest(
          requestId: 'r2',
          capability: 'notes.read',
          payload: 'x' * (pluginBridgePayloadLimit + 1),
        ),
      );
      await _drain();

      final (_, response) = session.responses.single;
      expect(
        (response as PluginBridgeFailure).code,
        pluginBridgePayloadTooLarge,
      );
    });

    test(
      'a declared capability is unavailable until LicoUp serves it',
      () async {
        session.request(
          PluginBridgeRequest(
            requestId: 'r3',
            capability: 'notes.read',
            payload: '{"limit":5}',
          ),
        );
        await _drain();

        final (id, response) = session.responses.single;
        expect(id, 'r3');
        expect(
          (response as PluginBridgeFailure).code,
          pluginCapabilityUnavailable,
        );
      },
    );

    test(
      'an update that narrows permissions applies to open windows',
      () async {
        await harness.install([
          pluginManifest('sketch.board', capabilities: const []),
        ]);
        session.request(
          PluginBridgeRequest(requestId: 'r4', capability: 'notes.read'),
        );
        await _drain();

        final (_, response) = session.responses.single;
        expect(
          (response as PluginBridgeFailure).code,
          pluginCapabilityUndeclared,
        );
        expect(harness.current.session('sketch.board'), isNotNull);
      },
    );

    test('a failing respond does not escape the source', () async {
      session.failActions = true;
      session.request(
        PluginBridgeRequest(requestId: 'r5', capability: 'notes.read'),
      );
      await _drain();

      expect(session.responses, isEmpty);
      expect(harness.current.session('sketch.board'), isNotNull);
    });
  });

  group('window actions', () {
    late FakePluginWindowSession session;

    setUp(() async {
      await harness.install([pluginManifest('sketch.board')]);
      session = await harness.open('sketch.board');
    });

    test('reload reaches the open session only', () async {
      harness.source.send(const ReloadPluginWindow('sketch.board'));
      harness.source.send(const ReloadPluginWindow('focus.timer'));
      await _drain();

      expect(session.reloads, 1);
    });

    test('a permission decision is sent only while one is pending', () async {
      harness.source.send(
        const DecidePluginWindowPermission(
          'sketch.board',
          PluginPermissionDecision.allowOnce,
        ),
      );
      await _drain();
      expect(session.decisions, isEmpty);

      session.emit(PluginWindowPermissionRequest(capability: 'notes.read'));
      await _drain();
      harness.source.send(
        const DecidePluginWindowPermission(
          'sketch.board',
          PluginPermissionDecision.deny,
        ),
      );
      await _drain();

      expect(session.decisions, [PluginPermissionDecision.deny]);
    });

    test(
      'adapter failures on reload and decide stay inside the source',
      () async {
        session.failActions = true;
        session.emit(PluginWindowPermissionRequest(capability: 'notes.read'));
        await _drain();

        harness.source.send(const ReloadPluginWindow('sketch.board'));
        harness.source.send(
          const DecidePluginWindowPermission(
            'sketch.board',
            PluginPermissionDecision.allowAlways,
          ),
        );
        await _drain();

        expect(
          harness.current.session('sketch.board')!.status,
          PluginWindowStatus.permissionRequest,
        );
      },
    );

    test('close removes the window and closes its session', () async {
      harness.source.send(const ClosePluginWindow('sketch.board'));
      await _drain();

      expect(harness.current.sessions, isEmpty);
      expect(session.closes, 1);

      session.emit(PluginWindowLoading(progress: 0.5));
      await _drain();
      expect(harness.current.sessions, isEmpty);
    });

    test('uninstalling a plugin closes its window', () async {
      await harness.install(const []);

      expect(harness.current.sessions, isEmpty);
      expect(session.closes, 1);
    });

    test('a reopened window gets a new session', () async {
      harness.source.send(const ClosePluginWindow('sketch.board'));
      await _drain();
      final reopened = await harness.open('sketch.board');

      expect(reopened, isNot(same(session)));
      expect(harness.port.opens, 2);
      expect(
        harness.current.session('sketch.board')!.status,
        PluginWindowStatus.loading,
      );
    });
  });

  test('dispose closes every session and ignores later intents', () async {
    await harness.install([
      pluginManifest('sketch.board'),
      pluginManifest('focus.timer', name: 'Focus Timer'),
    ]);
    final sketch = await harness.open('sketch.board');
    final timer = await harness.open('focus.timer');

    await harness.source.dispose();
    harness.source.send(const ReloadPluginWindow('sketch.board'));
    await _drain();

    expect(sketch.closes, 1);
    expect(timer.closes, 1);
    expect(sketch.reloads, 0);
  });
}
