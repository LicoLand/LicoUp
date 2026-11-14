import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_quota_usage_card.dart';

import '../support/bundled_font_loader.dart';
import 'support/roster_quota_test_support.dart';

void main() {
  setUpAll(loadBundledVisualFonts);

  testWidgets('roster quota rings render matching macOS golden', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      buildQuotaTestApp(
        const Key('messaging-roster-quota-qa-boundary'),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: CanonicalGroupRosterSurface(
              child: CanonicalGroupRoster(
                conversation: quotaTestConversation(),
                targets: quotaTestTargets(),
                onMentionAgent: (_) {},
                quotaSnapshots: quotaTestSnapshots(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const Key('messaging-roster-quota-qa-boundary')),
      matchesGoldenFile('../goldens/messaging/roster_quota_rings.png'),
    );
  });

  testWidgets('usage card renders matching macOS golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final fixedNow = DateTime.utc(2026, 8, 29, 12);
    await tester.pumpWidget(
      buildQuotaTestApp(
        const Key('messaging-quota-usage-card-qa-boundary'),
        Center(
          child: MessagingQuotaUsageCard(
            snapshot: quotaUsageCardTestSnapshot(fixedNow),
            clock: () => fixedNow,
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const Key('messaging-quota-usage-card-qa-boundary')),
      matchesGoldenFile('../goldens/messaging/roster_quota_usage_card.png'),
    );

    await tester.pumpWidget(const SizedBox());
  });
}
