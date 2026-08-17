import 'dart:async';

import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

/// Groups of destinations that share one interface-entry refresh cycle.
enum ClientInterfaceEntryGroup { conversation, communication, feature }

ClientInterfaceEntryGroup? clientInterfaceEntryGroupOf(ClientSection section) {
  return switch (section) {
    ClientSection.agents => ClientInterfaceEntryGroup.conversation,
    ClientSection.models ||
    ClientSection.mobileRelay => ClientInterfaceEntryGroup.communication,
    ClientSection.agentHub ||
    ClientSection.skillHub ||
    ClientSection.pluginManagement => ClientInterfaceEntryGroup.feature,
    _ => null,
  };
}

/// One injected local refresh lane for a grouped interface entry.
final class ClientInterfaceEntryHookTask {
  const ClientInterfaceEntryHookTask({
    required this.section,
    required this.action,
  });

  final ClientSection section;
  final Future<void> Function() action;
}

final class _EntryHookLane {
  _EntryHookLane(this.task);

  final ClientInterfaceEntryHookTask task;
  Future<void>? flight;
  RpcPriorityToken? token;
  int requestedCycle = 0;
  int completedCycle = 0;
  bool requestedBackground = true;
  Completer<void>? settle;
}

/// Schedules one grouped refresh cycle for every supported interface entry.
///
/// Fixed task lanes make request, deduplication, and foreground promotion
/// O(1) and keep memory bounded by the declared task set. Entering a group
/// starts the requested child at foreground RPC priority before sibling
/// preloads continue in the background; movement inside an active group only
/// promotes the requested lane; leaving deactivates the group so a later
/// re-entry schedules a fresh cycle. When a lane is requested again while its
/// prior refresh is still running, only the newest requested cycle is
/// remembered and runs once after settlement.
final class ClientInterfaceEntryHookController {
  ClientInterfaceEntryHookController({
    required Map<ClientSection, ClientInterfaceEntryHookTask> tasks,
    required ClientLifecycleReportSink onReport,
  }) : _lanes = {
         for (final task in tasks.values) task.section: _EntryHookLane(task),
       },
       _onReport = onReport;

  final Map<ClientSection, _EntryHookLane> _lanes;
  final ClientLifecycleReportSink _onReport;
  final Map<ClientInterfaceEntryGroup, int> _cycles = {
    for (final group in ClientInterfaceEntryGroup.values) group: 0,
  };
  ClientInterfaceEntryGroup? _activeGroup;
  bool _disposed = false;

  bool get disposed => _disposed;

  /// Routes one resolved interactive selection through the entry Hook
  /// framework. Destinations outside every group deactivate the active slice
  /// and carry no grouped work.
  void requestEntry(ClientSection section) {
    if (_disposed) return;
    final requestedGroup = clientInterfaceEntryGroupOf(section);
    if (requestedGroup == null) {
      _activeGroup = null;
      return;
    }
    if (_activeGroup != requestedGroup) {
      _activateGroup(requestedGroup, section);
      return;
    }
    if (requestedGroup == ClientInterfaceEntryGroup.conversation) {
      // Every conversation-interface entry or re-entry is a new entry.
      _activateGroup(requestedGroup, section);
      return;
    }
    _promote(section);
  }

  /// Completes when the entry task for [section] settles after the most
  /// recent request. Returns immediately when the lane is unknown or no work
  /// is scheduled.
  Future<void> awaitEntry(ClientSection section) {
    if (_disposed) return Future<void>.value();
    final lane = _lanes[section];
    if (lane == null || lane.settle == null) {
      return Future<void>.value();
    }
    return lane.settle!.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeGroup = null;
    for (final lane in _lanes.values) {
      _finishSettle(lane);
    }
  }

  void _activateGroup(
    ClientInterfaceEntryGroup group,
    ClientSection requestedSection,
  ) {
    _activeGroup = group;
    final cycle = _cycles[group] = _cycles[group]! + 1;
    final siblings = <_EntryHookLane>[];
    for (final lane in _lanes.values) {
      if (clientInterfaceEntryGroupOf(lane.task.section) != group) continue;
      lane.requestedCycle = cycle;
      lane.requestedBackground = lane.task.section != requestedSection;
      lane.settle ??= Completer<void>();
      if (lane.task.section == requestedSection) {
        unawaited(_startLane(lane));
      } else {
        siblings.add(lane);
      }
    }
    for (final sibling in siblings) {
      unawaited(_startLane(sibling));
    }
  }

  /// Same-cycle movement: reuse the scheduled task and only raise the
  /// requested lane to foreground priority. A lane that already settled this
  /// cycle must not run again.
  void _promote(ClientSection section) {
    final lane = _lanes[section];
    if (lane == null || lane.completedCycle >= lane.requestedCycle) return;
    lane.requestedBackground = false;
    unawaited(_startLane(lane));
  }

  Future<void> _startLane(_EntryHookLane lane) {
    if (_disposed) return Future<void>.value();
    final active = lane.flight;
    if (active != null) {
      if (!lane.requestedBackground) {
        lane.token?.background = false;
      }
      return active;
    }
    final token = RpcPriorityToken(background: lane.requestedBackground);
    lane.token = token;
    final cycle = lane.requestedCycle;
    final flight = _runLane(lane, cycle);
    lane.flight = flight;
    return flight;
  }

  Future<void> _runLane(_EntryHookLane lane, int cycle) async {
    var runningCycle = cycle;
    while (true) {
      final token = lane.token!;
      try {
        await runWithRpcPriorityToken(token, lane.task.action);
      } on Object {
        if (!_disposed) {
          _onReport(
            ClientLifecycleReport(
              code: 'client_interface_entry_hook_failed',
              stepId:
                  '${clientInterfaceEntryGroupOf(lane.task.section)!.name}.${lane.task.section.name}',
            ),
          );
        }
      }
      if (_disposed) {
        _finishSettle(lane);
        return;
      }
      if (runningCycle > lane.completedCycle) {
        lane.completedCycle = runningCycle;
      }
      if (lane.requestedCycle <= lane.completedCycle) {
        break;
      }
      // Coalesce the newest trailing request into one iterative follow-up.
      // The loop retains no Future chain while repeated re-entry stays busy.
      runningCycle = lane.requestedCycle;
      lane.token = RpcPriorityToken(background: lane.requestedBackground);
    }
    lane.token = null;
    lane.flight = null;
    _finishSettle(lane);
  }

  void _finishSettle(_EntryHookLane lane) {
    final settle = lane.settle;
    if (settle != null && !settle.isCompleted) {
      settle.complete();
    }
    lane.settle = null;
  }
}
