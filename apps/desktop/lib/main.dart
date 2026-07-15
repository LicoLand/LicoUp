import 'package:flutter/widgets.dart';

import 'package:flutter_client/app.dart';
import 'package:flutter_client/src/application/product_acceptance/agent_conversation_release_live.dart';

const _agentConversationReleaseLive = bool.fromEnvironment(
  'LICO_AGENT_CONVERSATION_RELEASE_LIVE',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (_agentConversationReleaseLive) {
    runAgentConversationReleaseLive();
    return;
  }
  runApp(const LicoApp());
}
