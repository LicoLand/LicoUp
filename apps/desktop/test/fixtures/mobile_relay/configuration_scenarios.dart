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

  test('keeps an empty persisted gateway unconfigured', () {
    final config = MobileRelayConfig.fromJson(const {
      'defaultGatewayUrl': '   ',
      'customGatewayUrl': '',
      'useCustomGateway': false,
    });

    expect(config.defaultGatewayUrl, isEmpty);
    expect(config.effectiveGatewayUrl, isEmpty);
  });

  test('disables stale ephemeral custom relay gateway', () {
    final config = MobileRelayConfig.fromJson(const {
      'defaultGatewayUrl': 'https://relay.example.test',
      'customGatewayUrl': 'https://old-relay.trycloudflare.com/',
      'useCustomGateway': true,
    });

    expect(config.useCustomGateway, isFalse);
    expect(config.customGatewayUrl, isEmpty);
    expect(config.effectiveGatewayUrl, 'https://relay.example.test');

    final copied = config.copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://next-relay.trycloudflare.com/',
    );
    expect(copied.useCustomGateway, isFalse);
    expect(copied.customGatewayUrl, isEmpty);
    expect(copied.effectiveGatewayUrl, 'https://relay.example.test');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayConfigurationScenarios();
}
