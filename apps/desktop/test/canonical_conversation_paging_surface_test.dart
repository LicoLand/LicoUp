import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/reading_position_scroll_controller.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'support/canonical_group/canonical_group_binding_fixture.dart';
import 'support/canonical_group/paged_conversation_native.dart';

void main() {
  for (final strategy in [
    const AgentsPresentationStrategy.console(),
    const AgentsPresentationStrategy.messaging(),
  ]) {
    testWidgets(
      '${strategy.messageStyle.name} scrolls canonical history by twenty and anchors live growth',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 720);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final native = PagedConversationNative();
        final controller = ClientConversationController(native: native);
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.selectConversation('group');
        await tester.pumpWidget(
          _app(
            strategy,
            CanonicalGroupConversationPaneFixture(
              controller: controller,
              targets: [
                TargetCandidate(
                  target: 'codex',
                  label: 'Codex',
                  kind: 'cli',
                  status: 'detected',
                  configured: true,
                  confidence: 1,
                  adapterStatus: 'implemented',
                ),
              ],
              onCopyText: (_) async {},
              framed: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.events, hasLength(20));
        expect(
          native.pageRequests,
          hasLength(1),
          reason: 'Mounting must not automatically page the history.',
        );
        final list = tester.widget<AgentConversationMessageList>(
          find.byType(AgentConversationMessageList),
        );
        final scroll = list.scrollController!;
        expect(scroll, isA<ReadingPositionScrollController>());
        expect(list.hasEarlierMessages, isTrue);
        native.earlierGate = Completer<void>();
        scroll.jumpTo(scroll.position.maxScrollExtent - 100);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.loadingEarlierEvents, isTrue);
        scroll.jumpTo(scroll.offset.clamp(0, scroll.position.maxScrollExtent));
        await tester.pump(const Duration(milliseconds: 100));
        expect(scroll.position.isScrollingNotifier.value, isFalse);
        final anchor = _visibleMessage(tester);
        final before = tester.getTopLeft(anchor).dy;
        native.earlierGate!.complete();
        await tester.pumpAndSettle();
        expect(controller.events, hasLength(40));
        expect(native.pageRequests.last['beforeSequence'], 46);
        expect(native.pageRequests.last['limit'], 20);
        expect(tester.getTopLeft(anchor).dy, closeTo(before, 2));
        final beforeLatest = tester.getTopLeft(anchor).dy;
        native.appendThrough(72);
        await controller.reloadSelected();
        await tester.pumpAndSettle();
        expect(controller.events, hasLength(47));
        expect(tester.getTopLeft(anchor).dy, closeTo(beforeLatest, 2));
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Canonical message 72', findRichText: true),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}

Finder _visibleMessage(WidgetTester tester) {
  for (final element in find.byType(RichText).evaluate()) {
    final value = (element.widget as RichText).text.toPlainText();
    if (!value.startsWith('Canonical message')) continue;
    final finder = find.text(value, findRichText: true);
    final rect = tester.getRect(finder.first);
    if (rect.top > 160 && rect.bottom < 480) return finder.first;
  }
  throw StateError('No visible canonical reading anchor');
}

Widget _app(AgentsPresentationStrategy strategy, Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(
    platformBrightness: Brightness.dark,
  ).copyWith(platform: TargetPlatform.macOS),
  home: Builder(
    builder: (context) => LayoutPaletteScope(
      palette: layoutPaletteFromColors(context.licoColors),
      child: LayoutAgentsStrategyScope(
        strategy: strategy,
        child: Scaffold(body: child),
      ),
    ),
  ),
);
