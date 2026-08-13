import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';

void main() {
  test('publish replaces the same event identity', () {
    final center = MessagingNotificationCenter();
    var ticks = 0;
    center.addListener(() => ticks += 1);

    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '第一次',
      messageEnglish: 'first',
      tone: MessagingNotificationTone.warning,
      code: 'subagent_mcp_unsupported',
    );
    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '第二次',
      messageEnglish: 'second',
      tone: MessagingNotificationTone.failure,
      code: 'subagent_mcp_unsupported',
    );

    expect(center.items, hasLength(1));
    expect(center.items.single.messageEnglish, 'second');
    expect(center.hasWarningOrFailure, isTrue);
    expect(center.revision, 2);
    expect(ticks, 2);

    center.dismiss('subagent-mcp-cursor');
    expect(center.hasItems, isFalse);
    expect(ticks, 3);
  });
}
