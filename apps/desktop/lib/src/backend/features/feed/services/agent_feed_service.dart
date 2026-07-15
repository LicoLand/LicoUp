import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';

class AgentFeedService {
  const AgentFeedService({required AgentFeedStore store}) : _store = store;

  final AgentFeedStore _store;

  Future<AgentFeedTimeline> load(Object portableData) async {
    try {
      final json = await _store.read(portableData);
      if (json is! Map) {
        return AgentFeedTimeline.defaults();
      }
      final document = Map<String, dynamic>.from(json);
      final timeline = AgentFeedTimeline.fromJson(document);
      final schemaVersion = int.tryParse(
        document['schemaVersion']?.toString() ?? '',
      );
      final interruptedDispatchPresent =
          document['dispatchOutcomes'] is List &&
          (document['dispatchOutcomes'] as List).whereType<Map>().any(
            (outcome) => outcome['status']?.toString() == 'running',
          );
      if (schemaVersion != AgentFeedTimeline.currentSchemaVersion ||
          interruptedDispatchPresent) {
        await save(portableData, timeline);
      }
      return timeline;
    } catch (_) {
      return AgentFeedTimeline.defaults();
    }
  }

  Future<void> save(Object portableData, AgentFeedTimeline timeline) async {
    await _store.write(portableData, timeline.toJson());
  }
}
