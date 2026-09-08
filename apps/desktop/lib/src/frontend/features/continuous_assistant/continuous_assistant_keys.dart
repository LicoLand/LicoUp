import 'package:flutter/foundation.dart';

/// Stable widget keys derived from typed continuity identities.
///
/// Keys use Goal, child Conversation, card sequence, and notification ids
/// supplied by generated DTOs. They are not hashes and do not change when
/// lifecycle or completion order changes.
abstract final class ContinuousAssistantKeys {
  static const Key composer = ValueKey<String>('continuous-assistant-composer');
  static const Key unavailable = ValueKey<String>(
    'continuous-assistant-unavailable',
  );
  static const Key timeline = ValueKey<String>('continuous-assistant-timeline');
  static const Key childList = ValueKey<String>(
    'continuous-assistant-child-list',
  );

  static Key card(String goalId) =>
      ValueKey<String>('continuous-assistant-card:$goalId');

  static Key child(String childConversationId) =>
      ValueKey<String>('continuous-assistant-child:$childConversationId');

  static Key notice(String notificationId) =>
      ValueKey<String>('continuous-assistant-notice:$notificationId');

  static Key expand(String goalId) =>
      ValueKey<String>('continuous-assistant-expand:$goalId');

  static Key openCard(String goalId) =>
      ValueKey<String>('continuous-assistant-open-card:$goalId');

  static Key pause(String goalId) =>
      ValueKey<String>('continuous-assistant-pause:$goalId');

  static Key resume(String goalId) =>
      ValueKey<String>('continuous-assistant-resume:$goalId');

  static Key cancel(String goalId) =>
      ValueKey<String>('continuous-assistant-cancel:$goalId');

  static Key correct(String goalId) =>
      ValueKey<String>('continuous-assistant-correct:$goalId');

  static Key lifecycle(String goalId) =>
      ValueKey<String>('continuous-assistant-lifecycle:$goalId');

  static Key control(String goalId) =>
      ValueKey<String>('continuous-assistant-control:$goalId');

  static Key sequence(String goalId) =>
      ValueKey<String>('continuous-assistant-sequence:$goalId');

  static Key title(String goalId) =>
      ValueKey<String>('continuous-assistant-title:$goalId');

  static Key collapsed(String goalId) =>
      ValueKey<String>('continuous-assistant-collapsed:$goalId');

  static Key waitReason(String goalId) =>
      ValueKey<String>('continuous-assistant-wait:$goalId');

  static Key responsible(String goalId) =>
      ValueKey<String>('continuous-assistant-responsible:$goalId');

  static Key executor(String goalId, String membershipId) =>
      ValueKey<String>('continuous-assistant-executor:$goalId:$membershipId');

  static Key participant(String goalId, String membershipId) =>
      ValueKey<String>(
        'continuous-assistant-participant:$goalId:$membershipId',
      );

  static Key evidence(String goalId, String opaqueId) =>
      ValueKey<String>('continuous-assistant-evidence:$goalId:$opaqueId');

  static Key source(String goalId, String opaqueId) =>
      ValueKey<String>('continuous-assistant-source:$goalId:$opaqueId');
}
