import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/application/controller/assembly';
  const leaves = <String, ({String owner, String forbidden})>{
    'client_lifecycle_component_assembly.dart': (
      owner: 'ClientLifecycleCoordinator(',
      forbidden: 'TargetController(',
    ),
    'client_conversation_component_assembly.dart': (
      owner: 'AgentConversationGatewayAdapter(',
      forbidden: 'AgentUsageController(',
    ),
    'client_routing_component_assembly.dart': (
      owner: 'RoutingModuleLifecycleController(',
      forbidden: 'MobileRelayController(',
    ),
    'client_target_component_assembly.dart': (
      owner: 'TargetController(',
      forbidden: 'SkillHubController(',
    ),
    'client_skill_component_assembly.dart': (
      owner: 'SkillHubController(',
      forbidden: 'TargetController(',
    ),
    'client_settings_component_assembly.dart': (
      owner: 'ClientUpdateController(',
      forbidden: 'SecureMeshController(',
    ),
    'client_mobile_component_assembly.dart': (
      owner: 'SecureMeshController(',
      forbidden: 'ClientUpdateController(',
    ),
    'client_usage_component_assembly.dart': (
      owner: 'AgentUsageController(',
      forbidden: 'SkillHubController(',
    ),
    'client_navigation_component_assembly.dart': (
      owner: 'ClientNavigationController(',
      forbidden: 'RoutingModuleLifecycleController(',
    ),
    'client_presentation_component_assembly.dart': (
      owner: 'LayoutManager(',
      forbidden: 'AgentConversationGatewayAdapter(',
    ),
  };

  test('each component factory owns one bounded construction concern', () {
    for (final entry in leaves.entries) {
      final source = File('$root/${entry.key}').readAsStringSync();
      expect(source, contains(entry.value.owner), reason: entry.key);
      expect(source, isNot(contains(entry.value.forbidden)), reason: entry.key);
      expect(
        source,
        isNot(contains('client_controller.dart')),
        reason: entry.key,
      );
      expect(source.split('\n').length, lessThan(140), reason: entry.key);
    }
  });

  test(
    'root assembly composes leaves without rebuilding feature controllers',
    () {
      final source = File(
        'lib/src/application/controller/client_component_assembly.dart',
      ).readAsStringSync();
      expect(source.split('\n').length, lessThan(320));
      for (final className in [
        'ClientLifecycleComponentAssembly(',
        'ClientConversationComponentAssembly(',
        'ClientRoutingComponentAssembly(',
        'ClientTargetComponentAssembly(',
        'ClientSkillComponentAssembly(',
        'ClientSettingsComponentAssembly(',
        'ClientMobileComponentAssembly(',
        'ClientUsageComponentAssembly(',
        'ClientNavigationComponentAssembly(',
        'ClientPresentationComponentAssembly(',
      ]) {
        expect(source, contains(className));
      }
      expect(source, isNot(contains('= TargetController(')));
      expect(source, isNot(contains('= SecureMeshController(')));
    },
  );
}
