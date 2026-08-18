import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/application/controller';
  const facades = <String, String>{
    'client_conversation_facade.dart': 'ClientConversationFacade',
    'client_presentation_facade.dart': 'ClientPresentationFacade',
    'client_routing_facade.dart': 'ClientRoutingFacade',
    'client_navigation_facade.dart': 'ClientNavigationFacade',
    'client_lifecycle_facade.dart': 'ClientLifecycleFacade',
  };

  test('runtime facade leaves are ordinary imports with bounded ownership', () {
    final controller = File('$root/client_controller.dart').readAsStringSync();
    for (final entry in facades.entries) {
      final source = File('$root/${entry.key}').readAsStringSync();
      expect(controller, contains("controller/${entry.key}';"));
      expect(controller, contains(entry.value));
      expect(source, isNot(contains('client_controller.dart')));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
  });

  test('thin controller delegates lifecycle navigation and presentation', () {
    final controller = File('$root/client_controller.dart').readAsStringSync();
    final routing = File('$root/client_routing_facade.dart').readAsStringSync();
    expect(controller, contains('ClientComponentAssembly('));
    expect(routing, contains('AgentService get agentService'));
    expect(routing, contains('agentWorkspaceReadSettingsState'));
    expect(
      controller,
      contains('entryHookTasks: resolveInterfaceEntryHookTasks()'),
    );
    expect(
      controller,
      contains(
        'ClientInterfaceEntryHookController get interfaceEntryHookController',
      ),
    );
    expect(
      controller,
      contains('notifyStateChanged: notifyClientStateChanged'),
    );
    expect(controller, isNot(contains('Future<void> _initializeCore()')));
    expect(controller, isNot(contains('void _selectDefaultConversationAgent')));
    expect(controller, isNot(contains('Future<void> reloadAppearancePresets')));
  });
}
