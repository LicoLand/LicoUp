import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

void main() {
  testWidgets(
    'tapping a messaging contact lands on its new-conversation home',
    (tester) async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('messaging'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
        size: const Size(1180, 820),
        brightness: Brightness.dark,
      );
      addTearDown(fixture.controller.dispose);
      final controller = fixture.controller;
      final agentId = controller.selectedConversationAgentId;
      final session = controller.conversationSessionsByAgent[agentId]!.single;

      await tester.binding.setSurfaceSize(const Size(1180, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        fixture.buildApp(
          semanticsKey: const Key('messaging-selection-semantics'),
          repaintBoundaryKey: const Key('messaging-selection-repaint'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      // With a conversation open, tapping the active contact returns to the
      // new-conversation home; old conversations stay reachable through the
      // recent list and the switcher.
      controller.selectConversationSession(session.id);
      await tester.pump();
      expect(controller.selectedConversationSession?.id, session.id);

      await tester.tap(find.byKey(Key('messaging-contact-$agentId')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      expect(controller.selectedConversationAgentId, agentId);
      expect(controller.selectedConversationSession, isNull);
      expect(find.byKey(Key('messaging-contact-$agentId')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
