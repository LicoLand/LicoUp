import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import 'support/replacement_shell.dart';

void main() {
  testWidgets('§97/§104 replace the shell renderer with equal outcomes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 760);
    addTearDown(tester.view.reset);
    final productionFixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
      size: const Size(1180, 760),
      brightness: Brightness.light,
    );
    addTearDown(productionFixture.dispose);
    final composition = ClientAppComposition(
      controller: productionFixture.controller,
    );
    addTearDown(() async {
      final disposal = composition.dispose();
      expect(identical(disposal, composition.dispose()), isTrue);
      await disposal;
    });
    final emittedEffects = <String>[];
    final replacementHandledEffects = <String>[];
    final navigationChanges = <String>[];
    var productionShellDisposals = 0;
    var alternateShellDisposals = 0;
    var alternateAgentsResets = 0;
    final effectSubscription = composition.binding.effects.effects.listen(
      (effect) => emittedEffects.add(effect.runtimeType.toString()),
    );
    addTearDown(effectSubscription.cancel);
    final navigationSubscription = composition.binding.navigation.changes
        .listen(
          (update) => navigationChanges.add(update.value.destination.name),
        );
    addTearDown(navigationSubscription.cancel);
    addTearDown(() {
      expect(productionShellDisposals, 1);
      expect(alternateShellDisposals, 1);
    });

    await tester.pumpWidget(
      _testApp(
        Row(
          children: [
            Expanded(
              child: _DisposalProbe(
                onDisposed: () => productionShellDisposals += 1,
                child: ClientShell(
                  binding: composition.binding,
                  renderer: composition.renderer,
                ),
              ),
            ),
            Expanded(
              child: _DisposalProbe(
                onDisposed: () => alternateShellDisposals += 1,
                child: ReplacementShell(
                  binding: composition.binding,
                  conversation: composition.conversation,
                  onEffect: (effect) => replacementHandledEffects.add(
                    effect.runtimeType.toString(),
                  ),
                  onAgentsReset: () => alternateAgentsResets += 1,
                  onDisposed: () {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final conversationId =
        composition.conversation.composer.current.conversationId;
    composition.conversation.intents.send(
      UpdateConversationDraft(conversationId, 'replacement-proof'),
    );
    composition.binding.intents.send(
      const SelectShellDestination(ClientSection.agents),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('replacement-nav-settings')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('replacement-nav-agents')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    composition.settings.intents.send(const SetLayoutPreference('messaging'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.byKey(const Key('replacement-layout-messaging')), findsOne);
    composition.settings.intents.send(const SetLayoutPreference('dashboard'));
    composition.settings.intents.send(
      const SetAppearancePreference('lico-soda'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final outcome = _capture(composition, emittedEffects);
    expect(outcome.navigation, 'agents');
    expect(outcome.layout, startsWith('dashboard:'));
    expect(outcome.environment, '590.0:760.0');
    expect(outcome.conversation, '$conversationId:replacement-proof');
    expect(outcome.status, isNotEmpty);
    expect(outcome.appearance, 'lico-soda');
    expect(outcome.locale, LocalePreference.english);
    expect(replacementHandledEffects, emittedEffects);
    expect(emittedEffects, ['ShellDestinationReselected']);
    expect(navigationChanges, ['settings', 'agents']);
    expect(alternateAgentsResets, 1);
    expect(find.byKey(const Key('replacement-destination')), findsOneWidget);
    expect(find.byKey(const Key('replacement-conversation')), findsOneWidget);
    expect(find.byType(ClientShell), findsOneWidget);
    expect(
      find.byKey(const Key('replacement-layout-dashboard')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('replacement-appearance-lico-soda')),
      findsOneWidget,
    );
  });
}

_Outcome _capture(ClientAppComposition composition, List<String> effects) =>
    _Outcome(
      navigation: composition.binding.navigation.current.destination.name,
      layout:
          '${composition.binding.layout.current.selection.effectiveId.value}:'
          '${composition.binding.layout.current.selection.viewport.name}',
      environment:
          '${composition.binding.environment.current.environment.width}:'
          '${composition.binding.environment.current.environment.height}',
      conversation:
          '${composition.conversation.composer.current.conversationId}:'
          '${composition.conversation.composer.current.draft}',
      effects: List.unmodifiable(effects),
      status:
          '${composition.binding.status.current.messageEnglish}:'
          '${composition.binding.status.current.errorCode}',
      appearance: composition.binding.appearance.current.presetId,
      locale: composition.binding.locale.current.preference,
    );

Widget _testApp(Widget shell) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(
    presetId: 'default-system',
    platformBrightness: Brightness.light,
  ),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(1180, 760)),
    child: shell,
  ),
);

final class _Outcome {
  const _Outcome({
    required this.navigation,
    required this.layout,
    required this.environment,
    required this.conversation,
    required this.effects,
    required this.status,
    required this.appearance,
    required this.locale,
  });

  final String navigation;
  final String layout;
  final String environment;
  final String conversation;
  final List<String> effects;
  final String status;
  final String appearance;
  final String locale;
}

final class _DisposalProbe extends StatefulWidget {
  const _DisposalProbe({required this.onDisposed, required this.child});

  final VoidCallback onDisposed;
  final Widget child;

  @override
  State<_DisposalProbe> createState() => _DisposalProbeState();
}

final class _DisposalProbeState extends State<_DisposalProbe> {
  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
