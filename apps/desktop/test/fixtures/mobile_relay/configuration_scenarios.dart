import 'dart:io';

import 'package:licoup/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:licoup/src/contracts/mobile_home_layout.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void registerMobileRelayConfigurationScenarios() {
  test('mobile home layout persists through platform storage', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-home-layout-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    const service = MobileHomeLayoutService(
      store: PlatformMobileHomeLayoutStore(),
    );

    await service.save(
      portableData,
      const MobileHomeLayout(
        order: ['target:codex', 'device:desktop'],
        pinnedEntryIds: {'target:codex'},
      ),
    );

    final loaded = await service.load(portableData);

    expect(loaded.order, ['target:codex', 'device:desktop']);
    expect(loaded.pinnedEntryIds, {'target:codex'});
  });

  test('keeps an empty persisted station unconfigured', () {
    final config = MobileRelayConfig.fromJson(const {'stationBaseUrl': '   '});

    expect(config.stationBaseUrl, isEmpty);
  });

  test('canonicalizes the single station base URL', () {
    final config = MobileRelayConfig.fromJson(const {
      'stationBaseUrl': 'HTTPS://Station.Example.Test:443/',
    });

    expect(config.stationBaseUrl, 'https://station.example.test');

    final copied = config.copyWith(stationBaseUrl: 'http://127.0.0.1:8787/');
    expect(copied.stationBaseUrl, 'http://127.0.0.1:8787');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayConfigurationScenarios();
}
