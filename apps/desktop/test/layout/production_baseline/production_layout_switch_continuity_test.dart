import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

import '../fixtures/production_client_shell_fixture.dart';

void main() {
  testWidgets(
    'production shell preserves business draft and isolates profile state',
    (tester) async {
      final workbench = LayoutProfileId.parse('workbench');
      final native = LayoutProfileId.parse('native');
      const surface = LayoutRuntimeSurface.desktop;
      const size = Size(1180, 820);
      final fixture = await ProductionClientShellFixture.create(
        profileId: workbench,
        surface: surface,
        destination: ClientSection.agents,
        size: size,
        brightness: Brightness.light,
      );
      addTearDown(fixture.controller.dispose);
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

      await tester.tap(find.byTooltip('Collapse conversation history'));
      await tester.pump();
      expect(
        fixture.controller.layoutComposition.stateStore.read(
          _agentsHistoryNamespace(workbench, surface),
        ),
        isA<LayoutExpansionState>().having(
          (value) => value.expanded,
          'expanded',
          isFalse,
        ),
      );
      expect(fixture.controller.layoutManager.beginPreview(native), isTrue);
      await tester.pump();
      await tester.pump();

      expect(composer(), findsOneWidget);
      expect(
        tester.widget<TextField>(composer()).controller?.text,
        'draft survives renderer replacement',
      );
      expect(fixture.controller.conversationComposerDraft, contains('draft'));
      expect(
        fixture.controller.layoutComposition.stateStore.read(
          _agentsHistoryNamespace(native, surface),
        ),
        isNull,
      );
      expect(find.byTooltip('Collapse conversation history'), findsOneWidget);

      fixture.controller.layoutManager.cancelPreview();
      await tester.pump();
      await tester.pump();

      expect(find.byTooltip('Expand conversation history'), findsOneWidget);
      expect(
        tester.widget<TextField>(composer()).controller?.text,
        'draft survives renderer replacement',
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
