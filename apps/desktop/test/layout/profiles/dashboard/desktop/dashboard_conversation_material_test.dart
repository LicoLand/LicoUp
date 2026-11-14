import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/presentation/dashboard_card_destination_presentations.dart';

import '../../../../support/conversation_material_harness.dart';

void main() {
  testWidgets('Dashboard owns a solid sidebar and opaque message roles', (
    tester,
  ) async {
    await verifyConversationMaterialIdentity(
      tester,
      presentation: dashboardCardAgentsPresentation,
      opaque: true,
    );
  });
}
