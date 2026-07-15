import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_json_store.dart';

class PlatformAgentFeedStore implements AgentFeedStore {
  const PlatformAgentFeedStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'agent-feed-timeline.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Object?> read(Object portableData) {
    return _jsonStore.read(portableData, fileName);
  }

  @override
  Future<void> write(Object portableData, Object? payload) {
    return _jsonStore.write(portableData, fileName, payload);
  }
}
