import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('constructs with default dependencies', () {
    final controller = ClientController();
    addTearDown(controller.dispose);

    expect(controller.agentService, isA<AgentService>());
    expect(controller.portableData, isA<PortableDataRoot>());
  });
}
