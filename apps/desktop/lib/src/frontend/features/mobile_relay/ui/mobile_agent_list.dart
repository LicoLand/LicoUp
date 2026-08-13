import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list_items.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_desktop_agent_list.dart';

final class MobileAgentList extends StatefulWidget {
  const MobileAgentList({
    super.key,
    required this.controller,
    required this.targets,
    required this.devices,
    required this.onRefresh,
    required this.onSelect,
    required this.onSelectDevice,
    required this.onAddAgent,
  });

  final ClientController controller;
  final List<TargetCandidate> targets;
  final List<MobileRelayPairedDevice> devices;
  final Future<void> Function() onRefresh;
  final ValueChanged<TargetCandidate> onSelect;
  final ValueChanged<MobileRelayPairedDevice> onSelectDevice;
  final VoidCallback onAddAgent;

  @override
  State<MobileAgentList> createState() => _MobileAgentListState();
}

final class _MobileAgentListState extends State<MobileAgentList> {
  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final rootTargets =
        widget.controller.mobileClientRuntimePlatform &&
            widget.devices.isNotEmpty
        ? const <TargetCandidate>[]
        : widget.targets;
    final unordered = [
      for (final device in widget.devices) _pairedDeviceEntry(device),
      for (final target in rootTargets) _localAgentEntry(context, target),
    ];
    final byId = {for (final entry in unordered) entry.id: entry};
    final entries = [
      for (final id in orderMobileHomeEntryIds([
        for (final entry in unordered) entry.orderItem,
      ], widget.controller.mobileHomeLayout))
        byId[id]!,
    ];
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
              child: LicoEmptyState(
                icon: Icons.psychology_outlined,
                iconSize: 34,
                title: widget.controller.isScanningTargets
                    ? strings.scanningLocalAgents
                    : strings.noLocalAgentsFound,
                action: widget.controller.isScanningTargets
                    ? null
                    : OutlinedButton.icon(
                        key: const Key('mobile-empty-add-agent-button'),
                        onPressed: widget.onAddAgent,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(strings.addAgent),
                      ),
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
                  if (oldIndex >= pinnedCount) return;
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
                  return entry.pinned
                      ? ReorderableDelayedDragStartListener(
                          key: key,
                          index: index,
                          child: child,
                        )
                      : KeyedSubtree(key: key, child: child);
                },
              ),
            ),
        ],
      ),
    );
  }

  _RenderedMobileHomeEntry _pairedDeviceEntry(MobileRelayPairedDevice device) {
    final id = 'device:${device.id}';
    final pinned = widget.controller.mobileHomeLayout.isPinned(id);
    return _RenderedMobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: 0,
      child: MobilePairedDeviceListItem(
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

  _RenderedMobileHomeEntry _localAgentEntry(
    BuildContext context,
    TargetCandidate target,
  ) {
    final id = 'target:${target.target}';
    final pinned = widget.controller.mobileHomeLayout.isPinned(id);
    final latestSession = latestMobileHomeSession(
      widget.controller.conversationSessionsByAgent[target.target] ?? const [],
    );
    final preview = mobileHomePreviewText(latestSession?.preview);
    final subtitle = preview.isNotEmpty
        ? preview
        : _localAgentFallbackSubtitle(context, target);
    return _RenderedMobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: latestSession == null
          ? 0
          : mobileConversationSortTime(latestSession),
      child: MobileLocalAgentListItem(
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
}

final class _RenderedMobileHomeEntry {
  const _RenderedMobileHomeEntry({
    required this.id,
    required this.pinned,
    required this.sortTimeMillis,
    required this.child,
  });

  final String id;
  final bool pinned;
  final int sortTimeMillis;
  final Widget child;

  MobileHomeEntryOrderItem get orderItem => MobileHomeEntryOrderItem(
    id: id,
    pinned: pinned,
    sortTimeMillis: sortTimeMillis,
  );
}

int? _mobileHomeEntryIndexForKey(
  List<_RenderedMobileHomeEntry> entries,
  Key key,
) {
  if (key is! ValueKey<String>) return null;
  const prefix = 'mobile-home-entry-';
  if (!key.value.startsWith(prefix)) return null;
  final entryId = key.value.substring(prefix.length);
  final index = entries.indexWhere((entry) => entry.id == entryId);
  return index < 0 ? null : index;
}

String _localAgentFallbackSubtitle(
  BuildContext context,
  TargetCandidate target,
) {
  final strings = LicoStrings.of(context);
  return [
    target.configured ? strings.configured : strings.notConfigured,
    if (target.kind.trim().isNotEmpty) target.kind.trim(),
  ].join(' · ');
}
