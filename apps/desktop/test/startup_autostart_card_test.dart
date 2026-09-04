import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/settings/ui/startup_autostart_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('startup card toggles desktop silent gateway and mcp', (
    tester,
  ) async {
    final source = SettingsValueProjectionFixture(
      const SettingsAutostartProjection(
        phase: SettingsAutostartPhase.ready,
        supported: true,
        desktopEnabled: false,
        desktopSilent: false,
        gatewayEnabled: false,
        mcpEnabled: false,
      ),
    );
    late final RecordingSettingsIntents intents;
    intents = RecordingSettingsIntents(
      onSend: (intent) {
        if (intent case SetSettingsAutostart(
          :final component,
          :final enabled,
          :final silent,
        )) {
          final current = source.current;
          source.publish(
            SettingsAutostartProjection(
              phase: SettingsAutostartPhase.ready,
              supported: true,
              desktopEnabled: component == SettingsAutostartComponent.desktop
                  ? enabled
                  : current.desktopEnabled,
              desktopSilent: component == SettingsAutostartComponent.desktop
                  ? (silent ?? current.desktopSilent)
                  : current.desktopSilent,
              gatewayEnabled: component == SettingsAutostartComponent.gateway
                  ? enabled
                  : current.gatewayEnabled,
              mcpEnabled: component == SettingsAutostartComponent.mcp
                  ? enabled
                  : current.mcpEnabled,
              result: SettingsAutostartResult.saved,
            ),
          );
        }
      },
    );
    final binding = settingsBindingFixture(autostart: source, intents: intents);
    addTearDown(source.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            FixtureLayoutPresentationScope(child: child!),
        locale: const Locale('zh'),
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
          body: SingleChildScrollView(
            child: StartupAutostartCard(binding: binding),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开启自启动'), findsOneWidget);
    expect(find.text('桌面客户端'), findsOneWidget);
    expect(find.text('后台进程'), findsOneWidget);
    expect(find.text('静默启动'), findsOneWidget);
    expect(find.text('LLM Gateway'), findsOneWidget);
    expect(find.text('本地 MCP 服务'), findsOneWidget);

    await tester.tap(find.byKey(const Key('startup-desktop-autostart')));
    await tester.pumpAndSettle();
    var changes = intents.values.whereType<SetSettingsAutostart>().toList();
    expect(changes.last.component, SettingsAutostartComponent.desktop);
    expect(changes.last.enabled, isTrue);
    expect(changes.last.silent, isFalse);

    await tester.tap(find.byKey(const Key('startup-desktop-silent')));
    await tester.pumpAndSettle();
    changes = intents.values.whereType<SetSettingsAutostart>().toList();
    expect(changes.last.component, SettingsAutostartComponent.desktop);
    expect(changes.last.enabled, isTrue);
    expect(changes.last.silent, isTrue);

    await tester.tap(find.byKey(const Key('startup-gateway-autostart')));
    await tester.pumpAndSettle();
    changes = intents.values.whereType<SetSettingsAutostart>().toList();
    expect(changes.last.component, SettingsAutostartComponent.gateway);
    expect(changes.last.enabled, isTrue);

    await tester.tap(find.byKey(const Key('startup-mcp-autostart')));
    await tester.pumpAndSettle();
    changes = intents.values.whereType<SetSettingsAutostart>().toList();
    expect(changes.last.component, SettingsAutostartComponent.mcp);
    expect(changes.last.enabled, isTrue);
    expect(find.text('自启动设置已保存。'), findsOneWidget);
  });
}
