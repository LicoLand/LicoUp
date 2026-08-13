import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:flutter/material.dart';
export 'package:licoup/src/contracts/agent_conversation_models.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
export 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
export 'package:licoup/src/frontend/shared/ui/theme.dart';
export 'package:flutter_test/flutter_test.dart';

Widget messageBlocksTestApp(Widget child) {
  return MaterialApp(
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    home: Scaffold(body: SizedBox(width: 760, height: 600, child: child)),
  );
}

AgentConversationMessage messageBlockTestMessage({
  required String role,
  required String text,
  String cardType = '',
  String cardTitle = '',
  bool collapsed = true,
  List<AgentConversationMessage> childMessages = const [],
  String? id,
}) {
  return AgentConversationMessage(
    id: id ?? 'message-$role',
    role: role,
    text: text,
    createdAt: '2030-01-01T00:00:00Z',
    cardType: cardType,
    cardTitle: cardTitle,
    collapsed: collapsed,
    childMessages: childMessages,
  );
}
