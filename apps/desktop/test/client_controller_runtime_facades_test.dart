import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/application/controller';
  const facades = <String, String>{
    'client_conversation_facade.dart': 'ClientConversationFacade',
    'client_appearance_commands.dart': 'ClientAppearanceCommands',
    'client_locale_commands.dart': 'ClientLocaleCommands',
    'client_functional_status_commands.dart': 'ClientFunctionalStatusCommands',
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
      isNot(contains('notifyStateChanged: notifyClientStateChanged')),
    );
    expect(controller, isNot(contains('Future<void> _initializeCore()')));
    expect(controller, isNot(contains('void _selectDefaultConversationAgent')));
    expect(controller, isNot(contains('Future<void> reloadAppearancePresets')));
  });

  test('presentation domains cannot regress to aggregate invalidation', () {
    final controller = File('$root/client_controller.dart').readAsStringSync();
    final appearance = File(
      '$root/client_appearance_commands.dart',
    ).readAsStringSync();
    final locale = File('$root/client_locale_commands.dart').readAsStringSync();
    final status = File(
      '$root/client_functional_status_commands.dart',
    ).readAsStringSync();

    expect(controller, isNot(contains('ClientPresentationFacade')));
    expect(File('$root/client_presentation_facade.dart').existsSync(), isFalse);
    for (final source in [appearance, locale, status]) {
      expect(source, isNot(contains('notifyClientStateChanged')));
    }
    expect(appearance, isNot(contains('FunctionalStatusRuntime')));
    expect(appearance, contains('reportAppearanceReloadOutcome('));
    expect(appearance, contains('reportAppearanceReloadFailure();'));
    expect(locale, isNot(contains('FunctionalStatusRuntime')));
    expect(status, isNot(contains('AppearancePreferenceOwner')));
    expect(status, isNot(contains('LocalePreferenceOwner')));
    expect(status, contains('Appearance presets reloaded.'));
    expect(status, contains('appearance_preset_reload_failed'));
  });

  test('application assembly excludes renderer-local layout state', () {
    final assembly = File(
      '$root/assembly/client_presentation_component_assembly.dart',
    ).readAsStringSync();
    final composition = File(
      'lib/src/composition/client_app_composition.dart',
    ).readAsStringSync();

    expect(assembly, contains('required this.layoutCatalog'));
    expect(assembly, contains('required this.layoutManager'));
    expect(assembly, isNot(contains('LayoutStateStore')));
    expect(assembly, isNot(contains('PresentationLayoutRuntime')));
    expect(assembly, isNot(contains('PortableDataRoot')));
    expect(assembly, isNot(contains('FilePresentationPreferencesRepository')));
    expect(assembly, isNot(contains('createBuiltInLayoutCatalog')));
    expect(assembly, isNot(contains('Platform.')));
    expect(composition, contains('_createProductionController'));
    expect(composition, contains('FilePresentationPreferencesRepository'));
    expect(composition, contains('layoutCatalog: layout.catalog'));
    expect(composition, contains('layoutManager: manager'));
    expect(composition, isNot(contains('PresentationLayoutRuntime')));
  });
}
