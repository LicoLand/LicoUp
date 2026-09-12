import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/platform/layout/dashboard_feature_order_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  late Directory tempDir;
  late PortableDataRoot portableData;
  late PlatformDashboardFeatureOrderStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'dashboard_feature_order_test',
    );
    portableData = PortableDataRoot(dataDirectoryOverride: tempDir);
    store = const PlatformDashboardFeatureOrderStore();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('first run yields the four-entry default order', () async {
    expect(await store.load(portableData), [
      'agentHub',
      'modelGateway',
      'mobilePairing',
      'statsPanel',
    ]);
  });

  test('saved custom order survives a fresh load', () async {
    final custom = ['statsPanel', 'agentHub', 'modelGateway', 'mobilePairing'];
    await store.save(portableData, custom);

    expect(await store.load(portableData), custom);
  });

  test('unknown stored ids are ignored and missing defaults appended', () async {
    final file = File(
      '${tempDir.path}/client-state/dashboard-feature-order.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '{"schemaVersion": 1, "order": ["chatChannels", "retroPane", "agentHub",'
      ' "agentHub", " "]}',
    );

    expect(await store.load(portableData), [
      'agentHub',
      'modelGateway',
      'mobilePairing',
      'statsPanel',
    ]);
  });

  test('save normalizes unknown ids instead of persisting them', () async {
    await store.save(portableData, ['statsPanel', 'unknownPane']);

    final file = File(
      '${tempDir.path}/client-state/dashboard-feature-order.json',
    );
    final raw = await file.readAsString();
    expect(raw, contains('statsPanel'));
    expect(raw, isNot(contains('unknownPane')));
    // The normalized document still round-trips every default entry.
    expect((await store.load(portableData)).length, 4);
  });

  test('a corrupt document is never projected as absence', () async {
    final file = File(
      '${tempDir.path}/client-state/dashboard-feature-order.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');

    await expectLater(store.load(portableData), throwsFormatException);
  });

  test('a foreign schema version requires startup migration', () async {
    final file = File(
      '${tempDir.path}/client-state/dashboard-feature-order.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('{"schemaVersion": 99, "order": []}');

    await expectLater(store.load(portableData), throwsStateError);
  });
}
