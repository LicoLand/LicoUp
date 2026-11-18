import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

String participantFlowAt(int hour, int minute, [int second = 0]) =>
    DateTime(2026, 7, 20, hour, minute, second).toIso8601String();

ConversationMessageTimelineItem participantFlowMessageItem(
  String key,
  String role,
  String text,
  String createdAt,
) {
  return ConversationMessageTimelineItem(
    key,
    AgentConversationMessage(
      id: key,
      role: role,
      text: text,
      createdAt: createdAt,
    ),
  );
}

Future<void> pumpParticipantFlowTest(
  WidgetTester tester,
  List<ConversationTimelineItem> newestFirst, {
  ScrollController? scrollController,
  List<TargetCandidate> participantTargets = const [],
  Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles =
      const {},
  bool hasEarlier = false,
  Future<void> Function()? onLoadEarlier,
  Future<void> Function(String)? onCopyText,
  Future<void> Function(String)? onRetryMessage,
  Future<void> Function(String)? onDeleteMessage,
  bool assistantActive = false,
  double viewportHeight = 600,
  ConversationMarkdownPreparation? preparation,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(800, viewportHeight);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (preparation != null)
          conversationMarkdownPortProvider.overrideWithValue(preparation),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportHeight,
            child: MessagingParticipantFlow(
              items: newestFirst,
              adapter: AgentRenderAdapter.fallback(),
              target: TargetCandidate(
                target: 'codex',
                label: 'Codex',
                kind: 'cli',
                status: 'detected',
                configured: true,
                confidence: 1,
                adapterStatus: 'implemented',
              ),
              participantTargets: participantTargets,
              participantRuntimeProfiles: participantRuntimeProfiles,
              assistantActive: assistantActive,
              scrollController: scrollController,
              hasEarlier: hasEarlier,
              onLoadEarlier: onLoadEarlier,
              onCopyText: onCopyText,
              onRetryMessage: onRetryMessage,
              onDeleteMessage: onDeleteMessage,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

bool preparedInlineCodeSpanVisible(WidgetTester tester, String fragment) {
  for (final rich in tester.widgetList<RichText>(
    find.textContaining(fragment, findRichText: true),
  )) {
    var found = false;
    (rich.text as TextSpan).visitChildren((span) {
      if (span is TextSpan &&
          (span.text ?? '').contains(fragment) &&
          span.style?.backgroundColor != null) {
        found = true;
      }
      return true;
    });
    if (found) return true;
  }
  return false;
}
