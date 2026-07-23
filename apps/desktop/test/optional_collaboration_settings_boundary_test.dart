import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('optional collaboration is owned only by plugin management', () {
    final root = Directory('lib/src/frontend');
    final imports = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains(
        'features/plugin_management/ui/optional_collaboration_settings.dart',
      )) {
        imports.add(entity.path);
      }
    }

    expect(imports, [
      'lib/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart',
    ]);

    final settings = _read(
      'lib/src/frontend/features/settings/ui/settings_panel.dart',
    );
    expect(settings, isNot(contains('OptionalCollaborationSettings')));
    expect(settings, isNot(contains('AntigravityAdapter')));

    final navigation = File(
      'lib/src/application/features/navigation/controller/client_navigation_controller.dart',
    ).readAsStringSync();
    expect(navigation, isNot(contains('optionalCollaboration')));
  });

  test('collaboration plugin facade composes testable sections', () {
    final surface = _read(
      'lib/src/frontend/features/plugin_management/ui/optional_collaboration_settings.dart',
    );
    for (final section in const [
      'OptionalCollaborationSettingsHeader',
      'OptionalCollaborationPolicyNotice',
      'OptionalCollaborationStatusCard',
      'OptionalCollaborationEnableSection',
      'OptionalCollaborationRunnerTrustSection',
      'OptionalCollaborationInstallSection',
      'OptionalCollaborationCatalogAction',
      'OptionalCollaborationWorkflowSections',
      'OptionalCollaborationTeardownSection',
    ]) {
      expect(surface, contains(section));
    }
    expect(surface, isNot(contains('TextField(')));
    expect(surface, isNot(contains('CheckboxListTile(')));
    expect(surface, isNot(contains('FilledButton(')));
  });

  test('controller facades delegate lifecycle and scenario actions', () {
    final lifecycle = _read(
      'lib/src/application/features/settings/controller/optional_collaboration_controller.dart',
    );
    for (final action in const [
      'OptionalCollaborationLifecycleActions',
      'OptionalCollaborationRunnerTrustActions',
      'OptionalCollaborationInstallActions',
      'OptionalCollaborationWorkflowController',
    ]) {
      expect(lifecycle, contains(action));
    }

    final workflows = _read(
      'lib/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart',
    );
    for (final action in const [
      'OptionalCollaborationLocalAssemblyActions',
      'OptionalCollaborationServerRuntimeActions',
      'OptionalCollaborationMcpActions',
    ]) {
      expect(workflows, contains(action));
    }
    expect(lifecycle, isNot(contains('runCli(')));
    expect(workflows, isNot(contains('runCli(')));
  });

  test('model facade exports responsibility-specific DTO leaves', () {
    final facade = _read(
      'lib/src/contracts/optional_collaboration_models.dart',
    );
    for (final leaf in const [
      'optional_collaboration_install_models.dart',
      'optional_collaboration_plugin_models.dart',
      'optional_collaboration_runner_trust_models.dart',
      'optional_collaboration_workflow_catalog_models.dart',
    ]) {
      expect(facade, contains(leaf));
    }
    expect(facade, isNot(contains('final class ')));

    final localServerFacade = _read(
      'lib/src/contracts/optional_collaboration_local_server_models.dart',
    );
    for (final leaf in const [
      'optional_collaboration_local_assembly_models.dart',
      'optional_collaboration_local_server_lifecycle_models.dart',
      'optional_collaboration_local_server_parser.dart',
      'optional_collaboration_local_server_state.dart',
    ]) {
      expect(localServerFacade, contains(leaf));
    }
    expect(localServerFacade, isNot(contains('final class ')));

    final workflowFacade = _read(
      'lib/src/contracts/optional_collaboration_workflow_models.dart',
    );
    for (final leaf in const [
      'optional_collaboration_mcp_workflow_models.dart',
      'optional_collaboration_workflow_kind.dart',
      'optional_collaboration_workflow_plan_models.dart',
      'optional_collaboration_workflow_result_models.dart',
    ]) {
      expect(workflowFacade, contains(leaf));
    }
    expect(workflowFacade, isNot(contains('final class ')));
  });

  test('UI leaves cannot execute commands or own wire DTO parsing', () {
    final root = Directory('lib/src/frontend/features/plugin_management/ui');
    final optionalFiles = root.listSync().whereType<File>().where(
      (file) =>
          file.path.endsWith('.dart') &&
          file.path.split('/').last.startsWith('optional_collaboration_'),
    );
    expect(optionalFiles, isNotEmpty);
    for (final file in optionalFiles) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('runCli(')), reason: file.path);
      expect(source, isNot(contains('Process.')), reason: file.path);
      expect(
        source,
        isNot(contains('Map<String, dynamic>')),
        reason: file.path,
      );
      expect(source, isNot(contains('/backend/')), reason: file.path);
    }
  });

  test('action leaves do not depend on presentation code', () {
    final root = Directory('lib/src/application/features/settings/controller');
    final actionFiles = root.listSync().whereType<File>().where(
      (file) =>
          file.path.endsWith('_actions.dart') &&
          file.path.split('/').last.startsWith('optional_collaboration_'),
    );
    expect(actionFiles, isNotEmpty);
    for (final file in actionFiles) {
      expect(
        file.readAsStringSync(),
        isNot(contains('/frontend/')),
        reason: file.path,
      );
    }
  });

  test('contract leaves never depend on controller or presentation layers', () {
    final root = Directory('lib/src/contracts');
    final files = root.listSync().whereType<File>().where(
      (file) =>
          file.path.endsWith('.dart') &&
          file.path.split('/').last.startsWith('optional_collaboration_'),
    );
    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('/application/')), reason: file.path);
      expect(source, isNot(contains('/frontend/')), reason: file.path);
      expect(source, isNot(contains('/backend/')), reason: file.path);
    }
  });
}

String _read(String path) => File(path).readAsStringSync();
