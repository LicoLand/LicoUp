import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/devices/devices_controller.dart';
import 'package:licoup/src/backend/features/devices/devices_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/devices/devices_models.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/devices/devices_projection_producer.dart';

import 'support/fake_devices_cli.dart';

final class _Timers {
  final List<(Duration, void Function())> scheduled = [];

  Timer create(Duration delay, void Function() callback) {
    scheduled.add((delay, callback));
    return Timer(const Duration(days: 365), () {});
  }

  void fireLast() => scheduled.removeLast().$2();
}

void main() {
  late FakeDevicesCli cli;
  late FakeDevicesNoticeRepository notice;
  late _Timers timers;
  late List<String> clipboard;
  late DevicesController controller;

  DevicesController build({bool clipboardWorks = true}) {
    final value = DevicesController(
      service: DevicesService(runner: cli),
      noticeRepository: notice,
      writeClipboard: (text) async {
        if (!clipboardWorks) return false;
        clipboard.add(text);
        return true;
      },
      createTimer: timers.create,
      newIntentId: () => 'intent-1',
    );
    addTearDown(value.dispose);
    return value;
  }

  setUp(() {
    cli = FakeDevicesCli();
    notice = FakeDevicesNoticeRepository();
    timers = _Timers();
    clipboard = [];
    controller = build();
  });

  test(
    'status projects an unenrolled device before and after loading',
    () async {
      expect(devicesProjectionOf(controller).phase, PresentationPhase.idle);
      expect(await controller.refresh(), isTrue);
      final projection = devicesProjectionOf(controller);
      expect(projection.phase, PresentationPhase.ready);
      expect(projection.enrolled, isFalse);
      expect(projection.station, isEmpty);
      expect(cli.callsOf('status'), 1);
      expect(cli.callsOf('message results'), 0);
    },
  );

  test('enrollment validates its input before calling the CLI', () async {
    expect(
      await controller.enroll(station: 'http://plain.example', invitation: 'x'),
      isFalse,
    );
    expect(controller.errorCode, 'devices_station_invalid');
    expect(
      await controller.enroll(station: 'https://s.example', invitation: ' '),
      isFalse,
    );
    expect(controller.errorCode, 'devices_invitation_required');
    expect(cli.calls, isEmpty);

    expect(
      await controller.enroll(
        station: ' https://station.example.test ',
        invitation: 'btm1.synthetic',
      ),
      isTrue,
    );
    expect(cli.calls.first, ['devices', 'enroll', '--stdin-json', 'true']);
    expect(cli.stdinPayloads.single, {
      'station': 'https://station.example.test',
      'invitation': 'btm1.synthetic',
      'ca': null,
    });
    expect(controller.status.enrolled, isTrue);
    expect(controller.errorCode, isEmpty);
  });

  test('enrollment forwards an optional CA PEM', () async {
    await controller.enroll(
      station: 'https://station.example.test',
      invitation: 'btm1.synthetic',
      caPem: '-----BEGIN CERTIFICATE-----\nsynthetic\n',
    );
    expect(
      cli.stdinPayloads.single['ca'],
      '-----BEGIN CERTIFICATE-----\nsynthetic',
    );
  });

  test(
    'offering a pairing shows the code, copies it and watches progress',
    () async {
      cli.enrolled = true;
      expect(await controller.offerPairing(label: 'Studio'), isTrue);
      expect(cli.calls.first, [
        'devices',
        'pair',
        'offer',
        '--label',
        'Studio',
      ]);
      final projection = devicesProjectionOf(controller);
      expect(projection.offerCode, 'code-pair-offer-1');
      expect(
        projection.pairings.single.state,
        DevicePairingStateView.awaitingClaim,
      );
      expect(projection.pairings.single.role, DevicePairingRoleView.offerer);

      expect(await controller.copyPairingCode(), isTrue);
      expect(clipboard, ['code-pair-offer-1']);

      // A pending pairing re-reads the CLI state after the progress interval.
      expect(timers.scheduled.single.$1, controller.progressInterval);
      cli.pairings.single['state'] = 'completed';
      cli.peers.add(FakeDevicesCli.peer('peer-1', 'Studio'));
      timers.fireLast();
      await pumpEventQueue();
      expect(controller.status.peers.single.peerId, 'peer-1');
      expect(
        controller.offer,
        isNull,
        reason: 'a completed offer is no longer shown',
      );
      expect(timers.scheduled, isEmpty, reason: 'nothing is pending any more');
    },
  );

  test('a pairing code copy failure is reported', () async {
    controller = build(clipboardWorks: false);
    cli.enrolled = true;
    await controller.offerPairing();
    expect(await controller.copyPairingCode(), isFalse);
  });

  test('claiming requires a code and sends it on stdin', () async {
    cli.enrolled = true;
    expect(await controller.claimPairing(code: ' '), isFalse);
    expect(controller.errorCode, 'devices_pairing_code_required');
    expect(
      await controller.claimPairing(code: ' lap1.code ', label: 'Air'),
      isTrue,
    );
    expect(cli.calls.first, [
      'devices',
      'pair',
      'claim',
      '--stdin-json',
      'true',
    ]);
    expect(cli.stdinPayloads.single, {'code': 'lap1.code', 'label': 'Air'});
    expect(
      devicesProjectionOf(controller).pairings.single.state,
      DevicePairingStateView.awaitingReply,
    );
  });

  test('cancelling a pairing clears its offered code', () async {
    cli.enrolled = true;
    await controller.offerPairing();
    expect(await controller.cancelPairing('pair-offer-1'), isTrue);
    expect(
      cli.calls,
      anyElement(
        equals(['devices', 'pair', 'cancel', '--pairing-id', 'pair-offer-1']),
      ),
    );
    expect(controller.offer, isNull);
    expect(controller.status.pairings, isEmpty);
  });

  test('unpairing removes the peer', () async {
    cli
      ..enrolled = true
      ..peers.add(FakeDevicesCli.peer('peer-1', 'Studio'));
    await controller.refresh();
    expect(await controller.unpair('peer-1'), isTrue);
    expect(
      cli.calls,
      anyElement(equals(['devices', 'unpair', '--peer-id', 'peer-1'])),
    );
    expect(controller.status.peers, isEmpty);
  });

  test('sending a message waits for its result and then projects it', () async {
    cli
      ..enrolled = true
      ..peers.add(FakeDevicesCli.peer('peer-1', 'Studio'));
    await controller.refresh();
    expect(
      await controller.sendMessage(peerId: 'peer-1', agent: ' ', body: 'hi'),
      isFalse,
    );
    expect(controller.errorCode, 'devices_message_agent_required');
    expect(
      await controller.sendMessage(peerId: 'peer-1', agent: 'codex', body: ' '),
      isFalse,
    );
    expect(controller.errorCode, 'devices_message_body_required');
    expect(
      await controller.sendMessage(
        peerId: 'unknown',
        agent: 'codex',
        body: 'hi',
      ),
      isFalse,
    );
    expect(controller.errorCode, 'devices_peer_required');

    expect(
      await controller.sendMessage(
        peerId: 'peer-1',
        agent: 'codex',
        body: 'hi',
      ),
      isTrue,
    );
    expect(cli.calls.last, ['devices', 'message', 'results']);
    expect(cli.calls.firstWhere((call) => call.contains('send')), [
      'devices',
      'message',
      'send',
      '--peer-id',
      'peer-1',
      '--agent',
      'codex',
      '--stdin-json',
      'true',
    ]);
    expect(cli.stdinPayloads.single, {
      'body': 'hi',
      'clientIntentId': 'intent-1',
    });
    expect(devicesProjectionOf(controller).outstandingMessageCount, 1);
    expect(timers.scheduled, hasLength(1));

    cli.results.add(
      FakeDevicesCli.result(
        'cmd-1',
        'peer-1',
        output: const {'text': 'done on Studio'},
      ),
    );
    timers.fireLast();
    await pumpEventQueue();
    final projection = devicesProjectionOf(controller);
    expect(projection.outstandingMessageCount, 0);
    expect(projection.results.single.outputText, 'done on Studio');
    expect(projection.results.single.completed, isTrue);
    expect(timers.scheduled, isEmpty);
  });

  test('a failed result without reply text shows its output object', () async {
    cli
      ..enrolled = true
      ..peers.add(FakeDevicesCli.peer('peer-1', 'Studio'))
      ..results.add(
        FakeDevicesCli.result(
          'cmd-9',
          'peer-1',
          status: 'failed',
          output: const {'code': 'agent_not_installed'},
        ),
      );
    await controller.refresh();
    final result = devicesProjectionOf(controller).results.single;
    expect(result.completed, isFalse);
    expect(result.outputText, contains('"code": "agent_not_installed"'));
  });

  test('CLI failures surface their stable code', () async {
    cli
      ..enrolled = true
      ..failures['pair claim'] = 'devices_pairing_code_invalid';
    expect(await controller.claimPairing(code: 'bad'), isFalse);
    expect(controller.errorCode, 'devices_pairing_code_invalid');
    expect(await controller.refresh(), isTrue);
    expect(controller.errorCode, isEmpty);
  });

  test('a malformed status answer fails closed', () async {
    final service = DevicesService(runner: _MalformedRunner());
    await expectLater(
      service.status(),
      throwsA(
        isA<FormatException>().having(
          (failure) => failure.message,
          'message',
          'devices_status_invalid',
        ),
      ),
    );
  });

  test(
    'the legacy pairing notice shows once and its dismissal persists',
    () async {
      cli.legacyPairingsDetected = true;
      await controller.loadNoticeAcknowledgement();
      await controller.refresh();
      expect(devicesProjectionOf(controller).showLegacyPairingNotice, isTrue);

      await controller.acknowledgeLegacyPairingNotice();
      expect(devicesProjectionOf(controller).showLegacyPairingNotice, isFalse);
      expect(notice.writes, 1);

      final restarted = build();
      await restarted.loadNoticeAcknowledgement();
      await restarted.refresh();
      expect(restarted.showLegacyPairingNotice, isFalse);
    },
  );

  test(
    'an unreadable notice record is preserved and the dismissal stays in memory',
    () async {
      notice.unreadable = true;
      cli.legacyPairingsDetected = true;
      await controller.loadNoticeAcknowledgement();
      await controller.refresh();
      expect(controller.showLegacyPairingNotice, isTrue);
      await controller.acknowledgeLegacyPairingNotice();
      expect(controller.showLegacyPairingNotice, isFalse);
      expect(notice.writes, 0);
    },
  );

  test('device models parse the C2 status shape', () {
    final status = DevicesStatus.fromJson({
      'ok': true,
      'enrolled': true,
      'legacyPairingsDetected': true,
      'station': 'https://station.example.test',
      'mailboxId': 'abcd',
      'peers': [FakeDevicesCli.peer('peer-1', 'Studio')],
      'pairings': [FakeDevicesCli.pairing('p-1', 'claimer', 'failed')],
    });
    expect(status.legacyPairingsDetected, isTrue);
    expect(status.peers.single.label, 'Studio');
    expect(status.pairings.single.state, DevicePairingState.failed);
    expect(status.hasPendingPairing, isFalse);
    expect(
      () => DevicesStatus.fromJson({
        'ok': true,
        'enrolled': true,
        'pairings': [FakeDevicesCli.pairing('p-1', 'claimer', 'unknown')],
      }),
      throwsFormatException,
    );
  });
}

final class _MalformedRunner implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => {'ok': true};

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
