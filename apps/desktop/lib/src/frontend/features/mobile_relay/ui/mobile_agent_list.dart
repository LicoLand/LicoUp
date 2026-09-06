import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agent_list_items.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

export 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_desktop_agent_list.dart';

final class MobileAgentList extends StatelessWidget {
  const MobileAgentList({
    super.key,
    required this.agents,
    required this.relay,
    required this.agentIntents,
    required this.relayIntents,
    required this.onSelect,
    required this.onSelectDevice,
    required this.onAddAgent,
    this.iconBuilder,
  });

  final AgentsProjection agents;
  final MobileRelayProjection relay;
  final IntentSink<AgentsIntent> agentIntents;
  final IntentSink<MobileRelayIntent> relayIntents;
  final ValueChanged<AgentTargetProjection> onSelect;
  final ValueChanged<RelayPeerProjection> onSelectDevice;
  final VoidCallback onAddAgent;
  final MobileAgentIconBuilder? iconBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final rootTargets = relay.mobileRuntime && relay.peers.isNotEmpty
        ? const <AgentTargetProjection>[]
        : agents.targets;
    final unordered = [
      for (final device in relay.peers) _pairedDeviceEntry(device),
      for (final target in rootTargets) _localAgentEntry(context, target),
    ];
    final byId = {for (final entry in unordered) entry.id: entry};
    final orderedIds = orderMobileHomeEntryIds([
      for (final entry in unordered) entry.orderItem,
    ], persistedOrder: relay.homeEntryOrder);
    final entries = [for (final id in orderedIds) byId[id]!];
    final pinnedCount = entries.where((entry) => entry.pinned).length;
    final scanning =
        agents.phase == PresentationPhase.loading ||
        agents.phase == PresentationPhase.applying;
    return RefreshIndicator(
      onRefresh: () {
        agentIntents.send(const ScanAgents());
        return Future<void>.value();
      },
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
                    onPressed: onAddAgent,
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
                title: scanning
                    ? strings.scanningLocalAgents
                    : strings.noLocalAgentsFound,
                action: scanning
                    ? null
                    : OutlinedButton.icon(
                        key: const Key('mobile-empty-add-agent-button'),
                        onPressed: onAddAgent,
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
                  relayIntents.send(
                    ReorderRelayHomePinnedEntries(
                      pinnedEntryIds: [
                        for (final entry in entries)
                          if (entry.pinned) entry.id,
                      ],
                      oldIndex: oldIndex,
                      newIndex: newIndex.clamp(0, pinnedCount).toInt(),
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

  _RenderedMobileHomeEntry _pairedDeviceEntry(RelayPeerProjection device) {
    final id = 'device:${device.id}';
    final pinned = relay.pinnedHomeEntryIds.contains(id);
    return _RenderedMobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: 0,
      child: MobilePairedDeviceListItem(
        device: device,
        entryId: id,
        pinned: pinned,
        onTogglePinned: () => relayIntents.send(ToggleRelayHomeEntryPinned(id)),
        onTap: () => onSelectDevice(device),
      ),
    );
  }

  _RenderedMobileHomeEntry _localAgentEntry(
    BuildContext context,
    AgentTargetProjection target,
  ) {
    final id = 'target:${target.id}';
    final pinned = relay.pinnedHomeEntryIds.contains(id);
    final strings = LicoStrings.of(context);
    final availability = target.available
        ? strings.active
        : strings.unavailable;
    final capability = target.capabilityLabel.trim();
    final preview = target.latestConversationPreview.trim();
    return _RenderedMobileHomeEntry(
      id: id,
      pinned: pinned,
      sortTimeMillis: target.latestConversationSortTimeMillis,
      child: MobileLocalAgentListItem(
        target: target,
        entryId: id,
        subtitle: preview.isNotEmpty
            ? preview
            : capability.isEmpty
            ? availability
            : '$availability · $capability',
        pinned: pinned,
        onTogglePinned: () => relayIntents.send(ToggleRelayHomeEntryPinned(id)),
        onTap: () => onSelect(target),
        iconBuilder: iconBuilder,
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
