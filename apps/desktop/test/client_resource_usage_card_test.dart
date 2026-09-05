import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/contracts/agent_resource_usage_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/client_resource_usage_probe.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/settings/settings_resource_usage_projection_source.dart';

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

  testWidgets('layout replacement keeps shared samplers active', (
    tester,
  ) async {
    final client = ClientResourceUsageController(probe: _SyntheticProbe());
    final agents = AgentResourceUsageController(gateway: _EmptyGateway());
    final source = SettingsResourceUsageProjectionSource(
      client: client,
      agents: agents,
    );
    addTearDown(source.dispose);
    final intents = RecordingSettingsIntents(
      onSend: (intent) {
        if (intent is StartSettingsResourceUsage) source.start();
        if (intent is StopSettingsResourceUsage) source.stop();
      },
    );
    final binding = settingsBindingFixture(intents: intents);
    Widget frame(String layout) => usageTestApp(
      theme: buildLicoTheme(),
      home: KeyedSubtree(
        key: ValueKey(layout),
        child: ClientResourceUsageCard(binding: binding),
      ),
    );

    await tester.pumpWidget(frame('first-layout'));
    expect(client.isSampling, isTrue);
    expect(agents.isSampling, isTrue);
    await tester.pumpWidget(frame('replacement-layout'));
    expect(find.byType(ClientResourceUsageCard), findsOneWidget);
    expect(client.isSampling, isTrue);
    expect(agents.isSampling, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(client.isSampling, isFalse);
    expect(agents.isSampling, isFalse);
  });
}

final class _SyntheticProbe implements ClientResourceUsageProbe {
  @override
  bool get supported => true;

  @override
  ResourceProbeReading read() => const ResourceProbeReading(
    rssBytes: 1024,
    diskReadBytes: 0,
    diskWriteBytes: 0,
  );
}

final class _EmptyGateway implements AgentResourceUsageGateway {
  @override
  Future<AgentResourceUsageReport> scan() async =>
      const AgentResourceUsageReport(
        schemaVersion: AgentResourceUsageReport.currentSchemaVersion,
        generatedAt: '2020-01-02T03:04:00Z',
        agents: [],
        summary: {},
      );
}
