import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

export 'package:flutter/material.dart';
export 'package:flutter_client/src/application/controller/client_controller.dart';
export 'package:flutter_client/src/contracts/agent_conversation_models.dart';
export 'package:flutter_client/src/contracts/target_candidate.dart';
export 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_composer.dart';
export 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_pane.dart';
export 'package:flutter_test/flutter_test.dart';

TargetCandidate paneTestTarget({
  String target = 'codex',
  String label = 'Codex',
}) => TargetCandidate(
  target: target,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationReadiness': 'ready'},
  supportedActions: const ['runtime.message.send'],
);

Widget paneTestApp(Widget child, {double width = 800, double height = 600}) {
  return MaterialApp(
    locale: const Locale('en'),
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    home: Scaffold(
      body: SizedBox(width: width, height: height, child: child),
    ),
  );
}
