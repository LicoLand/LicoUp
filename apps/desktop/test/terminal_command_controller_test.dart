import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/settings/controller/terminal_command_controller.dart';
import 'package:licoup/src/platform/native_client/terminal_command_port.dart';

/// Deterministic port driving the full decision table without touching
/// `/usr/local/bin`.
final class _FakePort implements TerminalCommandPort {
  _FakePort({
    this.status = TerminalCommandStatus.notInstalled,
    this.occupiedPath,
    this.linkTarget,
  });

  TerminalCommandStatus status;
  String? occupiedPath;
  String? linkTarget;
  bool writable = true;
  bool cancelNext = false;
  bool failNext = false;
  final List<String> calls = [];

  @override
  Future<TerminalCommandInspection> inspect() async =>
      TerminalCommandInspection(
        status: status,
        occupiedPath: occupiedPath,
        linkTarget: linkTarget,
      );

  @override
  Future<bool> canWriteDirectory() async => writable;

  @override
  Future<void> install({required String target, required bool privileged}) {
    calls.add('install:$target:privileged=$privileged');
    if (cancelNext) {
      return Future.error(const TerminalCommandCancelledException());
    }
    if (failNext) return Future.error(StateError('write failed'));
    status = TerminalCommandStatus.installed;
    linkTarget = target;
    return Future.value();
  }

  @override
  Future<void> uninstall({required bool privileged}) {
    calls.add('uninstall:privileged=$privileged');
    if (cancelNext) {
      return Future.error(const TerminalCommandCancelledException());
    }
    if (failNext) return Future.error(StateError('write failed'));
    status = TerminalCommandStatus.notInstalled;
    return Future.value();
  }
}

const _target =
    '/Applications/LicoUp.app/Contents/Helpers/LicoUpCustody.app/Contents/MacOS/licoup';

/// A real temp file standing in for the bundled helper: `install` refuses a
/// target that is absent on disk, so controller tests point at an existing
/// file while never touching `/usr/local/bin`.
late String _bundled;

TerminalCommandController _controller(_FakePort port, {String? target}) =>
    TerminalCommandController(
      port: port,
      bundledTarget: () => target ?? _bundled,
    );

void main() {
  setUpAll(() {
    _bundled = File('${Directory.systemTemp.path}/licoup-test-bundled').path;
    File(_bundled).createSync(recursive: true);
  });

  group('bundledCustodyExecutable', () {
    test('accepts the custody helper path inside the app bundle', () {
      expect(bundledCustodyExecutable(_target), _target);
    });

    test('derives the custody helper from the GUI executable', () {
      expect(
        bundledCustodyExecutable(
          '/Applications/LicoUp.app/Contents/MacOS/LicoUp',
        ),
        _target,
      );
    });

    test('refuses paths outside an app bundle', () {
      expect(bundledCustodyExecutable('/usr/local/bin/licoup'), isNull);
      expect(bundledCustodyExecutable('/tmp/licoup'), isNull);
    });
  });

  group('install', () {
    test('absent destination creates the link', () async {
      final port = _FakePort();
      final (result, _) = await _controller(port).install();
      expect(result, TerminalCommandActionResult.installed);
      expect(port.calls.single, 'install:$_bundled:privileged=false');
      expect(port.status, TerminalCommandStatus.installed);
    });

    test('stale owned link is repointed', () async {
      final port = _FakePort(status: TerminalCommandStatus.stale);
      final (result, _) = await _controller(port).install();
      expect(result, TerminalCommandActionResult.installed);
      expect(port.calls.single, 'install:$_bundled:privileged=false');
    });

    test('installed owned link is repointed idempotently', () async {
      final port = _FakePort(
        status: TerminalCommandStatus.installed,
        linkTarget: _target,
      );
      final (result, _) = await _controller(port).install();
      expect(result, TerminalCommandActionResult.installed);
    });

    test(
      'occupied destination is refused with its path and never written',
      () async {
        final port = _FakePort(
          status: TerminalCommandStatus.occupied,
          occupiedPath: '/opt/homebrew/bin/licoup',
        );
        final (result, occupied) = await _controller(port).install();
        expect(result, TerminalCommandActionResult.occupied);
        expect(occupied, '/opt/homebrew/bin/licoup');
        expect(port.calls, isEmpty);
        expect(port.status, TerminalCommandStatus.occupied);
      },
    );

    test(
      'non-writable directory escalates to the administrator prompt',
      () async {
        final port = _FakePort()..writable = false;
        final (result, _) = await _controller(port).install();
        expect(result, TerminalCommandActionResult.installed);
        expect(port.calls.single, 'install:$_bundled:privileged=true');
      },
    );

    test(
      'administrator cancellation is a distinct non-error outcome',
      () async {
        final port = _FakePort()
          ..writable = false
          ..cancelNext = true;
        final (result, _) = await _controller(port).install();
        expect(result, TerminalCommandActionResult.cancelled);
      },
    );

    test('write failure is reported', () async {
      final port = _FakePort()..failNext = true;
      final (result, _) = await _controller(port).install();
      expect(result, TerminalCommandActionResult.failed);
    });
  });

  group('uninstall', () {
    test('removes an installed owned link', () async {
      final port = _FakePort(
        status: TerminalCommandStatus.installed,
        linkTarget: _target,
      );
      final (result, path) = await _controller(port).uninstall();
      expect(result, TerminalCommandActionResult.uninstalled);
      expect(path, isNull);
      expect(port.calls.single, 'uninstall:privileged=false');
      expect(port.status, TerminalCommandStatus.notInstalled);
    });

    test('removes a stale owned link', () async {
      final port = _FakePort(status: TerminalCommandStatus.stale);
      final (result, path) = await _controller(port).uninstall();
      expect(result, TerminalCommandActionResult.uninstalled);
      expect(path, isNull);
    });

    test('absent destination is a no-op', () async {
      final port = _FakePort();
      final (result, path) = await _controller(port).uninstall();
      expect(result, TerminalCommandActionResult.notInstalled);
      expect(path, isNull);
      expect(port.calls, isEmpty);
    });

    test('occupied destination is refused with its path', () async {
      final port = _FakePort(
        status: TerminalCommandStatus.occupied,
        occupiedPath: '/opt/homebrew/bin/licoup',
      );
      final (result, path) = await _controller(port).uninstall();
      expect(result, TerminalCommandActionResult.occupied);
      expect(path, '/opt/homebrew/bin/licoup');
      expect(port.calls, isEmpty);
      expect(port.status, TerminalCommandStatus.occupied);
    });
  });

  group('availability', () {
    test('a client without a bundled binary reports unavailable', () async {
      final port = _FakePort();
      final ctl = TerminalCommandController(
        port: port,
        bundledTarget: () => null,
      );
      expect(ctl.canonicalTarget, isNull);
      final (result, _) = await ctl.install();
      expect(result, TerminalCommandActionResult.unavailable);
      final (uninstallResult, uninstallPath) = await ctl.uninstall();
      expect(uninstallResult, TerminalCommandActionResult.unavailable);
      expect(uninstallPath, isNull);
      expect(port.calls, isEmpty);
    });
  });
}
