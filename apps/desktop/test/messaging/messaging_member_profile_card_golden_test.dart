import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/member_profile_card_test_support.dart';

void main() {
  testWidgets('member profile card matches the demo anatomy', (tester) async {
    await pumpMemberProfileCardTestPanel(
      tester,
      onOpenMemberHistory: (_, _) {},
      onSelfMascotChanged: (_) {},
      onOpenSettings: () {},
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('member-profile-card-codex')),
      matchesGoldenFile('goldens/member_profile_agent.png'),
    );
    // Dismiss and open the self card for its own golden.
    await tester.tapAt(const Offset(60, 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-member-self')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('member-profile-card-self')),
      matchesGoldenFile('goldens/member_profile_self.png'),
    );
  });
}
