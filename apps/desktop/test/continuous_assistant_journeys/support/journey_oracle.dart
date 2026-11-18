/// Burden and association oracles derived from the actual bridge trajectory.
///
/// Counts come from dispatched requests and submitted composer posts, not from
/// reset-to-zero placeholders. No raw prompt or runtime payload is printed.
final class JourneyOracle {
  JourneyOracle._();

  static const forcedCreateActions = <String>{
    'conversation.create',
    'conversation.group.create',
  };

  static const modeOrAgentSwitchActions = <String>{
    'conversation.assistant.set',
    'conversation.membership.add',
    'conversation.membership.leave',
    'conversation.strategy.set',
  };

  static const reExplanationTexts = <String>{'delegate notes A', 'discuss B'};

  /// Sidebar create is a host callback, not a bridge action.
  static var sidebarCreateTaps = 0;

  static void reset() {
    sidebarCreateTaps = 0;
  }

  static List<String> actions(JourneyBridgeTrajectory trajectory) {
    return [
      for (final request in trajectory.requests)
        if ((request['action'] ?? '').toString().isNotEmpty)
          (request['action'] ?? '').toString(),
    ];
  }

  static int countAction(JourneyBridgeTrajectory trajectory, String action) {
    return actions(trajectory).where((item) => item == action).length;
  }

  static int postedMessageCount(JourneyBridgeTrajectory trajectory) {
    return countAction(trajectory, 'conversation.message.post');
  }

  static int afterPostCount(JourneyBridgeTrajectory trajectory) {
    return countAction(trajectory, 'conversation.dispatch.after-post');
  }

  static int forcedCreateCount(JourneyBridgeTrajectory trajectory) {
    return sidebarCreateTaps +
        trajectory.requests.where((request) {
          return forcedCreateActions.contains(
            (request['action'] ?? '').toString(),
          );
        }).length;
  }

  static int modeSwitchCount(JourneyBridgeTrajectory trajectory) {
    return trajectory.requests.where((request) {
      return modeOrAgentSwitchActions.contains(
        (request['action'] ?? '').toString(),
      );
    }).length;
  }

  static int reExplanationCount(JourneyBridgeTrajectory trajectory) {
    return postedContents(trajectory).where((content) {
      return reExplanationTexts.any(content.contains);
    }).length;
  }

  static List<String> postedContents(JourneyBridgeTrajectory trajectory) {
    return [
      for (final request in trajectory.requests)
        if ((request['action'] ?? '').toString() == 'conversation.message.post')
          (request['content'] ?? '').toString(),
    ];
  }

  static List<Map<String, String>> postedAssociations(
    JourneyBridgeTrajectory trajectory,
  ) {
    return trajectory.associations;
  }
}

/// Request and association surface the bridge already recorded.
abstract interface class JourneyBridgeTrajectory {
  List<Map<String, dynamic>> get requests;
  List<Map<String, String>> get associations;
}
