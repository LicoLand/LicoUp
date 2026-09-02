import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';
import 'package:licoup/src/contracts/mobile_home_layout.dart';

class PlatformMobileHomeLayoutStore implements MobileHomeLayoutStore {
  const PlatformMobileHomeLayoutStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'mobile-home-layout.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Object?> read(Object portableData) {
    return _jsonStore.readCurrent(portableData, fileName);
  }

  @override
  Future<void> write(Object portableData, Object? payload) {
    return _jsonStore.write(portableData, fileName, payload);
  }
}
