import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile agent list delegates ordering swipe and desktop surfaces', () {
    final root = File(
      'lib/src/frontend/features/mobile_relay/ui/mobile_agent_list.dart',
    ).readAsStringSync();
    final ordering = File(
      'lib/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart',
    ).readAsStringSync();
    expect(root, contains('orderMobileHomeEntryIds('));
    expect(root, isNot(contains('class MobileDesktopAgentList')));
    expect(root, isNot(contains('class MobileSwipePinAction')));
    expect(ordering, isNot(contains("package:flutter/material.dart")));
  });
}
