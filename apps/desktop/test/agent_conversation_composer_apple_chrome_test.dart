import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';
import 'support/agent_conversation_workspace_fixture.dart';

void main() {
  testWidgets(
    'agent conversation composer uses Apple glass without gold send chrome',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = ClientController();
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'native-history',
          status: 'detected',
          configured: true,
          confidence: 1,
          adapterStatus: 'implemented',
          adapterCapabilities: const {'conversationReadiness': 'ready'},
          supportedActions: const ['runtime.message.send'],
        ),
      ];
      controller.selectedConversationAgentId = 'codex';

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              FixtureLayoutPresentationScope(child: child!),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 900,
              child: AgentConversationWorkspaceFixture(
                controller: controller,
                targets: controller.scannedTargets,
                scanning: false,
                adding: false,
                onAddTarget: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(
        find.byKey(const Key('agent-conversation-composer-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('agent-conversation-composer-send')),
        findsOneWidget,
      );
      expect(find.byType(AppleGlassSurface), findsWidgets);

      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('agent-conversation-composer-field')),
          matching: find.byType(TextField),
        ),
      );
      final theme = buildLicoTheme(platformBrightness: Brightness.dark);
      final colors = theme.extension<LicoThemeColors>()!;
      // The caret and selection are interaction state, so they come from the
      // accent. They are set once on textSelectionTheme rather than overridden
      // per field, so every input in the client agrees.
      expect(field.cursorColor, isNull);
      expect(theme.textSelectionTheme.cursorColor, colors.accent);
      expect(theme.textSelectionTheme.selectionHandleColor, colors.accent);
      expect(field.decoration?.filled, isFalse);
    },
  );
}
