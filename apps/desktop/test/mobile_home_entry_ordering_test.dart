import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pinned order precedes recency-sorted unpinned entries', () {
    const entries = [
      MobileHomeEntryOrderItem(
        id: 'target:old',
        pinned: false,
        sortTimeMillis: 1,
      ),
      MobileHomeEntryOrderItem(
        id: 'target:pinned-b',
        pinned: true,
        sortTimeMillis: 0,
      ),
      MobileHomeEntryOrderItem(
        id: 'target:new',
        pinned: false,
        sortTimeMillis: 5,
      ),
      MobileHomeEntryOrderItem(
        id: 'target:pinned-a',
        pinned: true,
        sortTimeMillis: 0,
      ),
    ];
    const layout = MobileHomeLayout(
      order: ['target:pinned-a', 'target:pinned-b'],
      pinnedEntryIds: {'target:pinned-a', 'target:pinned-b'},
    );

    expect(orderMobileHomeEntryIds(entries, layout), [
      'target:pinned-a',
      'target:pinned-b',
      'target:new',
      'target:old',
    ]);
  });

  test('latest session and preview normalization are deterministic', () {
    const older = AgentConversationSession(
      id: 'older',
      agentId: 'codex',
      title: 'Older',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:01Z',
      messages: [],
    );
    const newer = AgentConversationSession(
      id: 'newer',
      agentId: 'codex',
      title: 'Newer',
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:03Z',
      messages: [],
    );

    expect(latestMobileHomeSession(const [older, newer])?.id, 'newer');
    expect(mobileHomePreviewText('  safe\n preview  '), 'safe preview');
    expect(parseMobileHomeSortTime('invalid'), 0);
  });
}
