import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/settings/settings_autostart_projection_source.dart';

void main() {
  test('maps semantic autostart actions to fixed native arguments', () async {
    final runner = _AutostartRunner();
    final source = SettingsAutostartProjectionSource(
      runner: runner,
      readGatewayPort: () => 15722,
    );
    addTearDown(source.dispose);
    const trace = TraceContext(traceId: 'settings-autostart');
    final updates = <ProjectionUpdate<SettingsAutostartProjection>>[];
    final subscription = source.changes.listen(updates.add);
    addTearDown(subscription.cancel);

    await source.refresh(trace: trace);
    expect(runner.calls.single, const ['autostart', 'status']);
    expect(source.current.phase, SettingsAutostartPhase.ready);
    expect(source.current.result, SettingsAutostartResult.none);
    expect(updates.last.trace, trace);

    await source.set(
      component: SettingsAutostartComponent.desktop,
      enabled: true,
      silent: false,
      trace: trace,
    );
    expect(runner.calls.last, const [
      'autostart',
      'set',
      '--component',
      'desktop',
      '--enabled',
      'true',
      '--silent',
      'false',
    ]);
    expect(source.current.desktopEnabled, isTrue);

    await source.set(
      component: SettingsAutostartComponent.gateway,
      enabled: true,
      silent: null,
      trace: trace,
    );
    expect(runner.calls.last, const [
      'autostart',
      'set',
      '--component',
      'gateway',
      '--enabled',
      'true',
      '--port',
      '15722',
    ]);
    expect(source.current.gatewayEnabled, isTrue);
    expect(source.current.result, SettingsAutostartResult.saved);
    expect(updates.every((update) => update.trace == trace), isTrue);
  });

  test(
    'reports a stable semantic load failure without leaking payloads',
    () async {
      final source = SettingsAutostartProjectionSource(
        runner: _FailingRunner(),
        readGatewayPort: () => 0,
      );
      addTearDown(source.dispose);

      await source.refresh();

      expect(source.current.phase, SettingsAutostartPhase.failed);
      expect(source.current.supported, isFalse);
      expect(source.current.result, SettingsAutostartResult.loadFailed);
    },
  );
}

abstract base class _RunCliOnly implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnsupportedError('synthetic_run_cli_only');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      throw UnsupportedError('synthetic_run_cli_only');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnsupportedError('synthetic_run_cli_only');
}

final class _AutostartRunner extends _RunCliOnly {
  final List<List<String>> calls = [];
  bool desktopEnabled = false;
  bool desktopSilent = false;
  bool gatewayEnabled = false;
  bool mcpEnabled = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List<String>.unmodifiable(args));
    if (args.length >= 2 && args[1] == 'set') {
      final component = _option(args, '--component');
      final enabled = _option(args, '--enabled') == 'true';
      if (component == 'desktop') {
        desktopEnabled = enabled;
        desktopSilent = enabled && _option(args, '--silent') == 'true';
      } else if (component == 'gateway') {
        gatewayEnabled = enabled;
      } else if (component == 'mcp') {
        mcpEnabled = enabled;
      }
    }
    return {
      'supported': true,
      'desktop': {'enabled': desktopEnabled, 'silent': desktopSilent},
      'gateway': {'enabled': gatewayEnabled},
      'mcp': {'enabled': mcpEnabled},
    };
  }

  String? _option(List<String> args, String name) {
    final index = args.indexOf(name);
    return index < 0 || index + 1 >= args.length ? null : args[index + 1];
  }
}

final class _FailingRunner extends _RunCliOnly {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    throw StateError('synthetic_autostart_failure');
  }
}
