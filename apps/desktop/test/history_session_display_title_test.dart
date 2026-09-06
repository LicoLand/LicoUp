import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';

void main() {
  const fallback = 'Untitled conversation';

  test('keeps human-readable titles untouched', () {
    expect(
      historySessionDisplayTitle('阅读这份规划，转换成 Better Plan', fallback: fallback),
      '阅读这份规划，转换成 Better Plan',
    );
    expect(
      historySessionDisplayTitle('  Fix the sidebar  ', fallback: fallback),
      'Fix the sidebar',
    );
  });

  test('collapses rollout file names to the fallback', () {
    expect(
      historySessionDisplayTitle(
        'rollout-2026-09-04T02-23-07-01a06882-4db0-7711-98f8-f70d4ca81435.jsonl',
        fallback: fallback,
      ),
      fallback,
    );
    expect(
      historySessionDisplayTitle(
        'rollout-2026-09-04T18-52-07',
        fallback: fallback,
      ),
      fallback,
    );
  });

  test('collapses bare session ids to the fallback', () {
    expect(
      historySessionDisplayTitle(
        '01a06882-4db0-7711-98f8-f70d4ca81435',
        fallback: fallback,
      ),
      fallback,
    );
    expect(historySessionDisplayTitle('   ', fallback: fallback), fallback);
  });

  test('strips leading agent control tags', () {
    expect(
      historySessionDisplayTitle(
        '<turn_aborted> The user interrupted the turn',
        fallback: fallback,
      ),
      'The user interrupted the turn',
    );
  });

  test('strips markdown heading markers', () {
    expect(
      historySessionDisplayTitle(
        '## Referenced ChatGPT conversation',
        fallback: fallback,
      ),
      'Referenced ChatGPT conversation',
    );
  });

  test('collapses internal whitespace for single-line lists', () {
    expect(
      historySessionDisplayTitle('第一行\n  第二行\t缩进', fallback: fallback),
      '第一行 第二行 缩进',
    );
  });

  test('control markup without readable content falls back', () {
    expect(
      historySessionDisplayTitle(
        '<system-reminder></system-reminder>',
        fallback: fallback,
      ),
      fallback,
    );
  });

  test('message previews strip leading control tags', () {
    expect(conversationMessagePreviewText('<turn_aborted>'), '');
    expect(
      conversationMessagePreviewText('<turn_aborted> The user interrupted'),
      'The user interrupted',
    );
    expect(conversationMessagePreviewText('正常的会话预览内容'), '正常的会话预览内容');
  });
}
