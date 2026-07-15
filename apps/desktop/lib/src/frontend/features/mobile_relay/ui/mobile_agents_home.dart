import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_provider_conversation.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';
import 'package:flutter_client/src/frontend/shared/ui/provider_brand_icon.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

enum _MobileAgentSurface {
  list,
  desktopAgents,
  conversation,
  configuration,
  remoteSessionList,
  remoteConversation,
  remoteConfiguration,
  remoteTrash,
}

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
  String _activeRemoteAccountId = '';
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
        final accounts = controller.mobileAgentAccounts;
        final devices = controller.mobileRelayConfig.deviceTabs;
        final activeTarget = _activeTarget(targets);
        final activeAccount = _activeRemoteAccount(accounts);
        final activeDevice = _activeDesktopDevice(devices);
        Widget list() => _MobileAgentList(
          controller: controller,
          targets: targets,
          accounts: accounts,
          devices: devices,
          onRefresh: controller.scanTargets,
          onSelect: _openConversation,
          onSelectAccount: _openRemoteAccount,
          onSelectDevice: _openPairedDevice,
          onAddAgent: _showAddAgentSheet,
        );
        if (_surface == _MobileAgentSurface.desktopAgents &&
            activeDevice != null) {
          return _SwipeableMobileAgentSurface(
            onSwipeRight: _showList,
            onSwipeLeft: null,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: _MobileDesktopAgentList(
              controller: controller,
              device: activeDevice,
              targets: targets,
              onBack: _showList,
              onRefresh: controller.scanTargets,
              onSelect: _openDesktopAgentConversation,
            ),
          );
        }
        if (activeAccount != null) {
          if (_surface == _MobileAgentSurface.remoteSessionList) {
            return _SwipeableMobileAgentSurface(
              onSwipeRight: _showList,
              onSwipeLeft: _showRemoteConfiguration,
              onDragStart: _resetHorizontalDrag,
              onDragUpdate: _accumulateHorizontalDrag,
              onDragEnd: _completeHorizontalDrag,
              onDragCancel: _resetHorizontalDrag,
              child: _MobileRemoteSessionList(
                controller: controller,
                account: activeAccount,
                onBack: _showList,
                onConfiguration: _showRemoteConfiguration,
                onOpenConversation: _openRemoteConversation,
                onNewConversation: _startRemoteConversation,
                onShowTrash: _showRemoteTrash,
              ),
            );
          }
          if (_surface == _MobileAgentSurface.remoteConversation) {
            return _SwipeableMobileAgentSurface(
              onSwipeRight: _showRemoteSessionList,
              onSwipeLeft: _showRemoteConfiguration,
              onDragStart: _resetHorizontalDrag,
              onDragUpdate: _accumulateHorizontalDrag,
              onDragEnd: _completeHorizontalDrag,
              onDragCancel: _resetHorizontalDrag,
              child: _MobileRemoteAgentConversation(
                controller: controller,
                account: activeAccount,
                onBack: _showRemoteSessionList,
                onConfiguration: _showRemoteConfiguration,
                onHandoff: _showRemoteAgentHandoffDialog,
                onOpenWebConversation: (account) => unawaited(
                  controller.openMobileProviderWebConversation(account),
                ),
              ),
            );
          }
          if (_surface == _MobileAgentSurface.remoteConfiguration) {
            return _SwipeableMobileAgentSurface(
              onSwipeRight: _showRemoteSessionList,
              onSwipeLeft: null,
              onDragStart: _resetHorizontalDrag,
              onDragUpdate: _accumulateHorizontalDrag,
              onDragEnd: _completeHorizontalDrag,
              onDragCancel: _resetHorizontalDrag,
              child: _MobileRemoteAgentConfiguration(
                controller: controller,
                account: activeAccount,
                onBack: _showRemoteSessionList,
                onSelectAccount: _openRemoteAccountConfiguration,
                onDeleted: _showList,
              ),
            );
          }
          if (_surface == _MobileAgentSurface.remoteTrash) {
            return _SwipeableMobileAgentSurface(
              onSwipeRight: _showRemoteSessionList,
              onSwipeLeft: null,
              onDragStart: _resetHorizontalDrag,
              onDragUpdate: _accumulateHorizontalDrag,
              onDragEnd: _completeHorizontalDrag,
              onDragCancel: _resetHorizontalDrag,
              child: _MobileRemoteTrashList(
                controller: controller,
                account: activeAccount,
                onBack: _showRemoteSessionList,
              ),
            );
          }
        }
        if (activeTarget == null) {
          return list();
        }
        return switch (_surface) {
          _MobileAgentSurface.list => list(),
          _MobileAgentSurface.desktopAgents =>
            activeDevice == null
                ? list()
                : _MobileDesktopAgentList(
                    controller: controller,
                    device: activeDevice,
                    targets: targets,
                    onBack: _showList,
                    onRefresh: controller.scanTargets,
                    onSelect: _openDesktopAgentConversation,
                  ),
          _MobileAgentSurface.conversation => _SwipeableMobileAgentSurface(
            onSwipeRight: _activeDesktopDeviceId.trim().isNotEmpty
                ? _showDesktopAgents
                : _showList,
            onSwipeLeft: _showConfiguration,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: _MobileAgentConversation(
              controller: controller,
              targets: targets,
              target: activeTarget,
              onBack: _activeDesktopDeviceId.trim().isNotEmpty
                  ? _showDesktopAgents
                  : _showList,
              onConfiguration: _showConfiguration,
            ),
          ),
          _MobileAgentSurface.configuration => _SwipeableMobileAgentSurface(
            onSwipeRight: _showConversation,
            onSwipeLeft: null,
            onDragStart: _resetHorizontalDrag,
            onDragUpdate: _accumulateHorizontalDrag,
            onDragEnd: _completeHorizontalDrag,
            onDragCancel: _resetHorizontalDrag,
            child: _MobileAgentConfiguration(
              controller: controller,
              target: activeTarget,
              onBack: _showConversation,
            ),
          ),
          _MobileAgentSurface.remoteConversation ||
          _MobileAgentSurface.remoteConfiguration ||
          _MobileAgentSurface.remoteSessionList ||
          _MobileAgentSurface.remoteTrash => list(),
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

  MobileAgentAccount? _activeRemoteAccount(List<MobileAgentAccount> accounts) {
    if (_activeRemoteAccountId.trim().isEmpty) {
      return null;
    }
    for (final account in accounts) {
      if (account.id == _activeRemoteAccountId) {
        return account;
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
      _activeRemoteAccountId = '';
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.conversation;
    });
    unawaited(controller.selectConversationAgent(target.target));
  }

  void _openDesktopAgentConversation(TargetCandidate target) {
    setState(() {
      _activeRemoteAccountId = '';
      _surface = _MobileAgentSurface.conversation;
    });
    unawaited(controller.selectConversationAgent(target.target));
  }

  void _openRemoteAccount(MobileAgentAccount account) {
    setState(() {
      _activeRemoteAccountId = account.id;
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.remoteSessionList;
    });
  }

  void _openRemoteAccountConfiguration(MobileAgentAccount account) {
    setState(() {
      _activeRemoteAccountId = account.id;
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.remoteConfiguration;
    });
  }

  void _openRemoteConversation(MobileProviderConversationRecord record) {
    final account = _activeRemoteAccount(controller.mobileAgentAccounts);
    if (account == null) {
      return;
    }
    controller.selectMobileProviderConversation(account, record.session.id);
    setState(() {
      _surface = _MobileAgentSurface.remoteConversation;
    });
  }

  Future<void> _startRemoteConversation() async {
    final account = _activeRemoteAccount(controller.mobileAgentAccounts);
    if (account == null) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.remoteConversation;
    });
    await controller.startMobileProviderConversation(account);
    if (!mounted) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.remoteConversation;
    });
  }

  void _openPairedDevice(MobileRelayPairedDevice device) {
    setState(() {
      _activeRemoteAccountId = '';
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
      builder: (context) => _MobileAddAgentSheet(
        controller: controller,
        onScanQr: _showMobilePairingDialog,
      ),
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
      _activeRemoteAccountId = '';
      _surface = _MobileAgentSurface.list;
    });
  }

  /// Resets the agents home back to the main conversation list.
  ///
  /// This is invoked when the active semantic Agents destination is selected
  /// again by the current layout profile.
  void resetToList() {
    if (_surface == _MobileAgentSurface.list &&
        _activeRemoteAccountId.trim().isEmpty &&
        _activeDesktopDeviceId.trim().isEmpty) {
      return;
    }
    setState(() {
      _activeRemoteAccountId = '';
      _activeDesktopDeviceId = '';
      _surface = _MobileAgentSurface.list;
    });
  }

  void _showDesktopAgents() {
    if (_surface == _MobileAgentSurface.desktopAgents) {
      return;
    }
    setState(() {
      _activeRemoteAccountId = '';
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

  void _showRemoteSessionList() {
    if (_surface == _MobileAgentSurface.remoteSessionList) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.remoteSessionList;
    });
  }

  void _showRemoteTrash() {
    if (_surface == _MobileAgentSurface.remoteTrash) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.remoteTrash;
    });
  }

  void _showRemoteConfiguration() {
    if (_surface == _MobileAgentSurface.remoteConfiguration) {
      return;
    }
    setState(() {
      _surface = _MobileAgentSurface.remoteConfiguration;
    });
  }

  Future<void> _showRemoteAgentHandoffDialog(MobileAgentAccount account) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _MobileConversationHandoffDialog(
        controller: controller,
        account: account,
      ),
    );
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

class _SwipeableMobileAgentSurface extends StatelessWidget {
  const _SwipeableMobileAgentSurface({
    required this.child,
    required this.onSwipeRight,
    required this.onSwipeLeft,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDragCancel,
  });

  final Widget child;
  final VoidCallback onSwipeRight;
  final VoidCallback? onSwipeLeft;
  final ValueChanged<DragStartDetails> onDragStart;
  final ValueChanged<DragUpdateDetails> onDragUpdate;
  final void Function(DragEndDetails, VoidCallback, VoidCallback?) onDragEnd;
  final VoidCallback onDragCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: onDragStart,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: (details) =>
          onDragEnd(details, onSwipeRight, onSwipeLeft),
      onHorizontalDragCancel: onDragCancel,
      child: child,
    );
  }
}

class _MobileAgentList extends StatefulWidget {
  const _MobileAgentList({
    required this.controller,
    required this.targets,
    required this.accounts,
    required this.devices,
    required this.onRefresh,
    required this.onSelect,
    required this.onSelectAccount,
    required this.onSelectDevice,
    required this.onAddAgent,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final List<MobileAgentAccount> accounts;
  final List<MobileRelayPairedDevice> devices;
  final Future<void> Function() onRefresh;
  final ValueChanged<TargetCandidate> onSelect;
  final ValueChanged<MobileAgentAccount> onSelectAccount;
  final ValueChanged<MobileRelayPairedDevice> onSelectDevice;
  final VoidCallback onAddAgent;

  @override
  State<_MobileAgentList> createState() => _MobileAgentListState();
}

class _MobileAgentListState extends State<_MobileAgentList> {
  final Set<String> _selectedAccountIds = {};
  bool _editingProviderAccounts = false;
  bool _deletingProviderAccounts = false;

  @override
  void didUpdateWidget(covariant _MobileAgentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final availableIds = {
      for (final account in widget.accounts)
        if (!account.usesDesktopRelay) account.id,
    };
    _selectedAccountIds.removeWhere((id) => !availableIds.contains(id));
    if (_editingProviderAccounts && availableIds.isEmpty) {
      _editingProviderAccounts = false;
      _selectedAccountIds.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final rootAccounts = widget.controller.mobileClientRuntimePlatform
        ? widget.accounts.where((account) => !account.usesDesktopRelay)
        : widget.accounts;
    final rootTargets =
        widget.controller.mobileClientRuntimePlatform &&
            widget.devices.isNotEmpty
        ? const <TargetCandidate>[]
        : widget.targets;
    final entries = _orderedMobileHomeEntries([
      for (final account in rootAccounts) _remoteAccountEntry(context, account),
      for (final device in widget.devices) _pairedDeviceEntry(context, device),
      for (final target in rootTargets) _localAgentEntry(context, target),
    ], widget.controller.mobileHomeLayout);
    final pinnedCount = entries.where((entry) => entry.pinned).length;
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.agents,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (_editingProviderAccounts) ...[
                    IconButton(
                      key: const Key('mobile-home-delete-selected-providers'),
                      tooltip: strings.delete,
                      onPressed:
                          _selectedAccountIds.isEmpty ||
                              _deletingProviderAccounts
                          ? null
                          : () => unawaited(_deleteSelectedProviderAccounts()),
                      icon: _deletingProviderAccounts
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline_rounded),
                    ),
                    IconButton(
                      key: const Key('mobile-home-exit-provider-edit'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: _deletingProviderAccounts
                          ? null
                          : _exitProviderEditMode,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ] else
                    IconButton(
                      key: const Key('mobile-add-agent-button'),
                      tooltip: strings.addAgent,
                      onPressed: widget.onAddAgent,
                      icon: const Icon(Icons.add_rounded),
                    ),
                ],
              ),
            ),
          ),
          if (entries.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _MobileAgentsEmptyState(
                scanning: widget.controller.isScanningTargets,
                onAddAgent: widget.onAddAgent,
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 14),
              sliver: SliverReorderableList(
                itemCount: entries.length,
                findChildIndexCallback: (key) =>
                    _mobileHomeEntryIndexForKey(entries, key),
                onReorderItem: (oldIndex, newIndex) {
                  if (_editingProviderAccounts) {
                    return;
                  }
                  if (oldIndex >= pinnedCount) {
                    return;
                  }
                  final pinnedIds = [
                    for (final entry in entries)
                      if (entry.pinned) entry.id,
                  ];
                  unawaited(
                    widget.controller.reorderMobileHomePinnedEntries(
                      pinnedIds,
                      oldIndex,
                      newIndex.clamp(0, pinnedCount).toInt(),
                    ),
                  );
                },
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final child = Padding(
                    padding: EdgeInsets.only(
                      bottom: index == entries.length - 1 ? 0 : 2,
                    ),
                    child: entry.child,
                  );
                  final key = ValueKey('mobile-home-entry-${entry.id}');
                  if (!entry.pinned) {
                    return KeyedSubtree(key: key, child: child);
                  }
                  return ReorderableDelayedDragStartListener(
                    key: key,
                    index: index,
                    child: child,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  _MobileHomeEntry _remoteAccountEntry(
    BuildContext context,
    MobileAgentAccount account,
  ) {
    final id = 'account:${account.id}';
    final pinned = widget.controller.mobileHomeLayout.isPinned(id);
    final selectable = !account.usesDesktopRelay;
    final siblingCount = widget.accounts
        .where((candidate) => candidate.providerId == account.providerId)
        .length;
    return _MobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: _mobileAccountSortTime(account),
      child: _MobileRemoteAgentListItem(
        account: account,
        preview: widget.controller.mobileProviderConversationPreview(account),
        entryId: id,
        pinned: pinned,
        editing: _editingProviderAccounts,
        selectable: selectable,
        selected: _selectedAccountIds.contains(account.id),
        siblingAccountCount: siblingCount,
        onLongPress: selectable
            ? () => _enterProviderEditMode(account.id)
            : null,
        onToggleSelected: selectable
            ? () => _toggleAccountSelection(account.id)
            : null,
        onTogglePinned: () =>
            unawaited(widget.controller.toggleMobileHomeEntryPinned(id)),
        onTap: _editingProviderAccounts && selectable
            ? () => _toggleAccountSelection(account.id)
            : () => widget.onSelectAccount(account),
      ),
    );
  }

  _MobileHomeEntry _pairedDeviceEntry(
    BuildContext context,
    MobileRelayPairedDevice device,
  ) {
    final id = 'device:${device.id}';
    final pinned = widget.controller.mobileHomeLayout.isPinned(id);
    return _MobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: 0,
      child: _MobilePairedDeviceListItem(
        device: device,
        active:
            device.pairingId == widget.controller.mobileRelayConfig.pairingId,
        entryId: id,
        pinned: pinned,
        onTogglePinned: () =>
            unawaited(widget.controller.toggleMobileHomeEntryPinned(id)),
        onTap: () => widget.onSelectDevice(device),
      ),
    );
  }

  _MobileHomeEntry _localAgentEntry(
    BuildContext context,
    TargetCandidate target,
  ) {
    final id = 'target:${target.target}';
    final pinned = widget.controller.mobileHomeLayout.isPinned(id);
    final latestSession = _latestMobileHomeSession(
      widget.controller.conversationSessionsByAgent[target.target] ?? const [],
    );
    final fallbackSubtitle = _localAgentFallbackSubtitle(context, target);
    final subtitle = _mobileHomePreviewText(latestSession?.preview).isNotEmpty
        ? _mobileHomePreviewText(latestSession?.preview)
        : fallbackSubtitle;
    return _MobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: latestSession == null
          ? 0
          : _mobileConversationSortTime(latestSession),
      child: _MobileAgentListItem(
        target: target,
        entryId: id,
        subtitle: subtitle,
        pinned: pinned,
        onTogglePinned: () =>
            unawaited(widget.controller.toggleMobileHomeEntryPinned(id)),
        onTap: () => widget.onSelect(target),
      ),
    );
  }

  void _enterProviderEditMode(String accountId) {
    setState(() {
      _editingProviderAccounts = true;
      _selectedAccountIds.add(accountId);
    });
  }

  void _toggleAccountSelection(String accountId) {
    setState(() {
      if (!_selectedAccountIds.add(accountId)) {
        _selectedAccountIds.remove(accountId);
      }
    });
  }

  void _exitProviderEditMode() {
    setState(() {
      _editingProviderAccounts = false;
      _selectedAccountIds.clear();
    });
  }

  Future<void> _deleteSelectedProviderAccounts() async {
    if (_selectedAccountIds.isEmpty || _deletingProviderAccounts) {
      return;
    }
    final ids = Set<String>.from(_selectedAccountIds);
    setState(() {
      _deletingProviderAccounts = true;
    });
    await widget.controller.deleteMobileAgentAccounts(ids);
    if (!mounted) {
      return;
    }
    setState(() {
      _deletingProviderAccounts = false;
      if (widget.controller.lastError.trim().isEmpty) {
        _editingProviderAccounts = false;
        _selectedAccountIds.clear();
      }
    });
  }
}

int? _mobileHomeEntryIndexForKey(List<_MobileHomeEntry> entries, Key key) {
  if (key is! ValueKey<String>) {
    return null;
  }
  const prefix = 'mobile-home-entry-';
  final value = key.value;
  if (!value.startsWith(prefix)) {
    return null;
  }
  final entryId = value.substring(prefix.length);
  final index = entries.indexWhere((entry) => entry.id == entryId);
  return index < 0 ? null : index;
}

class _MobileHomeEntry {
  const _MobileHomeEntry({
    required this.id,
    required this.pinned,
    required this.sortTimeMillis,
    required this.child,
  });

  final String id;
  final bool pinned;
  final int sortTimeMillis;
  final Widget child;
}

List<_MobileHomeEntry> _orderedMobileHomeEntries(
  List<_MobileHomeEntry> entries,
  MobileHomeLayout layout,
) {
  final orderIndex = <String, int>{
    for (var i = 0; i < layout.order.length; i++) layout.order[i]: i,
  };
  final indexed = entries.indexed.toList(growable: false);
  indexed.sort((left, right) {
    final leftPinned = left.$2.pinned ? 0 : 1;
    final rightPinned = right.$2.pinned ? 0 : 1;
    if (leftPinned != rightPinned) {
      return leftPinned.compareTo(rightPinned);
    }
    if (left.$2.pinned) {
      final leftOrder =
          orderIndex[left.$2.id] ?? (layout.order.length + left.$1);
      final rightOrder =
          orderIndex[right.$2.id] ?? (layout.order.length + right.$1);
      return leftOrder.compareTo(rightOrder);
    }
    final timeCompare = right.$2.sortTimeMillis.compareTo(
      left.$2.sortTimeMillis,
    );
    if (timeCompare != 0) {
      return timeCompare;
    }
    return left.$1.compareTo(right.$1);
  });
  return [for (final item in indexed) item.$2];
}

AgentConversationSession? _latestMobileHomeSession(
  List<AgentConversationSession> sessions,
) {
  AgentConversationSession? latest;
  for (final session in sessions) {
    if (latest == null ||
        _mobileConversationSortTime(session) >
            _mobileConversationSortTime(latest)) {
      latest = session;
    }
  }
  return latest;
}

int _mobileConversationSortTime(AgentConversationSession session) {
  return _parseMobileHomeSortTime(session.updatedAt, session.createdAt);
}

int _mobileAccountSortTime(MobileAgentAccount account) {
  return _parseMobileHomeSortTime(account.updatedAt);
}

int _parseMobileHomeSortTime(String primary, [String fallback = '']) {
  final parsedPrimary = DateTime.tryParse(primary);
  final parsedFallback = DateTime.tryParse(fallback);
  return (parsedPrimary ??
          parsedFallback ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
      .toUtc()
      .millisecondsSinceEpoch;
}

String _mobileProviderSessionTimeLabel(
  BuildContext context,
  AgentConversationSession session,
) {
  final updated =
      DateTime.tryParse(session.updatedAt)?.toLocal() ??
      DateTime.tryParse(session.createdAt)?.toLocal();
  if (updated == null) {
    return '';
  }
  final now = DateTime.now();
  final sameDay =
      updated.year == now.year &&
      updated.month == now.month &&
      updated.day == now.day;
  if (sameDay) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(updated),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
  return MaterialLocalizations.of(context).formatShortDate(updated);
}

String _mobileHomePreviewText(String? value) {
  return (value ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _mobileRemoteRelayLabel(
  LicoStrings strings,
  MobileAgentAccount account,
) {
  final label = account.relayDeviceLabel.trim();
  return label.isEmpty ? strings.pairedComputer : label;
}

String _mobileRemoteStatusText(
  LicoStrings strings,
  MobileAgentAccount account,
) {
  if (_mobileRemoteOAuthValidationFailed(account)) {
    return strings.chatValidationFailed;
  }
  if (!account.credentialPresent) {
    return strings.authorizationRequired;
  }
  if (account.usesDesktopRelay) {
    return strings.availableThroughPairedComputer(
      _mobileRemoteRelayLabel(strings, account),
    );
  }
  if (account.usesMobileSynced) {
    return strings.syncedFromPairedComputer(
      _mobileRemoteRelayLabel(strings, account),
    );
  }
  return strings.connected;
}

String _mobileRemoteReadinessText(
  LicoStrings strings,
  MobileAgentAccount account,
) {
  if (account.usesDesktopRelay) {
    return strings.availableThroughPairedComputer(
      _mobileRemoteRelayLabel(strings, account),
    );
  }
  if (account.usesMobileSynced) {
    if (_mobileRemoteUsesOAuthCredential(account)) {
      if (_mobileRemoteOAuthValidationFailed(account)) {
        return strings.oauthChatValidationFailedForProvider(
          account.providerId,
          account.provider.label,
        );
      }
      return strings.oauthReadyForProviderSurface(
        account.providerId,
        account.provider.label,
      );
    }
    return strings.apiKeySyncedReady(_mobileRemoteRelayLabel(strings, account));
  }
  if (_mobileRemoteUsesOAuthCredential(account)) {
    if (_mobileRemoteOAuthValidationFailed(account)) {
      return strings.oauthChatValidationFailedForProvider(
        account.providerId,
        account.provider.label,
      );
    }
    return account.credentialPresent
        ? strings.oauthReadyForProviderSurface(
            account.providerId,
            account.provider.label,
          )
        : strings.oauthClientRequired;
  }
  if (!account.credentialPresent) {
    return strings.authorizationRequired;
  }
  return account.credentialHint.isEmpty
      ? strings.apiKeyReady
      : '${strings.apiKeyReady} (${account.credentialHint})';
}

bool _mobileRemoteOAuthValidationFailed(MobileAgentAccount account) {
  return account.authState.trim().toLowerCase() ==
      MobileAgentAccount.authStateChatValidationFailed;
}

bool _canConfigureMobileRemoteAccount(MobileAgentAccount account) {
  if (account.usesDesktopRelay) {
    return false;
  }
  if (account.usesMobileSynced) {
    return _mobileRemoteCanLaunchLocalOAuth(account);
  }
  return true;
}

bool _mobileRemoteUsesOAuthCredential(MobileAgentAccount account) {
  if (account.authKind == MobileAgentAuthKind.oauthPkce ||
      account.usesLocalOAuth) {
    return true;
  }
  if (account.provider.authKind == MobileAgentAuthKind.oauthPkce) {
    return true;
  }
  final hint = account.credentialHint.trim().toLowerCase();
  final profileId = account.relayProfileId.trim().toLowerCase();
  return hint == 'oauth' || hint == 'oauth-pkce' || profileId.contains('oauth');
}

bool _mobileRemoteCanLaunchLocalOAuth(MobileAgentAccount account) {
  if (account.usesDesktopRelay ||
      !_mobileProviderCanLaunchLocalOAuth(account.provider)) {
    return false;
  }
  if (account.usesMobileSynced) {
    return _mobileRemoteUsesOAuthCredential(account);
  }
  return true;
}

bool _mobileProviderCanLaunchLocalOAuth(MobileAgentProvider provider) {
  return provider.supportsLocalOAuthLogin;
}

String _mobileAccountSourceModeLabel(
  LicoStrings strings,
  MobileAgentAccount account,
) {
  if (account.usesDesktopRelay) {
    return strings.pairedComputerAuthorization;
  }
  if (account.usesMobileSynced) {
    return strings.syncedFromPairedComputer(
      _mobileRemoteRelayLabel(strings, account),
    );
  }
  return account.usesLocalOAuth ||
          account.authKind == MobileAgentAuthKind.oauthPkce
      ? strings.oauthAuthorizationMethodForProvider(
          account.providerId,
          account.provider.label,
        )
      : strings.apiKeyAuthorization;
}

bool _mobileRemoteNeedsOAuthRecovery(
  MobileAgentAccount account,
  AgentConversationSession? session,
) {
  if (!_mobileRemoteUsesOAuthCredential(account)) {
    return false;
  }
  final messages = session?.messages ?? const <AgentConversationMessage>[];
  AgentConversationMessage? latestAssistant;
  for (final message in messages) {
    if (message.role.toLowerCase().trim() == 'assistant') {
      latestAssistant = message;
    }
  }
  final text = latestAssistant?.text.trim().toLowerCase() ?? '';
  if (text.isEmpty || !text.contains('oauth')) {
    return false;
  }
  if (text.contains('oauth_chat_transport_failed')) {
    return false;
  }
  return text.contains('oauth_access_token_missing') ||
      text.contains('oauth_refresh_token_missing') ||
      text.contains('oauth_token_refresh_failed') ||
      text.contains('oauth_token_refresh_incomplete') ||
      text.contains('oauth_credential_unreadable') ||
      text.contains('oauth_chat_failed') ||
      text.contains(' 401') ||
      text.contains('(401') ||
      text.contains(' 403') ||
      text.contains('(403') ||
      text.contains('unauthorized') ||
      text.contains('forbidden');
}

String _localAgentFallbackSubtitle(
  BuildContext context,
  TargetCandidate target,
) {
  final strings = LicoStrings.of(context);
  final configuredLabel = target.configured
      ? strings.configured
      : strings.notConfigured;
  final subtitleParts = [
    configuredLabel,
    if (target.kind.trim().isNotEmpty) target.kind.trim(),
  ];
  return subtitleParts.join(' · ');
}

class _MobileRemoteAgentListItem extends StatelessWidget {
  const _MobileRemoteAgentListItem({
    required this.account,
    required this.preview,
    required this.entryId,
    required this.pinned,
    required this.editing,
    required this.selectable,
    required this.selected,
    required this.onTogglePinned,
    required this.onTap,
    this.siblingAccountCount = 1,
    this.onLongPress,
    this.onToggleSelected,
  });

  final MobileAgentAccount account;
  final String preview;
  final String entryId;
  final bool pinned;
  final bool editing;
  final bool selectable;
  final bool selected;
  final int siblingAccountCount;
  final VoidCallback onTogglePinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final active = account.credentialPresent;
    final siblingCount = siblingAccountCount;
    final sourceLabel = _mobileAccountSourceModeLabel(strings, account);
    final status = account.usesMobileSynced && active
        ? strings.syncedFromPairedComputer(
            _mobileRemoteRelayLabel(strings, account),
          )
        : _mobileRemoteStatusText(strings, account);
    final countSuffix = siblingCount > 1
        ? (strings.isChinese
              ? ' · $siblingCount 个账号'
              : ' · $siblingCount accounts')
        : '';
    final activeMark = account.active
        ? (strings.isChinese ? ' · 当前' : ' · Active')
        : '';
    final normalizedPreview = _mobileHomePreviewText(preview);
    final subtitleBase = normalizedPreview.isNotEmpty
        ? normalizedPreview
        : account.usesMobileSynced && active
        ? sourceLabel
        : '$status · $sourceLabel';
    final subtitle = '$subtitleBase$countSuffix$activeMark';
    return _MobileListTile(
      key: Key('mobile-remote-agent-${account.id}'),
      icon: _providerIcon(
        account.providerId,
        active ? colors.primary : colors.text,
      ),
      title: account.label,
      subtitle: subtitle,
      entryId: entryId,
      pinned: pinned,
      editing: editing,
      selectable: selectable,
      selected: selected,
      onTogglePinned: onTogglePinned,
      onTap: onTap,
      onLongPress: onLongPress,
      onToggleSelected: onToggleSelected,
    );
  }
}

class _MobilePairedDeviceListItem extends StatelessWidget {
  const _MobilePairedDeviceListItem({
    required this.device,
    required this.active,
    required this.entryId,
    required this.pinned,
    required this.onTogglePinned,
    required this.onTap,
  });

  final MobileRelayPairedDevice device;
  final bool active;
  final String entryId;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return _MobileListTile(
      key: Key('mobile-paired-device-${device.id}'),
      icon: Icon(
        Icons.computer_rounded,
        size: 30,
        color: active ? colors.primary : colors.text,
      ),
      title: strings.arcDesktop,
      subtitle: active ? '${strings.active} · ${device.label}' : device.label,
      entryId: entryId,
      pinned: pinned,
      onTogglePinned: onTogglePinned,
      onTap: onTap,
    );
  }
}

class _MobileAgentListItem extends StatelessWidget {
  const _MobileAgentListItem({
    required this.target,
    required this.entryId,
    required this.subtitle,
    required this.pinned,
    required this.onTogglePinned,
    required this.onTap,
  });

  final TargetCandidate target;
  final String entryId;
  final String subtitle;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _MobileListTile(
      key: Key('mobile-agent-list-item-${target.target}'),
      icon: AgentBrandIcon(
        target: target,
        selected: true,
        detected: target.status != 'not-detected',
        size: 48,
        iconSize: 32,
      ),
      title: target.label,
      subtitle: subtitle,
      entryId: entryId,
      pinned: pinned,
      onTogglePinned: onTogglePinned,
      onTap: onTap,
    );
  }
}

class _MobileListTile extends StatelessWidget {
  const _MobileListTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.entryId,
    required this.pinned,
    required this.onTogglePinned,
    required this.onTap,
    this.editing = false,
    this.selectable = false,
    this.selected = false,
    this.onLongPress,
    this.onToggleSelected,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final String entryId;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final VoidCallback onTap;
  final bool editing;
  final bool selectable;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return _MobileSwipePinAction(
      entryId: entryId,
      pinned: pinned,
      enabled: !editing,
      onTogglePinned: onTogglePinned,
      child: Material(
        color: pinned ? colors.primaryFixed.withAlpha(120) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: pinned
              ? BorderSide(color: colors.primary.withAlpha(150))
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                if (editing && selectable) ...[
                  Checkbox(
                    key: Key('mobile-home-provider-checkbox-$entryId'),
                    value: selected,
                    onChanged: (_) => onToggleSelected?.call(),
                  ),
                  const SizedBox(width: 4),
                ],
                SizedBox.square(dimension: 48, child: Center(child: icon)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _mobileHomePreviewText(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: pinned ? colors.primary : colors.textMuted,
                          fontSize: 12,
                          fontWeight: pinned
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileSwipePinAction extends StatefulWidget {
  const _MobileSwipePinAction({
    required this.entryId,
    required this.pinned,
    required this.onTogglePinned,
    required this.child,
    this.enabled = true,
  });

  final String entryId;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final Widget child;
  final bool enabled;

  @override
  State<_MobileSwipePinAction> createState() => _MobileSwipePinActionState();
}

class _MobileSwipePinActionState extends State<_MobileSwipePinAction> {
  static const double _maxDragExtent = 84;
  static const double _openThreshold = 42;
  static const double _velocityThreshold = 420;

  double _revealExtent = 0;

  @override
  Widget build(BuildContext context) {
    final showAction = _revealExtent > 0;
    return ClipRRect(
      key: Key('mobile-home-swipe-${widget.entryId}'),
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: widget.enabled ? _handleDragUpdate : null,
        onHorizontalDragEnd: widget.enabled ? _handleDragEnd : null,
        onHorizontalDragCancel: widget.enabled ? _resetDrag : null,
        child: Stack(
          children: [
            if (showAction)
              Positioned.fill(
                child: _MobilePinSwipeButton(
                  entryId: widget.entryId,
                  pinned: widget.pinned,
                  onPressed: _togglePinned,
                ),
              ),
            Transform.translate(
              offset: Offset(-_revealExtent, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final primaryDelta = details.primaryDelta ?? details.delta.dx;
    final next = (_revealExtent - primaryDelta).clamp(0, _maxDragExtent);
    if (next == _revealExtent) {
      return;
    }
    setState(() {
      _revealExtent = next.toDouble();
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocityX = details.velocity.pixelsPerSecond.dx;
    final shouldOpen =
        _revealExtent >= _openThreshold || velocityX <= -_velocityThreshold;
    final shouldClose = velocityX >= _velocityThreshold;
    if (shouldOpen && !shouldClose) {
      _openAction();
    } else {
      _resetDrag();
    }
  }

  void _resetDrag() {
    if (_revealExtent == 0 || !mounted) {
      return;
    }
    setState(() {
      _revealExtent = 0;
    });
  }

  void _openAction() {
    if (!mounted || _revealExtent == _maxDragExtent) {
      return;
    }
    setState(() {
      _revealExtent = _maxDragExtent;
    });
  }

  void _togglePinned() {
    _resetDrag();
    widget.onTogglePinned();
  }
}

class _MobilePinSwipeButton extends StatelessWidget {
  const _MobilePinSwipeButton({
    required this.entryId,
    required this.pinned,
    required this.onPressed,
  });

  final String entryId;
  final bool pinned;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final label = pinned ? strings.unpinFromTop : strings.pinToTop;
    return Semantics(
      button: true,
      label: label,
      child: Container(
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: colors.primaryFixed.withAlpha(pinned ? 80 : 140),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          width: _MobileSwipePinActionState._maxDragExtent,
          child: IconButton(
            key: Key('mobile-home-pin-$entryId'),
            tooltip: label,
            onPressed: onPressed,
            icon: Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              color: colors.primary,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

Widget _providerIcon(String providerId, Color color) {
  return ProviderBrandIcon(providerId: providerId, color: color, size: 30);
}

class _MobileAgentsEmptyState extends StatelessWidget {
  const _MobileAgentsEmptyState({
    required this.scanning,
    required this.onAddAgent,
  });

  final bool scanning;
  final VoidCallback onAddAgent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, color: colors.textMuted, size: 34),
            const SizedBox(height: 12),
            Text(
              scanning
                  ? strings.scanningLocalAgents
                  : strings.noLocalAgentsFound,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (!scanning) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('mobile-empty-add-agent-button'),
                onPressed: onAddAgent,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(strings.addAgent),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MobileDesktopAgentList extends StatelessWidget {
  const _MobileDesktopAgentList({
    required this.controller,
    required this.device,
    required this.targets,
    required this.onBack,
    required this.onRefresh,
    required this.onSelect,
  });

  final ClientController controller;
  final MobileRelayPairedDevice device;
  final List<TargetCandidate> targets;
  final VoidCallback onBack;
  final Future<void> Function() onRefresh;
  final ValueChanged<TargetCandidate> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(
              bottom: BorderSide(color: colors.line.withAlpha(120)),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
            child: Row(
              children: [
                IconButton(
                  key: const Key('mobile-desktop-agents-back'),
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: onBack,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Icon(Icons.computer_rounded, color: colors.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.arcDesktop,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        device.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('mobile-desktop-agents-refresh'),
                  tooltip: strings.refreshAgents,
                  onPressed: () => unawaited(onRefresh()),
                  icon: controller.isScanningTargets
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: targets.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.hub_outlined,
                          color: colors.primary,
                          size: 34,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          strings.desktopAgents,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          strings.noDesktopAgents,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          onPressed: () => unawaited(onRefresh()),
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(strings.refreshAgents),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 14),
                  itemCount: targets.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final target = targets[index];
                    return _MobileDesktopAgentListItem(
                      target: target,
                      subtitle: strings.secureRelay,
                      onTap: () => onSelect(target),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MobileDesktopAgentListItem extends StatelessWidget {
  const _MobileDesktopAgentListItem({
    required this.target,
    required this.subtitle,
    required this.onTap,
  });

  final TargetCandidate target;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      key: Key('mobile-desktop-agent-${target.target}'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              AgentBrandIcon(
                target: target,
                selected: true,
                detected: target.status != 'not-detected',
                size: 48,
                iconSize: 32,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileConversationHandoffDialog extends StatefulWidget {
  const _MobileConversationHandoffDialog({
    required this.controller,
    required this.account,
  });

  final ClientController controller;
  final MobileAgentAccount account;

  @override
  State<_MobileConversationHandoffDialog> createState() =>
      _MobileConversationHandoffDialogState();
}

class _MobileConversationHandoffDialogState
    extends State<_MobileConversationHandoffDialog> {
  final TextEditingController _promptController = TextEditingController();
  String _targetAgentId = '';
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final targets = _targets;
    if (targets.isNotEmpty) {
      _targetAgentId = targets.first.target;
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  List<TargetCandidate> get _targets => widget.controller
      .orderedConversationTargets(
        widget.controller.scannedTargets.where(
          (target) => target.visibleInClient && target.canRelayRuntime,
        ),
      )
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final targets = _targets;
    final selectedValue =
        targets.any((target) => target.target == _targetAgentId)
        ? _targetAgentId
        : null;
    return AlertDialog(
      title: Text(strings.handoffToDesktopAgent),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('mobile-handoff-target'),
              initialValue: selectedValue,
              items: [
                for (final target in targets)
                  DropdownMenuItem<String>(
                    value: target.target,
                    child: Text(target.label),
                  ),
              ],
              onChanged: _submitting || targets.isEmpty
                  ? null
                  : (value) => setState(() => _targetAgentId = value ?? ''),
              decoration: InputDecoration(labelText: strings.desktopAgents),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('mobile-handoff-prompt'),
              controller: _promptController,
              minLines: 3,
              maxLines: 5,
              enabled: !_submitting,
              decoration: InputDecoration(
                labelText: strings.additionalPrompt,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton.icon(
          key: const Key('mobile-handoff-submit'),
          onPressed: _submitting || _targetAgentId.isEmpty ? null : _submit,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.turn_right_rounded, size: 18),
          label: Text(strings.handoff),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    await widget.controller.handoffMobileProviderConversationToAgent(
      account: widget.account,
      targetAgentId: _targetAgentId,
      prompt: _promptController.text,
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _MobileRemoteSessionList extends StatelessWidget {
  const _MobileRemoteSessionList({
    required this.controller,
    required this.account,
    required this.onBack,
    required this.onConfiguration,
    required this.onOpenConversation,
    required this.onNewConversation,
    required this.onShowTrash,
  });

  final ClientController controller;
  final MobileAgentAccount account;
  final VoidCallback onBack;
  final VoidCallback onConfiguration;
  final ValueChanged<MobileProviderConversationRecord> onOpenConversation;
  final Future<void> Function() onNewConversation;
  final VoidCallback onShowTrash;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final active = controller.activeMobileProviderConversationsFor(account);
    final archived = controller.archivedMobileProviderConversationsFor(account);
    return Column(
      children: [
        _MobileRemoteAccountHeader(
          account: account,
          onBack: onBack,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('mobile-provider-trash-${account.id}'),
                tooltip: strings.recycleBin,
                onPressed: onShowTrash,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              IconButton(
                key: Key('mobile-provider-settings-${account.id}'),
                tooltip: strings.settings,
                onPressed: onConfiguration,
                icon: const Icon(Icons.tune_rounded),
              ),
              IconButton.filled(
                key: Key('mobile-provider-new-conversation-${account.id}'),
                tooltip: strings.newConversation,
                onPressed: () => unawaited(onNewConversation()),
                icon: const Icon(Icons.add_comment_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (active.isEmpty && archived.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _providerIcon(account.providerId, colors.primary),
                          const SizedBox(height: 12),
                          Text(
                            strings.noConversationsYet,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            strings.messageTarget(account.label),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...[
                _MobileSessionSectionHeader(title: strings.conversations),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  sliver: SliverList.builder(
                    itemCount: active.length,
                    itemBuilder: (context, index) {
                      final record = active[index];
                      return _MobileConversationSwipeActions(
                        key: ValueKey(
                          'mobile-provider-session-${record.session.id}',
                        ),
                        record: record,
                        onArchive: () => unawaited(
                          controller.archiveMobileProviderConversation(
                            account,
                            record.session.id,
                          ),
                        ),
                        onTrash: () => unawaited(
                          _confirmTrashConversation(context, record),
                        ),
                        child: _MobileRemoteSessionTile(
                          account: account,
                          record: record,
                          onTap: () => onOpenConversation(record),
                        ),
                      );
                    },
                  ),
                ),
                if (archived.isNotEmpty) ...[
                  _MobileSessionSectionHeader(
                    title: strings.archivedConversations,
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                    sliver: SliverList.builder(
                      itemCount: archived.length,
                      itemBuilder: (context, index) {
                        final record = archived[index];
                        return _MobileConversationSwipeActions(
                          key: ValueKey(
                            'mobile-provider-archived-session-${record.session.id}',
                          ),
                          record: record,
                          onArchive: () {},
                          onTrash: () => unawaited(
                            _confirmTrashConversation(context, record),
                          ),
                          child: _MobileRemoteSessionTile(
                            account: account,
                            record: record,
                            archived: true,
                            onTap: () => onOpenConversation(record),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmTrashConversation(
    BuildContext context,
    MobileProviderConversationRecord record,
  ) async {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final title = record.session.title.trim().isEmpty
        ? account.label
        : record.session.title.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDeleteConversationTitle),
        content: Text(strings.confirmDeleteConversationMessage(title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton.icon(
            key: const Key('mobile-provider-confirm-delete-conversation'),
            style: FilledButton.styleFrom(backgroundColor: colors.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await controller.trashMobileProviderConversation(
      account,
      record.session.id,
    );
  }
}

class _MobileRemoteTrashList extends StatelessWidget {
  const _MobileRemoteTrashList({
    required this.controller,
    required this.account,
    required this.onBack,
  });

  final ClientController controller;
  final MobileAgentAccount account;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final trashed = controller.trashedMobileProviderConversationsFor(account);
    return Column(
      children: [
        _MobileRemoteAccountHeader(account: account, onBack: onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              strings.deletedConversationsExpire,
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ),
        ),
        Expanded(
          child: trashed.isEmpty
              ? Center(
                  child: Text(
                    strings.noTrashedConversations,
                    style: TextStyle(color: colors.textMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
                  itemCount: trashed.length,
                  itemBuilder: (context, index) {
                    final record = trashed[index];
                    return _MobileRemoteSessionTile(
                      account: account,
                      record: record,
                      trailing: TextButton.icon(
                        key: Key(
                          'mobile-provider-restore-${record.session.id}',
                        ),
                        onPressed: () => unawaited(
                          controller.restoreMobileProviderConversation(
                            account,
                            record.session.id,
                          ),
                        ),
                        icon: const Icon(Icons.restore_rounded, size: 18),
                        label: Text(strings.restore),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MobileSessionSectionHeader extends StatelessWidget {
  const _MobileSessionSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Text(
          title,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _MobileRemoteSessionTile extends StatelessWidget {
  const _MobileRemoteSessionTile({
    required this.account,
    required this.record,
    this.onTap,
    this.archived = false,
    this.trailing,
  });

  final MobileAgentAccount account;
  final MobileProviderConversationRecord record;
  final VoidCallback? onTap;
  final bool archived;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final session = record.session;
    final preview = session.preview.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('mobile-provider-session-open-${session.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 74),
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.line.withAlpha(150)),
            ),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 40,
                  child: Center(
                    child: _providerIcon(account.providerId, colors.text),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              session.title.trim().isEmpty
                                  ? account.label
                                  : session.title.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (archived)
                            Icon(
                              Icons.archive_outlined,
                              color: colors.textMuted,
                              size: 16,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preview.isEmpty ? account.label : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    Text(
                      _mobileProviderSessionTimeLabel(context, session),
                      style: TextStyle(color: colors.textMuted, fontSize: 11),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileConversationSwipeActions extends StatefulWidget {
  const _MobileConversationSwipeActions({
    super.key,
    required this.record,
    required this.onArchive,
    required this.onTrash,
    required this.child,
  });

  final MobileProviderConversationRecord record;
  final VoidCallback onArchive;
  final VoidCallback onTrash;
  final Widget child;

  @override
  State<_MobileConversationSwipeActions> createState() =>
      _MobileConversationSwipeActionsState();
}

class _MobileConversationSwipeActionsState
    extends State<_MobileConversationSwipeActions> {
  static const double _maxDragExtent = 168;
  static const double _openThreshold = 56;
  static const double _velocityThreshold = 420;

  double _revealExtent = 0;

  @override
  Widget build(BuildContext context) {
    final showAction = _revealExtent > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: _handleDragUpdate,
        onHorizontalDragEnd: _handleDragEnd,
        onHorizontalDragCancel: _resetDrag,
        child: Stack(
          children: [
            if (showAction)
              Positioned.fill(
                child: _MobileConversationActionButtons(
                  archived: widget.record.isArchived,
                  onArchive: _archive,
                  onTrash: _trash,
                ),
              ),
            Transform.translate(
              offset: Offset(-_revealExtent, 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final primaryDelta = details.primaryDelta ?? details.delta.dx;
    final next = (_revealExtent - primaryDelta).clamp(0, _maxDragExtent);
    if (next == _revealExtent) {
      return;
    }
    setState(() {
      _revealExtent = next.toDouble();
    });
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocityX = details.velocity.pixelsPerSecond.dx;
    final shouldOpen =
        _revealExtent >= _openThreshold || velocityX <= -_velocityThreshold;
    final shouldClose = velocityX >= _velocityThreshold;
    if (shouldOpen && !shouldClose) {
      setState(() => _revealExtent = _maxDragExtent);
    } else {
      _resetDrag();
    }
  }

  void _resetDrag() {
    if (_revealExtent == 0 || !mounted) {
      return;
    }
    setState(() => _revealExtent = 0);
  }

  void _archive() {
    _resetDrag();
    widget.onArchive();
  }

  void _trash() {
    _resetDrag();
    widget.onTrash();
  }
}

class _MobileConversationActionButtons extends StatelessWidget {
  const _MobileConversationActionButtons({
    required this.archived,
    required this.onArchive,
    required this.onTrash,
  });

  final bool archived;
  final VoidCallback onArchive;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      alignment: Alignment.centerRight,
      color: colors.surface,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (!archived)
            SizedBox(
              width: 84,
              child: IconButton(
                key: const Key('mobile-provider-session-archive'),
                tooltip: strings.archive,
                onPressed: onArchive,
                icon: Icon(Icons.archive_outlined, color: colors.primary),
              ),
            ),
          SizedBox(
            width: 84,
            child: IconButton(
              key: const Key('mobile-provider-session-delete'),
              tooltip: strings.delete,
              onPressed: onTrash,
              icon: Icon(Icons.delete_outline_rounded, color: colors.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileRemoteAgentConversation extends StatelessWidget {
  const _MobileRemoteAgentConversation({
    required this.controller,
    required this.account,
    required this.onBack,
    required this.onConfiguration,
    required this.onHandoff,
    required this.onOpenWebConversation,
  });

  final ClientController controller;
  final MobileAgentAccount account;
  final VoidCallback onBack;
  final VoidCallback onConfiguration;
  final ValueChanged<MobileAgentAccount> onHandoff;
  final ValueChanged<MobileAgentAccount> onOpenWebConversation;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final provider = account.provider;
    final isOauth = _mobileRemoteUsesOAuthCredential(account);
    final canLaunchLocalOAuth = _mobileRemoteCanLaunchLocalOAuth(account);
    final canConfigure = _canConfigureMobileRemoteAccount(account);
    final session = controller.mobileProviderConversationFor(account);
    final oauthAuthorizationPrompt = controller
        .mobileAgentOAuthAuthorizationPromptFor(account);
    final oauthValidationFailed = _mobileRemoteOAuthValidationFailed(account);
    final oauthPromptBlocksChat =
        isOauth &&
        (oauthValidationFailed ||
            oauthAuthorizationPrompt?.isWaiting == true ||
            oauthAuthorizationPrompt?.isFailed == true);
    final canChat =
        account.credentialPresent &&
        provider.supportsDirectChat &&
        !oauthPromptBlocksChat;
    final statusText = _mobileRemoteStatusText(strings, account);
    final showOAuthRecovery =
        _mobileRemoteNeedsOAuthRecovery(account, session) &&
        (oauthAuthorizationPrompt?.isDismissed != true);
    final showOAuthPrompt =
        isOauth &&
        (oauthValidationFailed ||
            showOAuthRecovery ||
            (oauthAuthorizationPrompt != null &&
                !oauthAuthorizationPrompt.isDismissed));
    return Column(
      children: [
        _MobileRemoteAccountHeader(
          account: account,
          onBack: onBack,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (account.providerId == 'chatgpt' &&
                  controller.scannedTargets.any(
                    (target) =>
                        target.visibleInClient && target.canRelayRuntime,
                  ))
                IconButton(
                  key: const Key('mobile-remote-agent-handoff-chatgpt'),
                  tooltip: strings.handoffToDesktopAgent,
                  onPressed: () => onHandoff(account),
                  icon: const Icon(Icons.turn_right_rounded),
                ),
              if (account.providerId == 'chatgpt')
                IconButton(
                  key: const Key('mobile-remote-agent-open-chatgpt-web'),
                  tooltip: strings.openChatGptWebConversation,
                  onPressed: () => onOpenWebConversation(account),
                  icon: const Icon(Icons.language_rounded),
                ),
              IconButton(
                key: const Key('mobile-remote-agent-open-configuration'),
                tooltip: strings.settings,
                onPressed: onConfiguration,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
        ),
        if (showOAuthPrompt)
          _MobileRemoteOAuthNoticeBanner(
            account: account,
            prompt: oauthAuthorizationPrompt,
            onAuthorize: () => _mobileRemoteCanLaunchLocalOAuth(account)
                ? unawaited(
                    controller.authorizeMobileAgentOAuth(
                      provider.id,
                      mobileAccountId: account.id,
                    ),
                  )
                : unawaited(
                    controller.syncMobileProviderCredentialsFromDesktopRelay(),
                  ),
            onDismiss: () =>
                controller.dismissMobileAgentOAuthAuthorizationPrompt(account),
          ),
        Expanded(
          child: canChat
              ? _MobileRemoteMessageList(
                  account: account,
                  session: session,
                  statusText: statusText,
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _providerIcon(
                          account.providerId,
                          account.credentialPresent
                              ? colors.primary
                              : colors.text,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          account.label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          statusText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        if (canConfigure) ...[
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            key: Key('mobile-remote-agent-auth-${provider.id}'),
                            onPressed: () => isOauth
                                ? canLaunchLocalOAuth
                                      ? controller.authorizeMobileAgentOAuth(
                                          provider.id,
                                          mobileAccountId: account.id,
                                        )
                                      : controller
                                            .syncMobileProviderCredentialsFromDesktopRelay()
                                : _showApiKeyDialog(
                                    context,
                                    controller,
                                    provider,
                                    account,
                                  ),
                            style: FilledButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            icon: Icon(
                              isOauth
                                  ? canLaunchLocalOAuth
                                        ? Icons.open_in_browser_rounded
                                        : Icons.sync_rounded
                                  : Icons.vpn_key_rounded,
                              size: 18,
                            ),
                            label: Text(
                              isOauth
                                  ? canLaunchLocalOAuth
                                        ? strings.webAuthorizationForProvider(
                                            provider.id,
                                            provider.label,
                                          )
                                        : strings
                                              .refreshSyncedOAuthAuthorization
                                  : strings.configureApiKey,
                            ),
                          ),
                          if (isOauth && canLaunchLocalOAuth) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              key: Key(
                                'mobile-remote-agent-paste-oauth-${provider.id}',
                              ),
                              onPressed: () => unawaited(
                                controller
                                    .completeMobileAgentOAuthCallbackFromClipboard(
                                      provider.id,
                                      mobileAccountId: account.id,
                                    ),
                              ),
                              icon: const Icon(
                                Icons.content_paste_rounded,
                                size: 18,
                              ),
                              label: Text(strings.pasteOAuthCallbackUrl),
                            ),
                          ],
                          if (!isOauth && canLaunchLocalOAuth) ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              key: Key(
                                'mobile-remote-agent-oauth-auth-${provider.id}',
                              ),
                              onPressed: () =>
                                  controller.authorizeMobileAgentOAuth(
                                    provider.id,
                                    mobileAccountId: account.id,
                                  ),
                              icon: const Icon(
                                Icons.open_in_browser_rounded,
                                size: 18,
                              ),
                              label: Text(
                                strings.webAuthorizationForProvider(
                                  provider.id,
                                  provider.label,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
        ),
        if (canChat)
          _MobileRemoteComposer(
            account: account,
            busy: controller.isSendingMobileProviderMessage,
            onSend: (text) => unawaited(
              controller.sendMobileProviderMessage(
                account: account,
                text: text,
              ),
            ),
          ),
      ],
    );
  }
}

class _MobileRemoteOAuthNoticeBanner extends StatefulWidget {
  const _MobileRemoteOAuthNoticeBanner({
    required this.account,
    required this.prompt,
    required this.onAuthorize,
    required this.onDismiss,
  });

  final MobileAgentAccount account;
  final MobileAgentOAuthAuthorizationPrompt? prompt;
  final VoidCallback onAuthorize;
  final VoidCallback onDismiss;

  @override
  State<_MobileRemoteOAuthNoticeBanner> createState() =>
      _MobileRemoteOAuthNoticeBannerState();
}

class _MobileRemoteOAuthNoticeBannerState
    extends State<_MobileRemoteOAuthNoticeBanner> {
  @override
  void dispose() {
    if (widget.prompt?.isSuccess == true) {
      Future<void>.microtask(widget.onDismiss);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final account = widget.account;
    final prompt = widget.prompt;
    final canLaunchLocalOAuth = _mobileRemoteCanLaunchLocalOAuth(account);
    final isWaiting = prompt?.isWaiting == true;
    final isFailed =
        prompt?.isFailed == true || _mobileRemoteOAuthValidationFailed(account);
    final isSuccess = prompt?.isSuccess == true;
    final accent = isSuccess
        ? colors.success
        : isFailed
        ? colors.error
        : colors.info;
    final title = isSuccess
        ? strings.oauthAuthorizationSuccessTitle
        : isFailed
        ? strings.oauthAuthorizationFailedTitle
        : isWaiting
        ? strings.oauthAuthorizationWaitingTitle
        : strings.oauthRecoveryTitle;
    final body = isSuccess
        ? strings.oauthAuthorizationSuccessBodyForProvider(
            account.providerId,
            account.provider.label,
          )
        : isFailed
        ? strings.oauthAuthorizationFailedBodyForProvider(
            account.providerId,
            account.provider.label,
            prompt?.message ?? '',
          )
        : isWaiting
        ? strings.oauthAuthorizationWaitingBodyForProvider(
            account.providerId,
            account.provider.label,
          )
        : strings.oauthRecoveryBody(account.provider.label);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(colors.isDark ? 18 : 26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withAlpha(120), width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isWaiting)
                    SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.info,
                      ),
                    )
                  else
                    Icon(
                      isSuccess
                          ? Icons.check_circle_outline_rounded
                          : isFailed
                          ? Icons.error_outline_rounded
                          : Icons.lock_reset_rounded,
                      color: accent,
                      size: 22,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: colors.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          body,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSuccess)
                    IconButton(
                      key: Key(
                        'mobile-remote-agent-oauth-recovery-close-${account.id}',
                      ),
                      tooltip: strings.close,
                      onPressed: widget.onDismiss,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: colors.textMuted,
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: Key('mobile-remote-agent-oauth-recovery-${account.id}'),
                  onPressed: isWaiting
                      ? null
                      : isSuccess
                      ? widget.onDismiss
                      : widget.onAuthorize,
                  style: FilledButton.styleFrom(
                    backgroundColor: isSuccess ? colors.success : null,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: Icon(
                    isSuccess
                        ? Icons.close_rounded
                        : isWaiting
                        ? Icons.hourglass_top_rounded
                        : canLaunchLocalOAuth
                        ? Icons.open_in_browser_rounded
                        : Icons.sync_rounded,
                    size: 18,
                  ),
                  label: Text(
                    isSuccess
                        ? strings.close
                        : isWaiting
                        ? strings.oauthAuthorizationWaitingAction
                        : canLaunchLocalOAuth
                        ? strings.reauthorizeOAuth
                        : strings.refreshSyncedOAuthAuthorization,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileRemoteMessageList extends StatelessWidget {
  const _MobileRemoteMessageList({
    required this.account,
    required this.session,
    required this.statusText,
  });

  final MobileAgentAccount account;
  final AgentConversationSession? session;
  final String statusText;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final messages = session?.messages ?? const <AgentConversationMessage>[];
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _providerIcon(account.providerId, colors.primary),
              const SizedBox(height: 12),
              Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                strings.messageTarget(account.label),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[messages.length - 1 - index];
        return _MobileRemoteMessageBubble(message: message);
      },
      separatorBuilder: (context, index) => const SizedBox(height: 10),
    );
  }
}

class _MobileRemoteMessageBubble extends StatelessWidget {
  const _MobileRemoteMessageBubble({required this.message});

  final AgentConversationMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isUser = message.role.toLowerCase().trim() == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 310),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isUser ? colors.primaryFixed : colors.surfaceLow,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isUser ? colors.primary.withAlpha(90) : colors.line,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            child: MessageMarkdown(
              data: message.text,
              foreground: colors.text,
              accent: colors.primary,
              codeBackground: colors.surface,
              blockBackground: colors.surface,
              borderColor: colors.line,
              renderStyle: const MessageMarkdownStyle(bodyFontSize: 14),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileRemoteComposer extends StatefulWidget {
  const _MobileRemoteComposer({
    required this.account,
    required this.busy,
    required this.onSend,
  });

  final MobileAgentAccount account;
  final bool busy;
  final ValueChanged<String> onSend;

  @override
  State<_MobileRemoteComposer> createState() => _MobileRemoteComposerState();
}

class _MobileRemoteComposerState extends State<_MobileRemoteComposer> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(top: BorderSide(color: colors.line.withAlpha(120))),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: Key(
                      'mobile-remote-agent-composer-${widget.account.id}',
                    ),
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    enabled: !widget.busy,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: strings.messageTarget(widget.account.label),
                      isDense: true,
                      filled: true,
                      fillColor: colors.surfaceLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton.filled(
                    key: Key('mobile-remote-agent-send-${widget.account.id}'),
                    tooltip: strings.send,
                    onPressed: widget.busy ? null : _submit,
                    icon: widget.busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.busy) {
      return;
    }
    _controller.clear();
    widget.onSend(text);
  }
}

class _MobileRemoteAgentConfiguration extends StatelessWidget {
  const _MobileRemoteAgentConfiguration({
    required this.controller,
    required this.account,
    required this.onBack,
    required this.onSelectAccount,
    required this.onDeleted,
  });

  final ClientController controller;
  final MobileAgentAccount account;
  final VoidCallback onBack;
  final ValueChanged<MobileAgentAccount> onSelectAccount;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final provider = account.provider;
    final isOauth = _mobileRemoteUsesOAuthCredential(account);
    final canLaunchLocalOAuth = _mobileRemoteCanLaunchLocalOAuth(account);
    final isDesktopRelay = account.usesDesktopRelay;
    final canConfigure = _canConfigureMobileRemoteAccount(account);
    final authMethod = isDesktopRelay
        ? strings.pairedComputerAuthorization
        : isOauth
        ? strings.oauthAuthorizationMethodForProvider(
            account.providerId,
            provider.label,
          )
        : strings.apiKeyAuthorization;
    final readiness = _mobileRemoteReadinessText(strings, account);
    final siblingAccounts = controller.mobileAgentAccounts
        .where((candidate) => candidate.providerId == account.providerId)
        .toList(growable: false);
    return Column(
      children: [
        _MobileRemoteAccountHeader(account: account, onBack: onBack),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              _MobileConfigRow(
                icon: Icons.smart_toy_outlined,
                label: strings.agent,
                value: provider.label,
              ),
              _MobileConfigRow(
                icon: account.credentialPresent
                    ? _mobileRemoteOAuthValidationFailed(account)
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded
                    : Icons.lock_outline_rounded,
                label: strings.status,
                value: _mobileRemoteStatusText(strings, account),
              ),
              _MobileConfigRow(
                icon: Icons.key_rounded,
                label: strings.authorizationMethod,
                value: authMethod,
              ),
              _MobileConfigRow(
                icon: Icons.hub_outlined,
                label: strings.readiness,
                value: readiness,
              ),
              _MobileConfigRow(
                icon: Icons.layers_outlined,
                label: strings.isChinese ? '来源模式' : 'Source mode',
                value: _mobileAccountSourceModeLabel(strings, account),
              ),
              if (account.active)
                _MobileConfigRow(
                  icon: Icons.check_circle_outline_rounded,
                  label: strings.isChinese ? '当前账号' : 'Active account',
                  value: strings.isChinese ? '是' : 'Yes',
                ),
              if (siblingAccounts.length > 1) ...[
                const SizedBox(height: 16),
                Text(
                  strings.isChinese
                      ? '同供应商账号（${siblingAccounts.length}）'
                      : 'Provider accounts (${siblingAccounts.length})',
                  style: TextStyle(
                    color: colors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                for (final candidate in siblingAccounts)
                  Semantics(
                    selected: candidate.id == account.id,
                    button: true,
                    child: ListTile(
                      key: Key(
                        'mobile-remote-agent-account-row-${candidate.id}',
                      ),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      selected: candidate.id == account.id,
                      onTap: () => onSelectAccount(candidate),
                      leading: Icon(
                        candidate.id == account.id
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: candidate.id == account.id
                            ? colors.primary
                            : colors.textMuted,
                      ),
                      title: Text(
                        candidate.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_mobileRemoteStatusText(strings, candidate)} · '
                        '${_mobileAccountSourceModeLabel(strings, candidate)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: candidate.active
                          ? Tooltip(
                              message: strings.isChinese
                                  ? '当前账号'
                                  : 'Active account',
                              child: Icon(
                                Icons.check_circle_rounded,
                                color: colors.primary,
                                size: 20,
                              ),
                            )
                          : null,
                    ),
                  ),
                Divider(color: colors.line),
              ],
              const SizedBox(height: 12),
              _MobileGenerationDropdown(
                key: Key('mobile-remote-agent-model-${account.id}'),
                icon: Icons.memory_rounded,
                label: strings.model,
                value: account.effectiveModel,
                options: provider.effectiveModelOptions,
                optionLabel: (option) => option.label,
                onChanged: (value) => unawaited(
                  controller.updateMobileAgentGenerationOptions(
                    account.id,
                    selectedModel: value,
                  ),
                ),
              ),
              if (provider.reasoningEffortOptions.isNotEmpty) ...[
                const SizedBox(height: 12),
                _MobileGenerationDropdown(
                  key: Key('mobile-remote-agent-reasoning-${account.id}'),
                  icon: Icons.psychology_alt_outlined,
                  label: strings.reasoningEffort,
                  value: account.reasoningEffort.trim(),
                  options: provider.reasoningEffortOptions,
                  optionLabel: (option) => strings.reasoningEffortOptionLabel(
                    option.id,
                    option.label,
                  ),
                  onChanged: (value) => unawaited(
                    controller.updateMobileAgentGenerationOptions(
                      account.id,
                      reasoningEffort: value,
                    ),
                  ),
                ),
              ],
              if (canConfigure) ...[
                const SizedBox(height: 16),
                if (!account.active && !isDesktopRelay)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      key: Key('mobile-remote-agent-set-active-${account.id}'),
                      onPressed: () => unawaited(
                        controller.setActiveMobileAgentAccount(account.id),
                      ),
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: Text(
                        strings.isChinese ? '设为当前账号' : 'Use this account',
                      ),
                    ),
                  ),
                if (!isDesktopRelay)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      key: Key('mobile-remote-agent-rename-${account.id}'),
                      onPressed: () => unawaited(
                        _showRenameMobileAccountDialog(
                          context,
                          controller,
                          account,
                        ),
                      ),
                      icon: const Icon(
                        Icons.drive_file_rename_outline,
                        size: 18,
                      ),
                      label: Text(
                        strings.isChinese ? '重命名账号' : 'Rename account',
                      ),
                    ),
                  ),
                if (!isDesktopRelay)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      key: Key(
                        'mobile-remote-agent-add-sibling-${provider.id}',
                      ),
                      onPressed: () => unawaited(
                        controller.addMobileAgentProvider(provider.id),
                      ),
                      icon: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 18,
                      ),
                      label: Text(
                        strings.isChinese ? '添加同供应商账号' : 'Add another account',
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    key: Key('mobile-remote-agent-refresh-${account.id}'),
                    onPressed: () => unawaited(
                      controller.refreshMobileAgentAccountStatus(account),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      strings.isChinese ? '刷新账号状态' : 'Refresh account status',
                    ),
                  ),
                ),
                FilledButton.icon(
                  key: Key('mobile-remote-agent-auth-${provider.id}'),
                  onPressed: () => isOauth
                      ? canLaunchLocalOAuth
                            ? controller.authorizeMobileAgentOAuth(
                                provider.id,
                                mobileAccountId: account.id,
                              )
                            : controller
                                  .syncMobileProviderCredentialsFromDesktopRelay()
                      : _showApiKeyDialog(
                          context,
                          controller,
                          provider,
                          account,
                        ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: Icon(
                    isOauth
                        ? canLaunchLocalOAuth
                              ? Icons.open_in_browser_rounded
                              : Icons.sync_rounded
                        : Icons.vpn_key_rounded,
                    size: 18,
                  ),
                  label: Text(
                    isOauth
                        ? canLaunchLocalOAuth
                              ? strings.webAuthorizationForProvider(
                                  provider.id,
                                  provider.label,
                                )
                              : strings.refreshSyncedOAuthAuthorization
                        : strings.configureApiKey,
                  ),
                ),
                if (isOauth && canLaunchLocalOAuth) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: Key('mobile-remote-agent-paste-oauth-${provider.id}'),
                    onPressed: () => unawaited(
                      controller.completeMobileAgentOAuthCallbackFromClipboard(
                        provider.id,
                        mobileAccountId: account.id,
                      ),
                    ),
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: Text(strings.pasteOAuthCallbackUrl),
                  ),
                ],
                if (!isOauth && canLaunchLocalOAuth) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: Key('mobile-remote-agent-oauth-auth-${provider.id}'),
                    onPressed: () => controller.authorizeMobileAgentOAuth(
                      provider.id,
                      mobileAccountId: account.id,
                    ),
                    icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                    label: Text(
                      strings.webAuthorizationForProvider(
                        provider.id,
                        provider.label,
                      ),
                    ),
                  ),
                ],
                if (provider.supportsPhoneAssistant && !isDesktopRelay) ...[
                  const SizedBox(height: 16),
                  Text(
                    strings.isChinese ? '手机助手授权' : 'Phone assistant grants',
                    style: TextStyle(
                      color: colors.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SwitchListTile.adaptive(
                    key: Key(
                      'mobile-remote-agent-grant-local-info-${account.id}',
                    ),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      strings.isChinese ? '本地设备信息' : 'Local device info',
                    ),
                    value: account.assistantGrants.localInfo,
                    onChanged: (value) => unawaited(
                      controller.updateMobileAgentAssistantGrants(
                        accountId: account.id,
                        grants: account.assistantGrants.copyWith(
                          localInfo: value,
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile.adaptive(
                    key: Key(
                      'mobile-remote-agent-grant-accessibility-${account.id}',
                    ),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      strings.isChinese ? '无障碍操作' : 'Accessibility actions',
                    ),
                    value: account.assistantGrants.accessibility,
                    onChanged: (value) => unawaited(
                      controller.updateMobileAgentAssistantGrants(
                        accountId: account.id,
                        grants: account.assistantGrants.copyWith(
                          accessibility: value,
                        ),
                      ),
                    ),
                  ),
                ],
                if (!isDesktopRelay) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: Key('mobile-remote-agent-delete-${account.id}'),
                    onPressed: () => unawaited(
                      _confirmDeleteMobileAgentAccount(
                        context,
                        controller,
                        account,
                        onDeleted,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.error,
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    label: Text(strings.isChinese ? '删除账号' : 'Delete account'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _confirmDeleteMobileAgentAccount(
  BuildContext context,
  ClientController controller,
  MobileAgentAccount account,
  VoidCallback onDeleted,
) async {
  final strings = LicoStrings.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(strings.isChinese ? '删除账号？' : 'Delete account?'),
      content: Text(
        strings.isChinese
            ? '将删除“${account.label}”的本机账号资料和对应安全凭据。其他账号不会受影响。'
            : 'This removes the local account record and its secure credential for '
                  '“${account.label}”. Other accounts are not affected.',
      ),
      actions: [
        TextButton(
          key: const Key('mobile-remote-agent-cancel-delete'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(
            MaterialLocalizations.of(dialogContext).cancelButtonLabel,
          ),
        ),
        FilledButton(
          key: const Key('mobile-remote-agent-confirm-delete'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(strings.isChinese ? '删除账号' : 'Delete account'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    return;
  }
  await controller.deleteMobileAgentAccounts([account.id]);
  if (controller.lastError.trim().isEmpty) {
    onDeleted();
  }
}

Future<void> _showRenameMobileAccountDialog(
  BuildContext context,
  ClientController controller,
  MobileAgentAccount account,
) async {
  final strings = LicoStrings.of(context);
  final labelController = TextEditingController(text: account.label);
  final nextLabel = await showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(strings.isChinese ? '重命名账号' : 'Rename account'),
        content: TextField(
          key: Key('mobile-remote-agent-rename-field-${account.id}'),
          controller: labelController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: strings.isChinese ? '账号名称' : 'Account label',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(labelController.text.trim()),
            child: Text(strings.save),
          ),
        ],
      );
    },
  );
  labelController.dispose();
  if (nextLabel == null || nextLabel.isEmpty || nextLabel == account.label) {
    return;
  }
  await controller.renameMobileAgentAccount(
    accountId: account.id,
    label: nextLabel,
  );
}

class _MobileGenerationDropdown extends StatelessWidget {
  const _MobileGenerationDropdown({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String value;
  final List<MobileAgentGenerationOption> options;
  final String Function(MobileAgentGenerationOption option) optionLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final normalizedOptions = options.isEmpty
        ? [MobileAgentGenerationOption(id: value, label: value)]
        : options;
    final selected = normalizedOptions.any((option) => option.id == value)
        ? value
        : normalizedOptions.first.id;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, size: 20),
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      items: [
        for (final option in normalizedOptions)
          DropdownMenuItem<String>(
            value: option.id,
            child: Text(
              optionLabel(option),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }
}

Future<void> _showApiKeyDialog(
  BuildContext context,
  ClientController controller,
  MobileAgentProvider provider,
  MobileAgentAccount account,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _MobileApiKeyDialog(
      controller: controller,
      provider: provider,
      account: account,
    ),
  );
}

class _MobileApiKeyDialog extends StatefulWidget {
  const _MobileApiKeyDialog({
    required this.controller,
    required this.provider,
    required this.account,
  });

  final ClientController controller;
  final MobileAgentProvider provider;
  final MobileAgentAccount account;

  @override
  State<_MobileApiKeyDialog> createState() => _MobileApiKeyDialogState();
}

class _MobileApiKeyDialogState extends State<_MobileApiKeyDialog> {
  final TextEditingController _textController = TextEditingController();
  bool _saving = false;
  bool _opening = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final provider = widget.provider;
    final canSave = _textController.text.trim().isNotEmpty && !_saving;
    return AlertDialog(
      title: Text('${strings.configureApiKey} - ${provider.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: Key('mobile-remote-agent-api-key-${provider.id}'),
            controller: _textController,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: strings.apiKeyInputLabel,
              hintText: strings.apiKeyInputHint,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Text(
            strings.apiKeySetupNotice(provider.docsUrl),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (provider.id == 'chatgpt') ...[
            const SizedBox(height: 8),
            Text(
              strings.chatGptOAuthNotApiKeyNotice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key(
                'mobile-remote-agent-open-credential-url-${provider.id}',
              ),
              onPressed: _opening ? null : _openCredentialPage,
              icon: _opening
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded, size: 18),
              label: Text(
                provider.id == 'chatgpt'
                    ? strings.openApiKeyPage
                    : strings.openProviderPage,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: Key('mobile-remote-agent-save-api-key-${provider.id}'),
          onPressed: canSave ? _save : null,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.saveApiKey),
        ),
      ],
    );
  }

  Future<void> _openCredentialPage() async {
    setState(() => _opening = true);
    await widget.controller.openMobileAgentProviderCredentialPage(
      widget.provider,
    );
    if (mounted) {
      setState(() => _opening = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.configureMobileAgentApiKey(
      providerId: widget.provider.id,
      mobileAccountId: widget.account.id,
      apiKey: _textController.text,
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _MobileRemoteAccountHeader extends StatelessWidget {
  const _MobileRemoteAccountHeader({
    required this.account,
    required this.onBack,
    this.trailing,
  });

  final MobileAgentAccount account;
  final VoidCallback onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.background),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            SizedBox.square(
              dimension: 36,
              child: Center(
                child: _providerIcon(account.providerId, colors.text),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                account.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _MobileAddAgentSheet extends StatelessWidget {
  const _MobileAddAgentSheet({
    required this.controller,
    required this.onScanQr,
  });

  final ClientController controller;
  final Future<void> Function() onScanQr;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(
              strings.addAgent,
              style: TextStyle(
                color: colors.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            _MobileScanQrOption(
              onTap: () {
                Navigator.of(context).pop();
                unawaited(onScanQr());
              },
            ),
            const SizedBox(height: 8),
            for (final provider in mobileAgentProviders)
              _MobileProviderOption(
                provider: provider,
                onTap: () {
                  unawaited(controller.addMobileAgentProvider(provider.id));
                  Navigator.of(context).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileScanQrOption extends StatelessWidget {
  const _MobileScanQrOption({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Material(
      key: const Key('mobile-agent-scan-qr-option'),
      color: colors.primaryFixed.withAlpha(220),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.primary.withAlpha(170)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 48,
                child: Center(
                  child: MinimalScanIcon(
                    color: colors.primary,
                    size: 30,
                    strokeWidth: 2.2,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.scanQrCode,
                      style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      strings.pairDevice,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileProviderOption extends StatelessWidget {
  const _MobileProviderOption({required this.provider, required this.onTap});

  final MobileAgentProvider provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final isOauth = provider.authKind == MobileAgentAuthKind.oauthPkce;
    return ListTile(
      key: Key('mobile-agent-provider-${provider.id}'),
      contentPadding: EdgeInsets.zero,
      leading: SizedBox.square(
        dimension: 48,
        child: Center(child: _providerIcon(provider.id, colors.text)),
      ),
      title: Text(
        provider.label,
        style: TextStyle(color: colors.text, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        isOauth
            ? strings.webAuthorizationForProvider(provider.id, provider.label)
            : _mobileProviderCanLaunchLocalOAuth(provider)
            ? '${strings.configureApiKey} / ${strings.webAuthorizationForProvider(provider.id, provider.label)}'
            : strings.configureApiKey,
        style: TextStyle(color: colors.textMuted, fontSize: 12),
      ),
      trailing: Icon(Icons.add_rounded, color: colors.textMuted),
      onTap: onTap,
    );
  }
}

class _MobileAgentConversation extends StatelessWidget {
  const _MobileAgentConversation({
    required this.controller,
    required this.targets,
    required this.target,
    required this.onBack,
    required this.onConfiguration,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final TargetCandidate target;
  final VoidCallback onBack;
  final VoidCallback onConfiguration;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: target.label,
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
          trailing: IconButton(
            key: const Key('mobile-agent-open-configuration'),
            tooltip: LicoStrings.of(context).settings,
            onPressed: onConfiguration,
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
        Expanded(
          child: AgentConversationWorkspace(
            controller: controller,
            targets: targets,
            scanning: controller.isScanningTargets,
            adding: controller.isAddingTarget,
            onAddTarget: () {},
            allowManualTargetActions: false,
          ),
        ),
      ],
    );
  }
}

class _MobileAgentConfiguration extends StatelessWidget {
  const _MobileAgentConfiguration({
    required this.controller,
    required this.target,
    required this.onBack,
  });

  final ClientController controller;
  final TargetCandidate target;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final historyRoots = [...target.historyRoots, ...target.remoteHistoryRoots];
    return Column(
      children: [
        _MobileAgentHeader(
          target: target,
          title: strings.agentConfiguration,
          leadingTooltip: MaterialLocalizations.of(context).backButtonTooltip,
          leadingIcon: Icons.chevron_left_rounded,
          onLeading: onBack,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              _MobileConfigRow(
                icon: Icons.smart_toy_outlined,
                label: strings.agent,
                value: target.label,
              ),
              _MobileConfigRow(
                icon: target.configured
                    ? Icons.check_circle_outline_rounded
                    : Icons.radio_button_unchecked_rounded,
                label: strings.target,
                value: target.configured
                    ? strings.configured
                    : strings.notConfigured,
              ),
              _MobileConfigRow(
                icon: Icons.category_outlined,
                label: strings.protocol,
                value: target.kind.trim().isEmpty
                    ? target.adapterStatus
                    : target.kind,
              ),
              DirectoryPathField(
                title: strings.configPath,
                label: strings.configPath,
                path: target.configPath?.trim() ?? '',
                icon: Icons.settings_applications_outlined,
                readOnly: true,
                showHeader: false,
                compactBreakpoint: 360,
                padding: const EdgeInsets.symmetric(vertical: 12),
                onOpen: (path) => controller.openDirectoryPath(
                  _directoryForMobilePath(path),
                  caption: strings.configPath,
                ),
              ),
              _MobileConfigRow(
                icon: Icons.terminal_outlined,
                label: strings.binaryPath,
                value: _displayValue(target.binaryPath, strings),
              ),
              _MobileConfigRow(
                icon: Icons.history_rounded,
                label: strings.historyRoot,
                value: historyRoots.isEmpty
                    ? strings.unavailable
                    : historyRoots.join('\n'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          unawaited(controller.inspectTarget(target.target)),
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: Text(strings.inspect),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          unawaited(controller.planTargetConfig(target.target)),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(Icons.route_outlined, size: 18),
                      label: Text(strings.plan),
                    ),
                  ),
                ],
              ),
              if (controller.displayStatusMessage.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  controller.displayStatusMessage,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _displayValue(String? value, LicoStrings strings) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? strings.unavailable : trimmed;
  }
}

String _directoryForMobilePath(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '-') {
    return '';
  }
  final basename = p.basename(trimmed);
  return basename.contains('.') ? p.dirname(trimmed) : trimmed;
}

class _MobileAgentHeader extends StatelessWidget {
  const _MobileAgentHeader({
    required this.target,
    required this.title,
    required this.leadingTooltip,
    required this.leadingIcon,
    required this.onLeading,
    this.trailing,
  });

  final TargetCandidate target;
  final String title;
  final String leadingTooltip;
  final IconData leadingIcon;
  final VoidCallback onLeading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.line.withAlpha(120))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
        child: Row(
          children: [
            IconButton(
              tooltip: leadingTooltip,
              onPressed: onLeading,
              icon: Icon(leadingIcon),
            ),
            AgentBrandIcon(
              target: target,
              selected: true,
              detected: target.status != 'not-detected',
              size: 36,
              iconSize: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _MobileConfigRow extends StatelessWidget {
  const _MobileConfigRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 21, color: colors.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
