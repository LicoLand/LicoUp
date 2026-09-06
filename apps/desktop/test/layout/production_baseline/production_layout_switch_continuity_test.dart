import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

import '../fixtures/production_client_shell_fixture.dart';

void main() {
  testWidgets(
    'production shell preserves business draft and isolates profile state',
    (tester) async {
      final dashboard = LayoutProfileId.parse('dashboard');
      final desktop = LayoutProfileId.parse('desktop');
      const surface = LayoutRuntimeSurface.desktop;
      const size = Size(1180, 820);
      final fixture = await ProductionClientShellFixture.create(
        profileId: dashboard,
        surface: surface,
        destination: ClientSection.agents,
        size: size,
        brightness: Brightness.light,
      );
      addTearDown(fixture.dispose);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        fixture.buildApp(
          semanticsKey: const ValueKey<String>('continuity-semantics'),
          repaintBoundaryKey: const ValueKey<String>('continuity-boundary'),
        ),
      );
      await tester.pumpAndSettle();

      Finder composer() => find.descendant(
        of: find.byKey(const Key('agent-conversation-composer-field')),
        matching: find.byType(TextField),
      );
      expect(composer(), findsOneWidget);
      await tester.enterText(composer(), 'draft survives renderer replacement');
      // The composer's draft-store echo is trailing-debounced; let the flush
      // land before exercising renderer replacement.
      await tester.pump(const Duration(milliseconds: 300));

      // Seed a dashboard-only agents-history state the way the conversation
      // workspace toggle would, then prove the state round-trips and stays
      // bound to the dashboard profile namespace across switches.
      final dashboardHistory = _agentsHistoryNamespace(dashboard, surface);
      fixture.layoutStateStore.write(
        dashboardHistory,
        const LayoutExpansionState(false),
      );
      expect(
        fixture.layoutStateStore.read(dashboardHistory),
        const LayoutExpansionState(false),
      );

      final switchToDesktop = fixture.controller.layoutManager.selectLayout(
        desktop,
      );
      await tester.pump();
      await tester.pump();
      expect(await switchToDesktop, isTrue);
      expect(fixture.controller.layoutManager.state.committedId, desktop);

      // Business draft survives the renderer swap; the desktop profile has no
      // dashboard namespace state of its own.
      expect(fixture.controller.conversationComposerDraft, contains('draft'));
      expect(
        fixture.layoutStateStore.read(
          _agentsHistoryNamespace(desktop, surface),
        ),
        isNull,
      );
      expect(
        fixture.layoutStateStore.read(dashboardHistory),
        const LayoutExpansionState(false),
      );

      final switchBack = fixture.controller.layoutManager.selectLayout(
        dashboard,
      );
      await tester.pump();
      await tester.pump();
      expect(await switchBack, isTrue);
      expect(fixture.controller.layoutManager.state.committedId, dashboard);

      expect(
        tester.widget<TextField>(composer()).controller?.text,
        'draft survives renderer replacement',
      );
      expect(
        fixture.layoutStateStore.read(dashboardHistory),
        const LayoutExpansionState(false),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

LayoutStateNamespace _agentsHistoryNamespace(
  LayoutProfileId profileId,
  LayoutRuntimeSurface surface,
) => LayoutStateNamespace(
  profileId: profileId,
  surface: surface,
  destination: ClientSection.agents,
  channel: LayoutStateChannels.agentsHistory,
);
