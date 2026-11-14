/// Isolation proof for the design fixture: the same builder the
/// `tool/design_fixture/main.dart` entrypoint uses must never spawn a
/// process, never reach a native history or target-scan lane, and surface
/// only synthetic conversations.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/app.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

import '../../tool/design_fixture/fixture_data.dart';
import '../../tool/design_fixture/fixture_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fixture composition mounts without process spawns and lists only '
    'synthetic conversations',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'design-fixture-isolation-',
      );
      fixtureSpawnAttempts.clear();

      final controller = buildFixtureController(home: directory.path);
      final composition = ClientAppComposition(
        controller: controller,
        collaborationRunPort: fixtureCollaborationPort,
        pluginWindowHostPort: fixturePluginHost,
      );
      addTearDown(() {
        directory.deleteSync(recursive: true);
      });

      // Keep each frame's software raster cheap: this test asserts
      // composition and service state, not pixels, and a full-size surface
      // makes every pump (plus the initializing spinner's free-running
      // frames during runAsync) cost seconds of raster time.
      tester.view.physicalSize = const Size(480, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(LicoApp(compositionFactory: () => composition));
      // Wait for the lifecycle to reach ready. Async storage work such as
      // the workspace-manifest write makes real file IO whose continuations
      // are registered in the fake zone, so each hop needs one real-time
      // delay (inside runAsync) followed by a pump to flush it; a fixed
      // frame count is not enough for dispose() to drain cleanly.
      // Fake-clock pumps also let bounded retry delays (e.g. the Gateway
      // recovery backoff) settle; kept under the 30s conversation poll
      // periods so transcript content stays deterministic.
      for (var i = 0; i < 240 && !composition.initialized; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 120));
      }
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(composition.initialized, isTrue);

      expect(tester.takeException(), isNull);
      expect(composition.bootstrapFailed, isFalse);
      expect(
        fixtureSpawnAttempts,
        isEmpty,
        reason: 'fixture attempted to spawn: $fixtureSpawnAttempts',
      );

      // Every native conversation call was answered by the synthetic
      // transport; nothing reached a history-projection or target-scan lane.
      expect(
        fixtureConversationTransport.requests
            .map((request) => request.method)
            .toSet(),
        everyElement(
          isIn(const [
            ConversationProtocolMethod.clientConversationExecute,
            ConversationProtocolMethod.agentConversationActive,
            ConversationProtocolMethod.agentConversationAttach,
          ]),
        ),
      );

      expect(
        controller.clientConversationController.groupConversations.map(
          (summary) => summary.id,
        ),
        [fixtureGroupId],
      );
      expect(
        controller.clientConversationController.groupConversations.map(
          (summary) => summary.title,
        ),
        ['Design review crew'],
      );

      // Dispose inside the body so the fake-zone periodic timers are
      // cancelled before the framework's pending-timer invariant runs.
      // dispose() waits for in-flight app-managed writes; those writes
      // continue only while the fake zone keeps flushing, so drive the
      // drain by alternating real time (for file IO) with pumps.
      var disposeSettled = false;
      unawaited(composition.dispose().then((_) => disposeSettled = true));
      for (var i = 0; i < 120 && !disposeSettled; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(disposeSettled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
