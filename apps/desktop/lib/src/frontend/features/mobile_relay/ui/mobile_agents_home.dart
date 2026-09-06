import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_add_agent.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list_items.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_local_agent.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_pair_device_scanner.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_surface_gestures.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

enum _MobileAgentSurface { list, desktopAgents, conversation, configuration }

class MobileAgentsHome extends StatefulWidget {
  const MobileAgentsHome({
    super.key,
    required this.agents,
    required this.relay,
    required this.conversationContentBuilder,
    required this.configurationContentBuilder,
    this.iconBuilder,
  });

  final AgentsBinding agents;
  final MobileRelayBinding relay;
  final MobileAgentContentBuilder conversationContentBuilder;
  final MobileAgentContentBuilder configurationContentBuilder;
  final MobileAgentIconBuilder? iconBuilder;

  @override
  State<MobileAgentsHome> createState() => MobileAgentsHomeState();
}

class MobileAgentsHomeState extends State<MobileAgentsHome> {
  static const double _swipeDistanceThreshold = 74;
  static const double _swipeVelocityThreshold = 300;

  _MobileAgentSurface _surface = _MobileAgentSurface.list;
  double _horizontalDragDelta = 0;
  bool _initialScanQueued = false;
  bool _peerScanQueued = false;
  String _activeDesktopDeviceId = '';
  String _activeAgentId = '';
  String _pendingScanAfterPeerId = '';

  @override
  void initState() {
    super.initState();
    _queueInitialScan();
  }

  @override
  void didUpdateWidget(covariant MobileAgentsHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.agents, widget.agents) ||
        !identical(oldWidget.relay, widget.relay)) {
      _initialScanQueued = false;
      _peerScanQueued = false;
      _activeDesktopDeviceId = '';
      _activeAgentId = '';
      _pendingScanAfterPeerId = '';
      _surface = _MobileAgentSurface.list;
      _queueInitialScan();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<AgentsProjection, AgentsProjection>(
      source: widget.agents.projection,
      select: (projection) => projection,
      builder: (context, agents) {
        return ProjectionBuilder<MobileRelayProjection, MobileRelayProjection>(
          source: widget.relay.projection,
          select: (projection) => projection,
          builder: (context, relay) => _buildProjection(context, agents, relay),
        );
      },
    );
  }

  Widget _buildProjection(
    BuildContext context,
    AgentsProjection agents,
    MobileRelayProjection relay,
  ) {
    _queuePeerScanWhenSelected(agents, relay);
    final targets = agents.targets;
    final activeTarget = _activeTarget(agents);
    final activeDevice = _activeDesktopDevice(relay);
    final scanning =
        agents.phase == PresentationPhase.loading ||
        agents.phase == PresentationPhase.applying;
    Widget list() => MobileAgentList(
      agents: agents,
      relay: relay,
      agentIntents: widget.agents.intents,
      relayIntents: widget.relay.intents,
      onSelect: _openConversation,
      onSelectDevice: _openPairedDevice,
      onAddAgent: _showAddAgentSheet,
      iconBuilder: widget.iconBuilder,
    );
    if (_surface == _MobileAgentSurface.desktopAgents && activeDevice != null) {
      return SwipeableMobileAgentSurface(
        onSwipeRight: _showList,
        onSwipeLeft: null,
        onDragStart: _resetHorizontalDrag,
        onDragUpdate: _accumulateHorizontalDrag,
        onDragEnd: _completeHorizontalDrag,
        onDragCancel: _resetHorizontalDrag,
        child: MobileDesktopAgentList(
          device: activeDevice,
          targets: targets,
          scanning: scanning,
          onBack: _showList,
          onRefresh: _scanAgents,
          onSelect: _openDesktopAgentConversation,
          iconBuilder: widget.iconBuilder,
        ),
      );
    }
    if (activeTarget == null) return list();
    return switch (_surface) {
      _MobileAgentSurface.list => list(),
      _MobileAgentSurface.desktopAgents =>
        activeDevice == null
            ? list()
            : MobileDesktopAgentList(
                device: activeDevice,
                targets: targets,
                scanning: scanning,
                onBack: _showList,
                onRefresh: _scanAgents,
                onSelect: _openDesktopAgentConversation,
                iconBuilder: widget.iconBuilder,
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
          target: activeTarget,
          contentBuilder: widget.conversationContentBuilder,
          onBack: _activeDesktopDeviceId.trim().isNotEmpty
              ? _showDesktopAgents
              : _showList,
          onConfiguration: _showConfiguration,
          iconBuilder: widget.iconBuilder,
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
          target: activeTarget,
          contentBuilder: widget.configurationContentBuilder,
          onBack: _showConversation,
          iconBuilder: widget.iconBuilder,
        ),
      ),
    };
  }

  void _queueInitialScan() {
    if (_initialScanQueued) return;
    _initialScanQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final projection = widget.agents.projection.current;
      final scanning =
          projection.phase == PresentationPhase.loading ||
          projection.phase == PresentationPhase.applying;
      if (projection.targets.isEmpty && !scanning) _scanAgents();
    });
  }

  void _queuePeerScanWhenSelected(
    AgentsProjection agents,
    MobileRelayProjection relay,
  ) {
    final pending = _pendingScanAfterPeerId;
    if (pending.isEmpty || _peerScanQueued) return;
    final selected = relay.peers.any(
      (peer) =>
          peer.selected && (peer.id == pending || peer.pairingId == pending),
    );
    if (!selected) return;
    _peerScanQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingScanAfterPeerId = '';
      _peerScanQueued = false;
      if (widget.agents.projection.current.targets.isEmpty) _scanAgents();
    });
  }

  AgentTargetProjection? _activeTarget(AgentsProjection projection) {
    final selected = _activeAgentId.trim().isNotEmpty
        ? _activeAgentId
        : projection.selectedAgentId;
    for (final target in projection.targets) {
      if (target.id == selected) return target;
    }
    return null;
  }

  RelayPeerProjection? _activeDesktopDevice(MobileRelayProjection projection) {
    final selected = _activeDesktopDeviceId.trim();
    for (final device in projection.peers) {
      if (device.id == selected || device.pairingId == selected) return device;
    }
    for (final device in projection.peers) {
      if (device.selected) return device;
    }
    return projection.peers.isEmpty ? null : projection.peers.first;
  }

  void _scanAgents() => widget.agents.intents.send(const ScanAgents());

  void _openConversation(AgentTargetProjection target) {
    setState(() {
      _activeDesktopDeviceId = '';
      _activeAgentId = target.id;
      _surface = _MobileAgentSurface.conversation;
    });
    widget.agents.intents.send(SelectAgent(target.id));
  }

  void _openDesktopAgentConversation(AgentTargetProjection target) {
    setState(() {
      _activeAgentId = target.id;
      _surface = _MobileAgentSurface.conversation;
    });
    widget.agents.intents.send(SelectAgent(target.id));
  }

  void _openPairedDevice(RelayPeerProjection device) {
    setState(() {
      _activeDesktopDeviceId = device.id;
      _pendingScanAfterPeerId = device.id;
      _peerScanQueued = false;
      _surface = _MobileAgentSurface.desktopAgents;
    });
    widget.relay.intents.send(SelectRelayPeer(device.id));
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
      barrierDismissible: !widget.relay.projection.current.busy,
      builder: (context) => PairDeviceDialog(
        binding: widget.relay,
        scannerPreviewBuilder:
            defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS
            ? (context, onDetect) => MobilePairDeviceScanner(onDetect: onDetect)
            : null,
      ),
    );
  }

  void _showList() {
    if (_surface == _MobileAgentSurface.list) return;
    setState(() => _surface = _MobileAgentSurface.list);
  }

  /// Resets the agents home back to the main conversation list.
  void resetToList() {
    if (_surface == _MobileAgentSurface.list &&
        _activeDesktopDeviceId.trim().isEmpty) {
      return;
    }
    setState(() {
      _activeDesktopDeviceId = '';
      _activeAgentId = '';
      _pendingScanAfterPeerId = '';
      _surface = _MobileAgentSurface.list;
    });
  }

  void _showDesktopAgents() {
    if (_surface == _MobileAgentSurface.desktopAgents) return;
    setState(() => _surface = _MobileAgentSurface.desktopAgents);
  }

  void _showConversation() {
    if (_surface == _MobileAgentSurface.conversation) return;
    setState(() => _surface = _MobileAgentSurface.conversation);
  }

  void _showConfiguration() {
    if (_surface == _MobileAgentSurface.configuration) return;
    setState(() => _surface = _MobileAgentSurface.configuration);
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
    if (velocity.abs() >= _swipeVelocityThreshold) return velocity > 0 ? 1 : -1;
    if (distance.abs() >= _swipeDistanceThreshold) return distance > 0 ? 1 : -1;
    return 0;
  }
}
