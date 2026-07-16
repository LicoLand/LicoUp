import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog convergence keeps native, application, and UI authority split', () {
    const root = 'lib/src';
    final controller = File(
      '$root/application/features/catalog_convergence/controller/catalog_convergence_controller.dart',
    ).readAsStringSync();
    final service = File(
      '$root/application/features/catalog_convergence/services/catalog_convergence_service.dart',
    ).readAsStringSync();
    final widget = File(
      '$root/frontend/features/settings/ui/catalog_convergence_status_card.dart',
    ).readAsStringSync();

    expect(controller, isNot(contains('/platform/')));
    expect(controller, isNot(contains('Authorization')));
    expect(service, contains('/platform/native_client/agent_service.dart'));
    expect(widget, isNot(contains('/platform/')));
    expect(widget, isNot(contains('partitionKey')));
    expect(widget, isNot(contains('bearer')));
  });
}
