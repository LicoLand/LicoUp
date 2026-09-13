import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _contentKey = Key('synthetic-content');
const _markKey = Key('synthetic-mark');
const _composerKey = Key('synthetic-composer');
const _hostKey = Key('synthetic-host');

Widget _composer({Key? key, double radius = 24}) =>
    ConversationMotionComposerOutline(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(key: key, height: 56, child: const TextField()),
    );

Widget _fixture({
  bool external = false,
  bool assembled = false,
  bool visible = true,
  bool offstage = false,
  bool reduced = false,
  bool showAvatar = true,
  Object conversationKey = 'synthetic-conversation',
  Object glyphIdentity = 'synthetic-brand-dark',
  double rosterWidth = 120,
  double radius = 24,
  VoidCallback? onAssembled,
}) {
  final content = ConversationMotionContent(
    child: SizedBox(
      key: _contentKey,
      child: Stack(
        children: [
          if (showAvatar) ...[
            Positioned(
              left: 32,
              top: 26,
              child: ConversationMotionAvatarTarget(
                child: ConversationMotionBrandMark(
                  glyphIdentity: glyphIdentity,
                  child: SizedBox(
                    key: _markKey,
                    width: 40,
                    height: 40,
                    child: CustomPaint(painter: _SyntheticBrandPainter()),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: 84,
              top: 36,
              child: Text('Synthetic reply is immediately visible'),
            ),
            // A newer-painted historical avatar must not take the destination.
            Positioned(
              left: 32,
              top: 150,
              child: ConversationMotionBrandMark(
                glyphIdentity: 'unselected-history',
                child: const SizedBox(
                  width: 80,
                  height: 80,
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
  final scene = ConversationMotionScene(
    conversationKey: conversationKey,
    visible: visible,
    assembled: assembled,
    onAssembled: onAssembled,
    child: Row(
      children: [
        SizedBox(width: rosterWidth),
        Expanded(
          child: Column(
            children: [
              Expanded(child: content),
              if (!external) _composer(key: _composerKey, radius: radius),
              if (external)
                TickerMode(enabled: false, child: _composer(radius: 2)),
            ],
          ),
        ),
      ],
    ),
  );
  final body = external
      ? ConversationMotionHost(
          key: _hostKey,
          child: Stack(
            children: [
              Positioned(
                left: 130,
                right: 30,
                bottom: 18,
                child: _composer(key: _composerKey, radius: radius),
              ),
              Positioned.fill(
                bottom: 96,
                child: Offstage(offstage: offstage, child: scene),
              ),
            ],
          ),
        )
      : Offstage(offstage: offstage, child: scene);
  return MaterialApp(
    theme: buildLicoTheme(platformBrightness: Brightness.dark),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(70, 24, 30, 36),
          child: body,
        ),
      ),
    ),
  );
}

ConversationParticleField _field(
  WidgetTester tester, {
  bool skipOffstage = true,
}) => tester.widget<ConversationParticleField>(
  find.byType(ConversationParticleField, skipOffstage: skipOffstage),
);

Future<void> _finishLocalRaster(WidgetTester tester) async {
  // Let the engine's local image readback finish outside the fake async clock.
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });
  await tester.pump();
  await tester.pump();
}

class _SyntheticBrandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.25,
        size.height * 0.125,
        size.width * 0.25,
        size.height * 0.75,
      ),
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_SyntheticBrandPainter oldDelegate) => false;
}

void main() {
  for (final external in [false, true]) {
    testWidgets(
      '${external ? 'Desktop sibling' : 'Dashboard nested'} composer uses real local geometry and keeps input live',
      (tester) async {
        await tester.pumpWidget(_fixture(external: external));
        await _finishLocalRaster(tester);
        final initial = _field(tester);
        final host = tester.getRect(find.byType(ConversationMotionHost));
        final content = tester
            .getRect(find.byKey(_contentKey))
            .shift(-host.topLeft);
        final mark = tester.getRect(find.byKey(_markKey)).shift(-host.topLeft);
        final composer = tester
            .getRect(find.byKey(_composerKey))
            .shift(-host.topLeft);
        expect(
          (initial.anchors.sphere.center - content.center).distance,
          lessThan(0.001),
        );
        expect(initial.anchors.avatar, mark);
        expect(initial.anchors.composer!.outerRect, composer);
        expect(initial.anchors.composer!.tlRadiusX, 24);
        final glyph = initial.avatarGlyph!;
        for (var i = 0; i < glyph.normalizedPositions.length; i += 2) {
          expect(glyph.normalizedPositions[i], inInclusiveRange(0.25, 0.5));
          expect(
            glyph.normalizedPositions[i + 1],
            inInclusiveRange(0.125, 0.875),
          );
        }
        final state = tester.state(find.byType(ConversationParticleField));
        await tester.pumpWidget(_fixture(external: external, assembled: true));
        await tester.pump();
        expect(
          tester.state(find.byType(ConversationParticleField)),
          same(state),
        );
        expect(
          find.text('Synthetic reply is immediately visible'),
          findsOneWidget,
        );
        final input = find.descendant(
          of: find.byKey(_composerKey),
          matching: find.byType(TextField),
        );
        await tester.enterText(input, 'Next synthetic draft');
        expect(find.text('Next synthetic draft'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final external in [false, true]) {
    testWidgets(
      '${external ? 'external' : 'nested'} composer reports real submits without content or slash-new events',
      (tester) async {
        for (final fixture in [
          (
            draft: 'Synthetic request',
            enabled: true,
            attachments: false,
            expected: ['visual', 'send'],
          ),
          (
            draft: '',
            enabled: true,
            attachments: true,
            expected: ['visual', 'send'],
          ),
          (draft: '/new', enabled: true, attachments: false, expected: ['new']),
          (
            draft: 'Disabled request',
            enabled: false,
            attachments: false,
            expected: <String>[],
          ),
          (
            draft: '   ',
            enabled: true,
            attachments: false,
            expected: <String>[],
          ),
        ]) {
          final events = <String>[];
          final composer = RuntimeMessageComposer(
            targetLabel: 'Synthetic Agent',
            initialDraft: fixture.draft,
            busy: false,
            enabled: fixture.enabled,
            hasAttachments: fixture.attachments,
            modelOptions: const [],
            selectedModel: '',
            reasoningEffortOptions: const [],
            selectedReasoningEffort: '',
            onModelChanged: (_) {},
            onReasoningEffortChanged: (_) {},
            onDraftChanged: (_) {},
            onSend: (_) async {
              events.add('send');
              return true;
            },
            onSlashNewConversation: () => events.add('new'),
          );
          final scene = ConversationMotionScene(
            key: UniqueKey(),
            conversationKey: 'synthetic-submission',
            visible: true,
            assembled: false,
            onSendInitiated: () => events.add('visual'),
            child: Column(
              children: [
                const Expanded(
                  child: ConversationMotionContent(child: SizedBox.expand()),
                ),
                if (!external) composer,
              ],
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: buildLicoTheme(platformBrightness: Brightness.dark),
              home: Scaffold(
                body: external
                    ? ConversationMotionHost(
                        child: Column(
                          children: [
                            Expanded(child: scene),
                            composer,
                          ],
                        ),
                      )
                    : scene,
              ),
            ),
          );
          tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
            fixture.draft,
          );
          await tester.pump();
          expect(events, fixture.expected);
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }

  testWidgets(
    'resize and animated outline retain field identity and cached mark geometry',
    (tester) async {
      await tester.pumpWidget(_fixture(external: true));
      await _finishLocalRaster(tester);
      final state = tester.state(find.byType(ConversationParticleField));
      final glyph = _field(tester).avatarGlyph;
      await tester.pumpWidget(_fixture(external: true, assembled: true));
      await tester.pump(const Duration(milliseconds: 700));
      tester.view.physicalSize = const Size(1000, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        _fixture(external: true, assembled: true, rosterWidth: 180, radius: 12),
      );
      await tester.pump();
      final field = _field(tester);
      final host = tester.getRect(find.byType(ConversationMotionHost));
      expect(
        (field.anchors.sphere.center -
                tester
                    .getRect(find.byKey(_contentKey))
                    .shift(-host.topLeft)
                    .center)
            .distance,
        lessThan(0.001),
      );
      expect(field.anchors.composer!.tlRadiusX, 12);
      expect(field.avatarGlyph, same(glyph));
      expect(tester.state(find.byType(ConversationParticleField)), same(state));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'conversation switch removes old anchors and creates a fresh field',
    (tester) async {
      await tester.pumpWidget(_fixture(external: true));
      await _finishLocalRaster(tester);
      final oldState = tester.state(find.byType(ConversationParticleField));
      await tester.pumpWidget(
        _fixture(
          external: true,
          conversationKey: 'another-conversation',
          showAvatar: false,
        ),
      );
      await tester.pump();
      expect(
        tester.state(find.byType(ConversationParticleField)),
        isNot(same(oldState)),
      );
      expect(_field(tester).anchors.avatar, isNull);
      await tester.pumpWidget(_fixture(external: true, visible: false));
      await tester.pump();
      expect(find.byType(ConversationParticleField), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offstage stops visual ticks and reduced motion completes only decoration',
    (tester) async {
      var completed = 0;
      await tester.pumpWidget(_fixture(external: true));
      await _finishLocalRaster(tester);
      await tester.pumpWidget(_fixture(external: true, offstage: true));
      await tester.pump();
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(
        TickerMode.valuesOf(
          tester.element(
            find.byType(ConversationParticleField, skipOffstage: false),
          ),
        ).enabled,
        isFalse,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(
        _fixture(
          external: true,
          reduced: true,
          assembled: true,
          onAssembled: () => completed++,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(completed, 1);
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(find.byKey(_composerKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'content sphere uses the visible ancestor clip rather than overflow height',
    (tester) async {
      const clipKey = Key('synthetic-viewport-clip');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: ConversationMotionHost(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  height: 320,
                  child: ClipRect(
                    key: clipKey,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 500,
                      maxHeight: 500,
                      child: ConversationMotionScene(
                        conversationKey: 'clipped-scene',
                        visible: true,
                        assembled: false,
                        child: const ConversationMotionContent(
                          child: SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final viewport = tester.getRect(find.byKey(clipKey));
      expect(
        (_field(tester).anchors.sphere.center - viewport.center).distance,
        lessThan(0.001),
      );
      expect(
        _field(tester).anchors.sphere.height,
        closeTo(viewport.height * 0.62, 0.001),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scroll retargets the selected mark through the viewport transform',
    (tester) async {
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: ConversationMotionScene(
              conversationKey: 'scrolling-scene',
              visible: true,
              assembled: false,
              child: Column(
                children: [
                  Expanded(
                    child: ConversationMotionContent(
                      child: ListView(
                        controller: scroll,
                        children: [
                          const SizedBox(height: 160),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: ConversationMotionAvatarTarget(
                              child: ConversationMotionBrandMark(
                                glyphIdentity: 'scrolling-mark',
                                child: SizedBox(
                                  key: _markKey,
                                  width: 40,
                                  height: 40,
                                  child: CustomPaint(
                                    painter: _SyntheticBrandPainter(),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 1000),
                        ],
                      ),
                    ),
                  ),
                  _composer(),
                ],
              ),
            ),
          ),
        ),
      );
      await _finishLocalRaster(tester);
      final before = _field(tester).anchors.avatar!;
      scroll.jumpTo(80);
      await tester.pump();
      await tester.pump();
      expect(_field(tester).anchors.avatar, before.shift(const Offset(0, -80)));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'real avatar samples its brand alone and real composer supplies its field',
    (tester) async {
      final target = TargetCandidate(
        target: 'codex',
        label: 'Synthetic Codex',
        kind: 'agent',
        status: TargetCandidateStatus.detected,
        configured: true,
        confidence: 1,
        adapterStatus: 'ready',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: ConversationMotionScene(
              conversationKey: 'real-widgets-synthetic-conversation',
              visible: true,
              assembled: false,
              child: Column(
                children: [
                  Expanded(
                    child: ConversationMotionContent(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConversationMotionAvatarTarget(
                          child: MessagingAgentAvatar(target: target),
                        ),
                      ),
                    ),
                  ),
                  RuntimeMessageComposer(
                    targetLabel: 'Synthetic Agent',
                    initialDraft: '',
                    busy: false,
                    enabled: true,
                    modelOptions: const [],
                    selectedModel: '',
                    reasoningEffortOptions: const [],
                    selectedReasoningEffort: '',
                    onModelChanged: (_) {},
                    onReasoningEffortChanged: (_) {},
                    onDraftChanged: (_) {},
                    onSend: (_) async => true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await _finishLocalRaster(tester);
      await _finishLocalRaster(tester);
      final field = _field(tester);
      expect(field.avatarGlyph, isNotNull);
      expect(
        field.anchors.avatar,
        tester.getRect(find.byType(MessagingAgentAvatar)),
      );
      expect(
        field.anchors.composer!.outerRect,
        tester.getRect(
          find.byKey(const Key('agent-conversation-composer-field')),
        ),
      );
      // The circular well would fill most pixels; the actual mark is sparse.
      expect(field.avatarGlyph!.length, lessThan(2000));
      await tester.enterText(find.byType(TextField), 'Synthetic next message');
      expect(find.text('Synthetic next message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
