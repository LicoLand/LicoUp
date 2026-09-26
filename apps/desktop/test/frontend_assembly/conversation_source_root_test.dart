// V7-FI: the conversation plane owner is bound once at the root and the dock
// reads it instead of the producer's raw projections.
//
// These tests prove the closure F5's owner enables:
// - the root scope resolves one runtime-backed owner over this composition's
//   own producer channels (not a second source and not the disabled port);
// - the dock renders the admitted planes and shows nothing once a plane is
//   withdrawn, while the producer owner still holds the value;
// - unmounting and remounting the dock reuses the same owner, opens no second
//   source, and does not revive the withdrawn plane;
// - withdrawing one plane leaves the other authorized planes visible.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/projections/conversation/conversation_source_owner.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

const _composerFieldKey = Key('agent-conversation-composer-field');

ResourceKey _composerPlaneResource() =>
    conversationPlaneFieldGroupFor<Object?>(conversationPlaneComposer).resource;

void main() {
  test(
    'the root binds one plane owner over the composition producer',
    () async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('dashboard'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
        size: const Size(1280, 800),
        brightness: Brightness.dark,
      );
      addTearDown(fixture.dispose);
      final composition = ClientAppComposition(controller: fixture.controller);
      addTearDown(composition.dispose);
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      addTearDown(container.dispose);

      final port = container.read(conversationSourcePortProvider);
      expect(port, isA<ConversationSourceOwner>());
      expect(
        identical(container.read(conversationSourcePortProvider), port),
        isTrue,
        reason: 'the container must resolve one owner, not one per read',
      );
      final owner = port as ConversationSourceOwner;
      final composerPlane = owner.composer as ConversationPlaneRuntime;

      expect(
        await _waitUntil(() => composerPlane.visibleValue != null),
        isTrue,
        reason: 'the composer plane never admitted a value',
      );
      // The admitted value is the producer's current plane value, so the owner
      // wraps this composition's channels instead of rebuilding content.
      expect(
        composerPlane.visibleValue,
        composition.conversation.composer.current,
      );

      // An application withdrawal hides the plane while the producer keeps its
      // value; nothing falls back to the raw projection.
      composition.presentationRuntime.revoke(_composerPlaneResource());
      await _waitUntil(() => composerPlane.visibleValue == null);
      expect(composerPlane.visibleValue, isNull);
      expect(
        composition.conversation.composer.current.conversationId,
        isNotEmpty,
      );

      owner.reconnect(conversationPlaneComposer);
      expect(
        await _waitUntil(() => composerPlane.visibleValue != null),
        isTrue,
        reason: 'an explicit re-read must admit the fresh incarnation',
      );
      expect(composerPlane.incarnations, 2);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets('the dock reads planes, keeps partitions, and survives remount', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1180, 760),
      brightness: Brightness.dark,
    );
    addTearDown(fixture.dispose);
    final composition = ClientAppComposition(controller: fixture.controller);
    addTearDown(composition.dispose);
    final overrides = composition.presentationOverrides;
    final features = composition.renderer.createChromeFeatures(
      ValueNotifier<bool>(false),
    );
    Widget dock() =>
        Builder(builder: (context) => features.buildDockComposer(context));
    Widget app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildLicoTheme(
        presetId: 'default-system',
        platformBrightness: Brightness.dark,
      ).copyWith(platform: TargetPlatform.macOS),
      home: ProviderScope(
        overrides: overrides,
        child: Scaffold(body: Center(child: child)),
      ),
    );

    try {
      await tester.pumpWidget(app(dock()));
      expect(
        await _pumpUntil(tester, find.byKey(_composerFieldKey)),
        isTrue,
        reason: 'the dock never rendered the admitted composer plane',
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(_composerFieldKey)),
      );
      final owner =
          container.read(conversationSourcePortProvider)
              as ConversationSourceOwner;
      final composerPlane = owner.composer as ConversationPlaneRuntime;
      expect(composerPlane.incarnations, 1);

      // Withdrawing the composer plane hides the input while the producer
      // owner keeps the admitted draft, and the other planes stay visible.
      composition.presentationRuntime.revoke(_composerPlaneResource());
      await tester.pump();
      expect(find.byKey(_composerFieldKey), findsNothing);
      expect(owner.persistentTurns.visibleValue, isNotNull);
      expect(
        composition.conversation.composer.current.conversationId,
        isNotEmpty,
      );

      // Unmounting and remounting the dock reuses the same owner: no second
      // source, no new incarnation, and the withdrawn plane does not revive.
      await tester.pumpWidget(app(const SizedBox.shrink()));
      await tester.pump();
      await tester.pumpWidget(app(dock()));
      await tester.pump();
      await tester.pump();
      expect(
        identical(container.read(conversationSourcePortProvider), owner),
        isTrue,
        reason: 'a dock remount created a second owner',
      );
      expect(composerPlane.incarnations, 1);
      expect(find.byKey(_composerFieldKey), findsNothing);
      expect(owner.composer.visibleValue, isNull);

      // An explicit re-read admits a fresh incarnation and the input returns.
      owner.reconnect(conversationPlaneComposer);
      expect(
        await _pumpUntil(tester, find.byKey(_composerFieldKey)),
        isTrue,
        reason: 'the dock never showed the re-read plane',
      );
      expect(composerPlane.incarnations, 2);

      // The dock's input path keeps a full Chinese draft end to end.
      const draft = '你好，介绍一下当前布局。';
      await tester.enterText(find.byKey(_composerFieldKey), draft);
      await tester.pump();
      // The draft-store echo is trailing-debounced; let the flush land.
      await tester.pump(const Duration(milliseconds: 320));
      expect(composition.conversation.composer.current.draft, draft);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(composition.dispose);
    }
  });
}

Future<bool> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    if (condition()) return true;
    await pumpEventQueue(times: 2);
  }
  return condition();
}

Future<bool> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var frame = 0; frame < 40; frame++) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 20));
  }
  return finder.evaluate().isNotEmpty;
}
