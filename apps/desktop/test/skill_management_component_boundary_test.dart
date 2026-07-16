import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skill management capabilities have independent acceptance chains', () {
    final contracts = {
      'update': File('lib/src/contracts/skill_update.dart').readAsStringSync(),
      'delete': File('lib/src/contracts/skill_delete.dart').readAsStringSync(),
      'usage': File('lib/src/contracts/skill_usage.dart').readAsStringSync(),
    };
    final services = {
      'update': File(
        'lib/src/application/features/skill_hub/services/skill_update_service.dart',
      ).readAsStringSync(),
      'delete': File(
        'lib/src/application/features/skill_hub/services/skill_delete_service.dart',
      ).readAsStringSync(),
      'usage': File(
        'lib/src/application/features/skill_hub/services/skill_usage_service.dart',
      ).readAsStringSync(),
    };
    final controllers = {
      'update': File(
        'lib/src/application/features/skill_hub/controller/skill_update_controller.dart',
      ).readAsStringSync(),
      'delete': File(
        'lib/src/application/features/skill_hub/controller/skill_delete_controller.dart',
      ).readAsStringSync(),
      'usage': File(
        'lib/src/application/features/skill_hub/controller/skill_usage_controller.dart',
      ).readAsStringSync(),
    };
    final views = {
      'update': File(
        'lib/src/frontend/features/skill_hub/ui/skill_update_section.dart',
      ).readAsStringSync(),
      'delete': File(
        'lib/src/frontend/features/skill_hub/ui/skill_delete_section.dart',
      ).readAsStringSync(),
      'usage': File(
        'lib/src/frontend/features/skill_hub/ui/skill_usage_section.dart',
      ).readAsStringSync(),
    };
    final composition = File(
      'lib/src/frontend/features/skill_hub/ui/skill_management_section.dart',
    ).readAsStringSync();
    final assembly = File(
      'lib/src/application/controller/assembly/client_skill_component_assembly.dart',
    ).readAsStringSync();

    expect(contracts['update'], contains('SkillUpdateGateway'));
    expect(contracts['delete'], contains('SkillDeleteGateway'));
    expect(contracts['usage'], contains('SkillUsageGateway'));
    for (final entry in services.entries) {
      final service = entry.value;
      expect(service, contains("contracts/skill_${entry.key}.dart';"));
      expect(service, isNot(contains('platform/native_client')));
      expect(service, isNot(contains('flutter/material.dart')));
    }
    expect(controllers['update'], contains('SkillUpdateService'));
    expect(controllers['delete'], contains('SkillDeleteService'));
    expect(controllers['usage'], contains('SkillUsageService'));
    for (final controller in controllers.values) {
      expect(controller, isNot(contains('SkillHubController')));
    }
    expect(views['update'], contains('SkillUpdateViewModel'));
    expect(views['delete'], contains('SkillDeleteViewModel'));
    expect(views['usage'], contains('SkillUsageViewModel'));
    for (final view in views.values) {
      expect(view, isNot(contains('ClientController')));
      expect(view, isNot(contains('Service')));
    }
    expect(composition, contains('SkillUpdateSection('));
    expect(composition, contains('SkillDeleteSection('));
    expect(composition, contains('SkillUsageSection('));
    expect(assembly, contains('SkillUpdateController('));
    expect(assembly, contains('SkillDeleteController('));
    expect(assembly, contains('SkillUsageController('));
  });
}
