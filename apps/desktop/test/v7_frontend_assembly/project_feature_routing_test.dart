import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/app.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/project_collaboration_root.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../support/presentation_source_overrides.dart';
import '../support/bundled_font_loader.dart';

void main() {
  setUpAll(loadBundledVisualFonts);
  for (final profile in ['dashboard', 'desktop']) {
    testWidgets(
      '$profile opens project swimlanes from Features in its content pane',
      (tester) async {
        const motionChannel = MethodChannel(
          'licoup/accessibility/reduce_motion',
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          motionChannel,
          (_) async => null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            motionChannel,
            null,
          ),
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await tester.binding.setSurfaceSize(const Size(1440, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final fixture = await ProductionClientShellFixture.create(
          profileId: LayoutProfileId.parse(profile),
          surface: LayoutRuntimeSurface.desktop,
          destination: ClientSection.agents,
          size: const Size(1440, 900),
          brightness: Brightness.dark,
        );
        addTearDown(fixture.dispose);
        final composition = ClientAppComposition(
          controller: fixture.controller,
        );
        const captureKey = Key('feature-routing-shell-capture');
        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: captureKey,
              child: LicoApp(
                compositionFactory: () => composition,
                initializeController: false,
              ),
            ),
          );
          final features = find.byKey(
            Key(
              profile == 'dashboard'
                  ? 'messaging-sidebar-nav-features'
                  : 'desktop-dock-pin-features',
            ),
          );
          expect(
            await pumpUntilVisible(tester, features, maxFrames: 120),
            isTrue,
          );
          final container = ProviderScope.containerOf(tester.element(features));
          final conversationOwner = container.read(
            conversationSourcePortProvider,
          );
          final composerField = find.byKey(
            const Key('agent-conversation-composer-field'),
          );
          expect(
            await pumpUntilVisible(tester, composerField, maxFrames: 120),
            isTrue,
          );
          await tester.enterText(composerField, '保留这份对话草稿');
          await tester.pump(const Duration(milliseconds: 350));
          final selectedConversation =
              composition.conversation.composer.current.conversationId;
          final draft = composition.conversation.composer.current.draft;
          expect(draft, '保留这份对话草稿');
          final right = find.byKey(const Key('desktop-conversation-pane'));
          final rightElement = profile == 'desktop'
              ? tester.element(right)
              : null;
          final rightRect = profile == 'desktop' ? tester.getRect(right) : null;

          await tester.tap(features);
          final projectEntry = find.byKey(
            Key(
              profile == 'dashboard'
                  ? 'messaging-sidebar-list-projectCollaboration'
                  : 'desktop-launchpad-app-projectCollaboration',
            ),
          );
          expect(
            await pumpUntilVisible(tester, projectEntry, maxFrames: 120),
            isTrue,
          );
          await tester.tap(projectEntry);
          final content = find.byKey(
            const Key('project-swimlanes-feature-content'),
          );
          expect(
            await pumpUntilVisible(tester, content, maxFrames: 120),
            isTrue,
          );
          final unavailable = find.byKey(
            const Key('project-collaboration-unavailable'),
          );
          expect(
            await pumpUntilVisible(tester, unavailable, maxFrames: 120),
            isTrue,
          );
          expect(find.byType(MaterialApp), findsOneWidget);
          final projectOwner = ProjectCollaborationRoot.compositionOf(
            tester.element(content),
          );
          expect(projectOwner, isNotNull);
          expect(
            projectOwner!.source.snapshot,
            isNull,
            reason: 'production must not seed fixture projects',
          );
          expect(
            ClientSection.values.map((section) => section.name),
            isNot(contains('projectCollaboration')),
          );

          if (profile == 'desktop') {
            final left = find.byKey(const Key('desktop-left-pane'));
            expect(
              find.descendant(of: left, matching: content),
              findsOneWidget,
            );
            expect(tester.element(right), same(rightElement));
            expect(tester.getRect(right), rightRect);
            expect(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: find.byKey(const Key('desktop-dock-composer')),
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
                  .text,
              '保留这份对话草稿',
            );
            expect(
              tester.getRect(content).right,
              lessThanOrEqualTo(tester.getRect(right).left),
            );
          } else {
            final sidebar = find.byKey(
              const Key('messaging-sidebar-feature-list'),
            );
            expect(
              tester.getRect(content).left,
              greaterThanOrEqualTo(tester.getRect(sidebar).right),
            );
          }
          expect(
            container.read(conversationSourcePortProvider),
            same(conversationOwner),
          );
          expect(
            composition.conversation.composer.current.conversationId,
            selectedConversation,
          );
          expect(composition.conversation.composer.current.draft, draft);

          // Leave and re-enter through the same Features host, not a second
          // primary destination. Both the project surface and conversation owner
          // must retain application lifetime identity.
          if (profile == 'desktop') await tester.tap(features);
          final hubEntry = find.byKey(
            Key(
              profile == 'dashboard'
                  ? 'messaging-sidebar-list-agentHub'
                  : 'desktop-launchpad-app-agentHub',
            ),
          );
          expect(
            await pumpUntilVisible(tester, hubEntry, maxFrames: 120),
            isTrue,
          );
          await tester.tap(hubEntry);
          await tester.pump();
          expect(content, findsNothing);
          if (profile == 'desktop') await tester.tap(features);
          expect(
            await pumpUntilVisible(tester, projectEntry, maxFrames: 120),
            isTrue,
          );
          await tester.tap(projectEntry);
          expect(
            await pumpUntilVisible(tester, unavailable, maxFrames: 120),
            isTrue,
          );
          expect(
            ProjectCollaborationRoot.compositionOf(tester.element(content)),
            same(projectOwner),
          );
          expect(projectOwner.source.snapshot, isNull);
          expect(
            container.read(conversationSourcePortProvider),
            same(conversationOwner),
          );
          expect(tester.takeException(), isNull);

          // Optional local evidence captures the real LicoApp shell, not a
          // replacement MaterialApp or a synthetic graph page.
          final directory = Platform.environment['FI_SHELL_CAPTURE_DIR'];
          if (directory != null) {
            await tester.pump(const Duration(milliseconds: 500));
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(captureKey),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '$directory/$profile-project-feature.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          if (profile == 'dashboard') {
            await tester.tap(
              find.byKey(const Key('messaging-sidebar-nav-conversations')),
            );
            expect(
              await pumpUntilVisible(tester, composerField, maxFrames: 120),
              isTrue,
            );
            expect(
              tester
                  .widget<EditableText>(
                    find.descendant(
                      of: composerField,
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
                  .text,
              '保留这份对话草稿',
            );
          }
        } finally {
          await tester.runAsync(composition.dispose);
          await tester.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
