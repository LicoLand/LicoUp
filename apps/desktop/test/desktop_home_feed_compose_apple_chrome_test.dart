import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/feed/ui/desktop_home_feed_compose_bar.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

void main() {
  testWidgets(
    'plaza compose uses Apple glass chrome without gold accent send',
    (tester) async {
      final controller = ClientController(agentService: _NoopAgentService());
      addTearDown(controller.dispose);

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
            body: DesktopHomeFeedComposeBar(controller: controller),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AppleGlassSurface), findsWidgets);
      expect(
        find.byKey(const Key('desktop-home-feed-compose-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('desktop-home-feed-compose-submit')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      expect(find.byIcon(Icons.send_rounded), findsNothing);

      final field = tester.widget<TextField>(
        find.byKey(const Key('desktop-home-feed-compose-button')),
      );
      final colors = buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).extension<LicoThemeColors>()!;
      expect(field.cursorColor, colors.info);
      expect(field.cursorColor, isNot(colors.primary));
    },
  );
}

class _NoopAgentService extends AgentService {
  _NoopAgentService() : super();
}
