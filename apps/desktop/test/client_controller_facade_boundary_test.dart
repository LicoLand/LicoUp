import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client composition root delegates independent feature facades', () {
    const root = 'lib/src/application/controller';
    final controller = File('$root/client_controller.dart').readAsStringSync();
    final facadeFiles = <String>[
      'client_agent_usage_facade.dart',
      'client_conversation_archive_bindings.dart',
      'client_mobile_relay_facade.dart',
      'client_skill_hub_facade.dart',
      'client_target_facade.dart',
      'client_maintenance_facade.dart',
    ];

    for (final fileName in facadeFiles) {
      final source = File('$root/$fileName').readAsStringSync();
      expect(controller, contains("controller/$fileName';"));
      expect(source, isNot(contains('client_controller.dart')));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }

    expect(controller, contains('ClientAgentUsageFacade'));
    expect(controller, contains('ClientConversationArchiveBindings'));
    expect(controller, contains('ClientMobileRelayFacade'));
    expect(controller, contains('ClientSkillHubFacade'));
    expect(controller, contains('ClientTargetFacade'));
    expect(controller, contains('ClientMaintenanceFacade'));
    expect(
      controller,
      isNot(
        contains(RegExp(r'^\s*void startAgentUsagePolling\(', multiLine: true)),
      ),
    );
    expect(
      controller,
      isNot(
        contains(
          RegExp(
            r'^\s*Future<void> configureMobileRelayStation\(',
            multiLine: true,
          ),
        ),
      ),
    );
    expect(
      controller,
      isNot(
        contains(
          RegExp(r'^\s*Future<void> refreshSkillHub\(', multiLine: true),
        ),
      ),
    );
    expect(
      controller,
      isNot(
        contains(
          RegExp(r'^\s*String get clientLogExportPath', multiLine: true),
        ),
      ),
    );
  });
}
