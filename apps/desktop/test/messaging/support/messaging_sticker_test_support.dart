import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final TargetCandidate messagingStickerTestTarget = TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
);

void messagingStickerNoop(String _) {}

final class MessagingStickerComposerHost extends StatelessWidget {
  const MessagingStickerComposerHost({super.key, this.sent});

  final List<String>? sent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: RuntimeMessageComposer(
          targetLabel: 'Fixture Agent',
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
          onSend: (text) async {
            sent?.add(text);
            return true;
          },
          floatingMatteCapsule: true,
        ),
      ),
    );
  }
}

final class MessagingStickerTestApp extends StatelessWidget {
  const MessagingStickerTestApp({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      // The expression motion loop never settles; tests exercise the
      // reduced-motion static path instead.
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child,
        ),
      ),
    );
  }
}
