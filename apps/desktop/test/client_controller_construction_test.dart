import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('constructs with default dependencies', () {
    final controller = ClientController();
    addTearDown(controller.dispose);

    expect(controller.agentService, isA<AgentService>());
    expect(controller.portableData, isA<PortableDataRoot>());
  });
}
