import 'dart:ui';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'auth-required failure maps to the authorize runtime action, bilingually',
    () {
      final en = conversationSendAvailabilityCopy(
        strings: LicoStrings.forLocale(const Locale('en')),
        reasonCode: 'antigravity_auth_required',
      );
      expect(en.unblockAction, ConversationSendUnblockAction.authorizeRuntime);
      expect(en.unblockLabel, 'Authorize');
      expect(en.reasonLabel, contains('authorization'));

      final zh = conversationSendAvailabilityCopy(
        strings: LicoStrings.forLocale(const Locale('zh')),
        reasonCode: 'antigravity_auth_required',
      );
      expect(zh.unblockAction, ConversationSendUnblockAction.authorizeRuntime);
      expect(zh.unblockLabel, '授权');
      expect(zh.reasonLabel, contains('授权'));
    },
  );

  test('other driver failures keep the verbatim code without an action', () {
    final copy = conversationSendAvailabilityCopy(
      strings: LicoStrings.forLocale(const Locale('en')),
      reasonCode: 'copilot_acp_protocol_timeout',
    );
    expect(copy.unblockAction, isNull);
    expect(copy.unblockLabel, isNull);
    expect(copy.reasonLabel, contains('copilot_acp_protocol_timeout'));
  });
}
