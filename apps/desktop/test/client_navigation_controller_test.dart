import 'package:licoup/src/application/features/navigation/controller/client_navigation_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop keeps every supported destination canonical', () {
    final controller = ClientNavigationController(isMobileRuntime: () => false);
    addTearDown(controller.dispose);

    for (final destination in ClientSection.values) {
      expect(controller.resolve(destination), destination);
    }
  });

  test('mobile surface limits sections to the supported destinations', () {
    final controller = ClientNavigationController(isMobileRuntime: () => true);
    addTearDown(controller.dispose);

    expect(controller.resolve(ClientSection.monitoring), ClientSection.agents);
    expect(controller.resolve(ClientSection.skillHub), ClientSection.agents);
    expect(
      controller.resolve(ClientSection.pluginManagement),
      ClientSection.agents,
    );
    expect(controller.resolve(ClientSection.agentHub), ClientSection.agents);
    expect(
      controller.resolve(ClientSection.mobileRelay),
      ClientSection.mobileRelay,
    );
  });

  test('selection invokes enter, exit, and reselect hooks exactly once', () {
    var exits = 0;
    var enters = 0;
    var reselects = 0;
    final controller = ClientNavigationController(
      isMobileRuntime: () => false,
      hooks: {
        ClientSection.agents: ClientSectionHooks(onExit: () => exits += 1),
        ClientSection.settings: ClientSectionHooks(
          onEnter: () => enters += 1,
          onReselect: () => reselects += 1,
        ),
      },
    );
    addTearDown(controller.dispose);

    expect(controller.select(ClientSection.settings), isTrue);
    expect(controller.select(ClientSection.settings), isFalse);
    expect((exits, enters, reselects), (1, 1, 1));
  });
}
