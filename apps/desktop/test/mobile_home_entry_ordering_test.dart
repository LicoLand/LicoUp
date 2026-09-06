import 'package:licoup/src/contracts/mobile_home_layout.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart';
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

    expect(orderMobileHomeEntryIds(entries, persistedOrder: layout.order), [
      'target:pinned-a',
      'target:pinned-b',
      'target:new',
      'target:old',
    ]);
  });

  test('equal-recency order and preview normalization are deterministic', () {
    const entries = [
      MobileHomeEntryOrderItem(id: 'first', pinned: false, sortTimeMillis: 7),
      MobileHomeEntryOrderItem(id: 'second', pinned: false, sortTimeMillis: 7),
    ];

    expect(orderMobileHomeEntryIds(entries, persistedOrder: const []), [
      'first',
      'second',
    ]);
    expect(mobileHomePreviewText('  safe\n preview  '), 'safe preview');
  });

  test('mobile home layout rejects documents awaiting startup migration', () {
    expect(
      () => MobileHomeLayout.fromJson(const {
        'schemaVersion': 1,
        'order': <String>[],
      }),
      throwsStateError,
    );
  });
}
