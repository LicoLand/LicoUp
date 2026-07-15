import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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
              child: AgentConversationWorkspace(
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
      final colors = buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).extension<LicoThemeColors>()!;
      expect(field.cursorColor, colors.info);
      expect(field.decoration?.filled, isFalse);
    },
  );
}
