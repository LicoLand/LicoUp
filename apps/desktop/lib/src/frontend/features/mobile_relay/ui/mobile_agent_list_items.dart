import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_home_entry_ordering.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_swipe_pin_action.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class MobilePairedDeviceListItem extends StatelessWidget {
  const MobilePairedDeviceListItem({
    super.key,
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

final class MobileLocalAgentListItem extends StatelessWidget {
  const MobileLocalAgentListItem({
    super.key,
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

final class _MobileListTile extends StatelessWidget {
  const _MobileListTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.entryId,
    required this.pinned,
    required this.onTogglePinned,
    required this.onTap,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final String entryId;
  final bool pinned;
  final VoidCallback onTogglePinned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MobileSwipePinAction(
      entryId: entryId,
      pinned: pinned,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
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
                        mobileHomePreviewText(subtitle),
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
