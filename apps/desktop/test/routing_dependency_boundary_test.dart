import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('routing contracts do not import implementation layers', () {
    final contractFiles = Directory(
      'lib/src/contracts/routing',
    ).listSync().whereType<File>().where((file) => file.path.endsWith('.dart'));
    final forbiddenImport = RegExp(
      r"import 'package:flutter_client/src/"
      r'(application|backend|frontend|platform)/',
    );

    for (final file in contractFiles) {
      expect(
        forbiddenImport.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.uri.pathSegments.last,
      );
    }
  });

  test('routing registration exposes the coordinator contract port', () {
    final registration = _source(
      'lib/src/contracts/routing/routing_module_registration.dart',
    );
    final port = _source(
      'lib/src/contracts/routing/task_route_coordinator_port.dart',
    );
    final coordinator = _source(
      'lib/src/application/features/routing/controller/'
      'task_route_coordinator.dart',
    );
    final excluded = _source(
      'lib/src/application/features/routing/'
      'excluded_routing_module_registration.dart',
    );

    expect(registration, contains('TaskRouteCoordinatorPort? get coordinator'));
    expect(registration, isNot(contains('/application/')));
    expect(port, contains('abstract interface class TaskRouteCoordinatorPort'));
    expect(coordinator, contains('implements TaskRouteCoordinatorPort'));
    expect(
      excluded,
      isNot(contains('/controller/task_route_coordinator.dart')),
    );
  });
}

String _source(String path) => File(path).readAsStringSync();
