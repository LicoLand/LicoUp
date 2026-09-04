import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

import 'fixtures/agent_usage_panel/usage_panel_fixtures.dart';
import 'fixtures/settings_binding_fixture.dart';

void main() {
  group('formatRssBytes', () {
    test('formats megabytes and gigabytes', () {
      expect(formatRssBytes(0), '0');
      expect(formatRssBytes((1.3 * 1024 * 1024).round()), '1.3');
      expect(formatRssBytes(512 * 1024 * 1024), '512');
      expect(formatRssBytes(3 * 1024 * 1024 * 1024), '3.0');
    });
  });

  group('formatMemoryCapacity', () {
    test('formats machine capacity', () {
      expect(formatMemoryCapacity(0), '0 B');
      expect(formatMemoryCapacity(512 * 1024 * 1024), '512 MB');
      expect(formatMemoryCapacity(64 * 1024 * 1024 * 1024), '64 GB');
    });
  });

  testWidgets('renders client and running-agent memory ring segments', (
    tester,
  ) async {
    final source = SettingsValueProjectionFixture(
      SettingsResourceUsageProjection(
        supported: true,
        clientRssBytes: 512 * 1024 * 1024,
        totalMemoryBytes: 64 * 1024 * 1024 * 1024,
        agentRssBytes: {'claude-code': 455 * 1024 * 1024},
      ),
    );
    final intents = RecordingSettingsIntents();
    final binding = settingsBindingFixture(
      resourceUsage: source,
      intents: intents,
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      usageTestApp(
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: SizedBox(
          width: 700,
          height: 420,
          child: ClientResourceUsageCard(binding: binding),
        ),
      ),
    );
    expect(find.text('LicoUp'), findsOneWidget);
    expect(find.text('512'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('455'), findsOneWidget);
    expect(find.textContaining('of 64 GB machine'), findsOneWidget);
    expect(
      intents.values.whereType<StartSettingsResourceUsage>(),
      hasLength(1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    expect(intents.values.whereType<StopSettingsResourceUsage>(), hasLength(1));
  });

  testWidgets('shows an unsupported notice when the source is absent', (
    tester,
  ) async {
    final source = SettingsValueProjectionFixture(
      SettingsResourceUsageProjection.unsupported(),
    );
    final binding = settingsBindingFixture(resourceUsage: source);
    addTearDown(source.dispose);
    await tester.pumpWidget(
      usageTestApp(
        theme: buildLicoTheme(),
        home: SizedBox(
          width: 700,
          height: 200,
          child: ClientResourceUsageCard(binding: binding),
        ),
      ),
    );
    expect(
      find.text(
        'Process resource statistics are not supported on this platform.',
      ),
      findsOneWidget,
    );
    expect(find.text('LicoUp'), findsNothing);
  });
}
