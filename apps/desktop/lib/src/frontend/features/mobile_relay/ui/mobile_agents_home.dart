import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_target.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_add_agent.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_agent_list.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_local_agent.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_surface_gestures.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

enum _MobileAgentSurface { list, desktopAgents, conversation, configuration }

class MobileAgentsHome extends StatefulWidget {
  const MobileAgentsHome({super.key, required this.controller});

  final ClientController controller;

  @override
  State<MobileAgentsHome> createState() => MobileAgentsHomeState();
}

class MobileAgentsHomeState extends State<MobileAgentsHome> {
  static const double _swipeDistanceThreshold = 74;
  static const double _swipeVelocityThreshold = 300;

  _MobileAgentSurface _surface = _MobileAgentSurface.list;
  double _horizontalDragDelta = 0;
  bool _initialScanQueued = false;
  String _activeDesktopDeviceId = '';

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _queueInitialScan();
  }

  @override
  void didUpdateWidget(covariant MobileAgentsHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _initialScanQueued = false;
      _surface = _MobileAgentSurface.list;
      _queueInitialScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final targets = controller
            .orderedConversationTargets(
              controller.scannedTargets.where(
                (target) => target.visibleInClient,
              ),
            )
            .where((target) => !isAgentOrchestrationTargetId(target.target))
            .toList(growable: false);
        final devices = controller.mobileRelayConfig.deviceTabs;
        final activeTarget = _activeTarget(targets);
        final activeDevice = _activeDesktopDevice(devices);
        Widget list() => MobileAgentList(
          controller: controller,
          targets: targets,
          devices: devices,
          onRefresh: controller.scanTargets,
          onSelect: _openConversation,
          onSelectDevice: _openPairedDevice,
          onAddAgent: _showAddAgentSheet,
        );
        if (_surface == _MobileAgentSurface.desktopAgents &&
            activeDevice != null) {
          return SwipeableMobileAgentSurface(
            onSwipeRight: _showList,
            onSwipeLeft: null,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: MobileDesktopAgentList(
              controller: controller,
              device: activeDevice,
              targets: targets,
              onBack: _showList,
              onRefresh: controller.scanTargets,
              onSelect: _openDesktopAgentConversation,
            ),
          );
        }
        if (activeTarget == null) {
          return list();
        }
        return switch (_surface) {
          _MobileAgentSurface.list => list(),
          _MobileAgentSurface.desktopAgents =>
            activeDevice == null
                ? list()
                : MobileDesktopAgentList(
                    controller: controller,
                    device: activeDevice,
                    targets: targets,
                    onBack: _showList,
                    onRefresh: controller.scanTargets,
                    onSelect: _openDesktopAgentConversation,
                  ),
          _MobileAgentSurface.conversation => SwipeableMobileAgentSurface(
            onSwipeRight: _activeDesktopDeviceId.trim().isNotEmpty
                ? _showDesktopAgents
                : _showList,
            onSwipeLeft: _showConfiguration,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: MobileAgentConversation(
              controller: controller,
              targets: targets,
              target: activeTarget,
              onBack: _activeDesktopDeviceId.trim().isNotEmpty
                  ? _showDesktopAgents
                  : _showList,
              onConfiguration: _showConfiguration,
            ),
          ),
          _MobileAgentSurface.configuration => SwipeableMobileAgentSurface(
            onSwipeRight: _showConversation,
            onSwipeLeft: null,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: MobileAgentConfiguration(
              controller: controller,
              target: activeTarget,
              onBack: _showConversation,
            ),
          ),
        };
      },
    );
  }

  void _queueInitialScan() {
    if (_initialScanQueued) {
      return;
    }
    _initialScanQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          controller.scannedTargets.isNotEmpty ||
          controller.isScanningTargets) {
        return;
      }
      unawaited(controller.scanTargets());
    });
  }

  TargetCandidate? _activeTarget(List<TargetCandidate> targets) {
    final selected = controller.selectedConversationAgentId;
    for (final target in targets) {
      if (target.target == selected) {
        return target;
      }
    }
    return null;
  }

  MobileRelayPairedDevice? _activeDesktopDevice(
    List<MobileRelayPairedDevice> devices,
  ) {
    final selected = _activeDesktopDeviceId.trim();
    for (final device in devices) {
      if (device.id == selected || device.pairingId == selected) {
        return device;
      }
    }
    final currentPairing = controller.mobileRelayConfig.pairingId.trim();
    if (currentPairing.isNotEmpty) {
      for (final device in devices) {
        if (device.pairingId == currentPairing) {
          return device;
        }
      }
    }
    return devices.isEmpty ? null : devices.first;
  }

  void _openConversation(TargetCandidate target) {
    setState(() {
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.conversation;
    });
    unawaited(controller.selectConversationAgent(target.target));
  }

  void _openDesktopAgentConversation(TargetCandidate target) {
    setState(() {
      _surface = _MobileAgentSurface.conversation;
    });
    unawaited(controller.selectConversationAgent(target.target));
  }

  void _openPairedDevice(MobileRelayPairedDevice device) {
    setState(() {
      _activeDesktopDeviceId = device.id;
      _surface = _MobileAgentSurface.desktopAgents;
    });
    unawaited(() async {
      await controller.selectMobileRelayDevice(device.id);
      if (controller.scannedTargets.isEmpty) {
        await controller.scanTargets();
      }
    }());
  }

  Future<void> _showAddAgentSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.licoColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) =>
          MobileAddAgentSheet(onScanQr: _showMobilePairingDialog),
    );
  }

  Future<void> _showMobilePairingDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: !controller.isMobileRelayBusy,
      builder: (context) => PairDeviceDialog(onClaim: _claimMobilePairingText),
    );
  }

  Future<void> _claimMobilePairingText(String value) async {
    if (value.trim().isEmpty) {
      return;
    }
    await controller.claimMobilePairingInvite(value);
    if (controller.lastError.trim().isNotEmpty) {
      throw StateError(controller.lastError);
    }
  }

  void _showList() {
    if (_surface == _MobileAgentSurface.list) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.list;
    });
  }

  /// Resets the agents home back to the main conversation list.
  ///
  /// This is invoked when the active semantic Agents destination is selected
  /// again by the current layout profile.
  void resetToList() {
    if (_surface == _MobileAgentSurface.list &&
        _activeDesktopDeviceId.trim().isEmpty) {
      return;
    }
    setState(() {
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.list;
    });
  }

  void _showDesktopAgents() {
    if (_surface == _MobileAgentSurface.desktopAgents) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.desktopAgents;
    });
  }

  void _showConversation() {
    if (_surface == _MobileAgentSurface.conversation) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.conversation;
    });
  }

  void _showConfiguration() {
    if (_surface == _MobileAgentSurface.configuration) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.configuration;
    });
  }

  void _resetHorizontalDrag([DragStartDetails? _]) {
    _horizontalDragDelta = 0;
  }

  void _accumulateHorizontalDrag(DragUpdateDetails details) {
    _horizontalDragDelta += details.primaryDelta ?? details.delta.dx;
  }

  void _completeHorizontalDrag(
    DragEndDetails details,
    VoidCallback onSwipeRight,
    VoidCallback? onSwipeLeft,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final direction = _horizontalSwipeDirection(
      distance: _horizontalDragDelta,
      velocity: velocity,
    );
    _horizontalDragDelta = 0;
    if (direction > 0) {
      onSwipeRight();
    } else if (direction < 0) {
      onSwipeLeft?.call();
    }
  }

  int _horizontalSwipeDirection({
    required double distance,
    required double velocity,
  }) {
    if (velocity.abs() >= _swipeVelocityThreshold) {
      return velocity > 0 ? 1 : -1;
    }
    if (distance.abs() >= _swipeDistanceThreshold) {
      return distance > 0 ? 1 : -1;
    }
    return 0;
  }
}
