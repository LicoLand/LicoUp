import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog rejects lifecycle actions on built-in lanes', () {
    expect(
      () => AdapterPluginCatalog.fromJson({
        'ok': true,
        'schemaVersion': adapterPluginCatalogSchema,
        'adapters': [
          _descriptor(
            agentId: 'codex',
            managementKind: 'native',
            actions: const ['install'],
          ),
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'adapter_plugin_builtin_action_invalid',
        ),
      ),
    );
  });

  test(
    'controller executes only a declared bridge action then refreshes',
    () async {
      final runner = _AdapterRunner();
      final updates = <AdapterPluginStatusUpdate>[];
      final controller = AdapterPluginController(
        runner: runner,
        onStatus: updates.add,
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.adapters.single.agentId, 'antigravity');
      expect(
        controller.adapters.single.lifecycleActions,
        contains(AdapterPluginLifecycleAction.install),
      );

      await controller.install('antigravity');
      expect(runner.calls, [
        ['adapter', 'catalog'],
        ['adapter', 'antigravity', 'install'],
        ['adapter', 'catalog'],
      ]);
      expect(controller.adapters.single.installationState, 'installed');
      expect(
        controller.adapters.single.lifecycleActions,
        contains(AdapterPluginLifecycleAction.uninstall),
      );
      expect(updates.last.errorCode, isEmpty);
    },
  );

  test(
    'controller refuses lifecycle actions absent from the catalog',
    () async {
      final runner = _AdapterRunner();
      final updates = <AdapterPluginStatusUpdate>[];
      final controller = AdapterPluginController(
        runner: runner,
        onStatus: updates.add,
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      await controller.uninstall('antigravity');

      expect(runner.calls, [
        ['adapter', 'catalog'],
      ]);
      expect(updates.last.errorCode, 'adapter_plugin_action_not_declared');
    },
  );

  test('controller preserves the native lifecycle failure code', () async {
    final runner = _AdapterRunner()
      ..installErrorCode = 'adapter_plugin_install_failed';
    final updates = <AdapterPluginStatusUpdate>[];
    final controller = AdapterPluginController(
      runner: runner,
      onStatus: updates.add,
    );
    addTearDown(controller.dispose);

    await controller.refresh();
    await controller.install('antigravity');

    expect(runner.calls, [
      ['adapter', 'catalog'],
      ['adapter', 'antigravity', 'install'],
    ]);
    expect(controller.adapters.single.installationState, 'not-installed');
    expect(updates.last.errorCode, 'adapter_plugin_install_failed');
  });
}

Map<String, Object> _descriptor({
  required String agentId,
  required String managementKind,
  required List<String> actions,
  String installationState = 'not-required',
}) => {
  'agentId': agentId,
  'label': agentId,
  'driverId': '$agentId-driver',
  'runtimeProtocol': '$agentId-protocol',
  'laneFamily': managementKind == 'bundled-acp' ? 'acp' : 'cli',
  'managementKind': managementKind,
  'installationState': installationState,
  'readiness': 'ready',
  'lifecycleActions': actions,
};

final class _AdapterRunner implements AgentCommandRunner {
  final List<List<String>> calls = [];
  bool installed = false;
  String? installErrorCode;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.of(args));
    if (args case ['adapter', 'catalog']) {
      return {
        'ok': true,
        'schemaVersion': adapterPluginCatalogSchema,
        'adapters': [
          _descriptor(
            agentId: 'antigravity',
            managementKind: 'managed-bridge',
            installationState: installed ? 'installed' : 'not-installed',
            actions: [installed ? 'uninstall' : 'install'],
          ),
        ],
      };
    }
    if (args case ['adapter', 'antigravity', 'install']) {
      if (installErrorCode case final code?) {
        return {
          'ok': false,
          'error': {'code': code},
        };
      }
      installed = true;
      return {'ok': true, 'installed': true};
    }
    return {
      'ok': false,
      'error': {'code': 'adapter_plugin_action_unsupported'},
    };
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => runCli(args);

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
