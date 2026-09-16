import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/header.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/glass_lens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_search_capsule.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';

/// Reproducible component board for Design System visual review.
/// Uses synthetic content only; GLASS_REVIEW_OUTPUT exports candidate PNGs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture accepted glass reference composition', (tester) async {
    expect(
      GlassLens.isSupported,
      isTrue,
      reason: 'Capture on an Impeller renderer.',
    );
    await GlassLens.ensureLoaded();
    for (final productionChrome in [false, true]) {
      for (final dark in [false, true]) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            theme: buildLicoTheme(
              presetId: dark ? 'lico-soda' : 'lico-soda-light',
              platformBrightness: dark ? Brightness.dark : Brightness.light,
            ).copyWith(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: Center(
                child: FittedBox(
                  child: RepaintBoundary(
                    key: key,
                    child: SizedBox(
                      width: 1000,
                      height: 660,
                      child: _Scene(
                        dark: dark,
                        productionChrome: productionChrome,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // The active Assistant name deliberately keeps animating. Capture a
        // deterministic phase instead of waiting for its loop to settle.
        await tester.pump();
        await tester.pump(
          Duration(milliseconds: productionChrome ? 1800 : 300),
        );
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 2);
        try {
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          final output = const String.fromEnvironment('GLASS_REVIEW_OUTPUT');
          if (output.isNotEmpty) {
            final dir = Directory(output);
            await dir.create(recursive: true);
            await File(
              '${dir.path}/${productionChrome ? 'conversation-' : ''}${dark ? 'dark' : 'light'}.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          }
        } finally {
          img.dispose();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}

class _Scene extends StatelessWidget {
  const _Scene({required this.dark, required this.productionChrome});
  final bool dark;
  final bool productionChrome;
  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final ink = dark ? const Color(0xFFF4F4F6) : const Color(0xFF21242A);
    return ColoredBox(
      color: dark ? const Color(0xFF17191E) : const Color(0xFFF3F4F7),
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: DefaultTextStyle(
          style: TextStyle(fontFamily: 'SF Pro Text', fontSize: 14, color: ink),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LicoUp · Glass',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.8,
                  color: ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                dark
                    ? 'Dark appearance · real Flutter components'
                    : 'Light appearance · real Flutter components',
                style: TextStyle(
                  color: ink.withValues(alpha: 0.55),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 30),
              Row(
                children: [
                  Expanded(
                    child: LicoSearchCapsule(
                      onTap: () {},
                      hintText: 'Search conversations',
                    ),
                  ),
                  const SizedBox(width: 14),
                  LicoIconButton(
                    icon: const Icon(Icons.add_rounded),
                    tooltip: 'New conversation',
                    onPressed: () {},
                    tone: LicoIconButtonTone.outlined,
                  ),
                  const SizedBox(width: 10),
                  LicoIconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: 'Refresh',
                    onPressed: () {},
                    tone: LicoIconButtonTone.outlined,
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 230,
                    height: 36,
                    child: AppleGlassSurface(
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(Icons.tune_rounded, size: 16),
                            SizedBox(width: 10),
                            Text('Conversation settings'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: dark
                                ? const [
                                    Color(0xFF243B58),
                                    Color(0xFF495D69),
                                    Color(0xFF493B58),
                                    Color(0xFF212B40),
                                  ]
                                : const [
                                    Color(0xFFBECEDC),
                                    Color(0xFFE6CFBD),
                                    Color(0xFFA9C9CA),
                                    Color(0xFFB7BDD4),
                                  ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: -60,
                        top: 145,
                        child: Transform.rotate(
                          angle: -0.3,
                          child: Container(
                            width: 760,
                            height: 90,
                            color:
                                (dark ? const Color(0xFFBACED8) : Colors.white)
                                    .withValues(alpha: 0.15),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(26),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (productionChrome)
                              CanonicalGroupConversationHeader(
                                conversation: const ClientConversation(
                                  id: 'visual-reference-group',
                                  title: 'Design conversation',
                                  archived: false,
                                  group: true,
                                  revision: 1,
                                  createdAtUnixMs: 0,
                                  updatedAtUnixMs: 0,
                                  memberships: [],
                                  eventCount: 1,
                                ),
                                rosterVisible: false,
                                onToggleRoster: () {},
                              )
                            else
                              Row(
                                children: [
                                  MessagingConversationOverlayGlass(
                                    borderRadius: BorderRadius.circular(24),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 12,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.forum_outlined, size: 18),
                                          SizedBox(width: 10),
                                          Text(
                                            'Design conversation',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  MessagingConversationOverlayGlass(
                                    borderRadius: BorderRadius.circular(22),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 15,
                                        vertical: 12,
                                      ),
                                      child: Icon(
                                        Icons.more_horiz_rounded,
                                        color: ink,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            const SizedBox(height: 25),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: dark
                                    ? const Color(0xFF282D38)
                                    : const Color(0xFFF6F5F2),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Text(
                                'A quieter edge. More room for the conversation.',
                              ),
                            ),
                            const Spacer(),
                            if (productionChrome) ...[
                              GroupStrategyPickerCapsule(
                                selectedRevision: null,
                                onOpen: (_) {},
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (productionChrome)
                              RuntimeMessageComposer(
                                targetLabel: 'the group',
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
                                showRuntimeSettings: false,
                                floatingMatteCapsule: true,
                                leading: CanonicalGroupAssistantActions(
                                  onPickAttachments: () {},
                                  onNewConversation: () {},
                                  onClearHistory: () {},
                                ),
                                fieldLeading: AssistantToggleButton(
                                  active: true,
                                  configured: true,
                                  label: 'Kimi Code',
                                  status: GroupAssistantStatusLight.ready,
                                  onTap: () {},
                                  onEdit: () {},
                                ),
                              )
                            else
                              MessagingConversationOverlayGlass(
                                borderRadius: BorderRadius.circular(24),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Message the group…',
                                        style: TextStyle(
                                          color: ink.withValues(alpha: 0.58),
                                        ),
                                      ),
                                      const SizedBox(height: 26),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.add_rounded,
                                            size: 20,
                                            color: ink.withValues(alpha: 0.65),
                                          ),
                                          const SizedBox(width: 14),
                                          Text(
                                            'Kimi Code',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: ink.withValues(alpha: 0.7),
                                            ),
                                          ),
                                          const Spacer(),
                                          Icon(
                                            Icons.arrow_upward_rounded,
                                            size: 20,
                                            color: ink,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Text(
                    'Focus',
                    style: TextStyle(
                      fontSize: 12,
                      color: ink.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 270,
                    height: 36,
                    child: AppleGlassSurface.searchField(
                      focused: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Search your conversations',
                            style: TextStyle(
                              fontSize: 12,
                              color: ink.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  LicoGlass(
                    borderRadius: BorderRadius.circular(20),
                    fill: colors.surfaceLow,
                    trackLight: true,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Text(
                        'Hover to move the light',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
