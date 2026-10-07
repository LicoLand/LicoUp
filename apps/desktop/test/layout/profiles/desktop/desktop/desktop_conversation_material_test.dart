import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/presentation/desktop_desktop_destination_presentations.dart';

import '../../../../support/conversation_material_harness.dart';

void main() {
  testWidgets('Desktop keeps translucent message roles', (tester) async {
    await verifyConversationMaterialIdentity(
      tester,
      presentation: desktopDesktopAgentsPresentation,
      opaque: false,
    );
  });
}
