import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_json_store.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';

class PlatformMobileAgentAccountStore implements MobileAgentAccountStore {
  const PlatformMobileAgentAccountStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'mobile-agent-accounts.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Object?> read(Object portableData) {
    return _jsonStore.read(portableData, fileName);
  }

  @override
  Future<void> write(Object portableData, Object? payload) {
    return _jsonStore.write(portableData, fileName, payload, lock: true);
  }
}
