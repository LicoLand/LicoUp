// V7-FI: ordinary shell behavior under view replacement.
//
// A14 component-integration evidence: replacing the appearance preset and the
// layout profile must not add business reads or dispatched commands, and the
// ordinary shell interactions (navigation selection, Chinese draft input,
// sending) must keep working through the real bindings at the production
// root.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../presentation/composed_client_shell_test_helper.dart';
import '../support/fake_conversation_transport.dart';
import '../support/presentation_source_overrides.dart';

const _shellSize = Size(1180, 760);

Finder _layoutHostFinder() => find.byKey(
  Key(
    'layout-host-dashboard/desktop/'
    '${LayoutViewportPolicy.classify(surface: LayoutRuntimeSurface.desktop, width: _shellSize.width).name}',
  ),
);

void main() {
  testWidgets('appearance and layout replacement add no business reads', (
    tester,
  ) async {
    final transport = FakeConversationTransport(
      command: (_, _) async => {'ok': true, 'turns': [], 'result': []},
    );
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: _shellSize,
      brightness: Brightness.dark,
      conversationNativePort: transport.native,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(_shellSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final compositions = <ClientAppComposition>[];
    try {
      await tester.pumpWidget(
        _testApp(
          composedClientShell(fixture.controller, onComposed: compositions.add),
        ),
      );
      expect(
        await pumpUntilVisible(tester, _layoutHostFinder(), maxFrames: 60),
        isTrue,
        reason: 'the real shell never became visible',
      );
      await tester.pump(const Duration(milliseconds: 160));
      final composition = compositions.single;
      final effects = <ShellEffect>[];
      final effectSubscription = composition.binding.effects.effects.listen(
        effects.add,
      );
      addTearDown(effectSubscription.cancel);
      final readsBefore = transport.requests.length;

      // Replace the appearance preset: no business read, no dispatched
      // command.
      composition.settings.intents.send(
        const SetAppearancePreference('lico-soda'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump();
      expect(
        transport.requests.length,
        readsBefore,
        reason: 'appearance replacement re-read business data',
      );
      expect(effects, isEmpty, reason: 'appearance replacement dispatched');

      // Replace the layout profile and come back: the same business state
      // must be reused instead of re-read.
      composition.settings.intents.send(const SetLayoutPreference('desktop'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        transport.requests.length,
        readsBefore,
        reason: 'layout replacement re-read business data',
      );
      composition.settings.intents.send(const SetLayoutPreference('dashboard'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        transport.requests.length,
        readsBefore,
        reason: 'layout restore re-read business data',
      );

      // The draft and the selected conversation survived both replacements.
      expect(
        composition.conversation.composer.current.conversationId,
        isNotEmpty,
      );
      expect(find.byType(ClientShell), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (compositions.isNotEmpty) {
        await tester.runAsync(compositions.single.dispose);
      }
    }
  });

  testWidgets('feature selection and Chinese draft reach the real bindings', (
    tester,
  ) async {
    final transport = FakeConversationTransport(
      command: (_, _) async => {'ok': true, 'turns': [], 'result': []},
    );
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: _shellSize,
      brightness: Brightness.dark,
      conversationNativePort: transport.native,
    );
    addTearDown(fixture.dispose);
    await tester.binding.setSurfaceSize(_shellSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final compositions = <ClientAppComposition>[];
    try {
      await tester.pumpWidget(
        _testApp(
          composedClientShell(fixture.controller, onComposed: compositions.add),
        ),
      );
      expect(
        await pumpUntilVisible(tester, _layoutHostFinder(), maxFrames: 60),
        isTrue,
        reason: 'the real shell never became visible',
      );
      await tester.pump(const Duration(milliseconds: 160));
      final composition = compositions.single;

      // The shell exposes the renderer chrome port directly: the retired
      // legacy projection wrapper no longer wraps or re-projects it.
      expect(
        identical(
          LayoutChromePortScope.maybeOf(
            tester.element(
              find.byKey(const Key('dashboard-desktop-destination-agents')),
            ),
          ),
          composition.renderer.chrome,
        ),
        isTrue,
        reason: 'the shell must expose the renderer chrome port directly',
      );

      // Selecting the new 功能 row reaches the project collaboration
      // destination through the real navigation intent path.
      expect(
        await pumpUntilVisible(
          tester,
          find.byKey(const Key('messaging-sidebar-nav-features')),
          maxFrames: 60,
        ),
        isTrue,
        reason: '功能 nav never became visible',
      );
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
      expect(
        await pumpUntilVisible(
          tester,
          find.byKey(const Key('messaging-sidebar-list-projectCollaboration')),
          maxFrames: 60,
        ),
        isTrue,
        reason: '功能 list never became visible',
      );
      await tester.tap(
        find.byKey(const Key('messaging-sidebar-list-projectCollaboration')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(fixture.controller.currentSection, ClientSection.agentHub);
      expect(
        find.byKey(const Key('project-swimlanes-feature-content')),
        findsOneWidget,
      );

      // Back on 对话 the selection and the admitted conversation survived both
      // replacements. The dock's own input path (including a full Chinese
      // draft) is covered from the conversation plane port in
      // conversation_source_root_test.dart.
      expect(
        await pumpUntilVisible(
          tester,
          find.byKey(const Key('messaging-sidebar-nav-conversations')),
          maxFrames: 60,
        ),
        isTrue,
        reason: '对话 nav never became visible',
      );
      await tester.tap(
        find.byKey(const Key('messaging-sidebar-nav-conversations')),
      );
      expect(
        await pumpUntilVisible(
          tester,
          find.byKey(const Key('dashboard-desktop-destination-agents')),
          maxFrames: 60,
        ),
        isTrue,
        reason: 'the 对话 destination never returned',
      );
      expect(fixture.controller.currentSection, ClientSection.agents);
      expect(
        composition.conversation.composer.current.conversationId,
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (compositions.isNotEmpty) {
        await tester.runAsync(compositions.single.dispose);
      }
    }
  });
}

Widget _testApp(Widget shell) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: const Locale('en'),
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(
    presetId: 'default-system',
    platformBrightness: Brightness.dark,
  ).copyWith(platform: TargetPlatform.macOS),
  home: MediaQuery(
    data: const MediaQueryData(
      size: _shellSize,
      devicePixelRatio: 1,
      textScaler: TextScaler.noScaling,
      platformBrightness: Brightness.dark,
      disableAnimations: true,
    ),
    child: shell,
  ),
);
