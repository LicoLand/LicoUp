import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_identity.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/conversation_visual_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The demo's `.av-mosaic`: a 2x2 grid of square member tiles, the local
/// user's cell first, under a single rounded-square clip. Cells are flat
/// tiles — mascot art fills the cell, agent marks sit centered at 58% over a
/// brand-hue wash — never circular wells. With no resolvable member cells it
/// falls back to the generic group mark so empty rosters still read as a
/// group.
final class MessagingGroupMosaicAvatar extends StatelessWidget {
  const MessagingGroupMosaicAvatar({
    super.key,
    required this.rosterTargets,
    required this.hasLocalOwner,
    required this.extent,
    this.selfMascotId,
  });

  final List<TargetCandidate> rosterTargets;
  final String? selfMascotId;

  /// The mosaic's corner radius follows the profile's avatar language:
  /// a full circle on Desktop, a rounded square elsewhere — the same
  /// geometry [MessagingSelfAvatar] resolves for user avatars.
  double cornerRadiusFor(BuildContext context) =>
      MessagingSelfAvatar.circularFor(context) ? extent / 2 : extent * 0.27;

  final bool hasLocalOwner;
  final double extent;

  Widget _selfCell(LicoThemeColors colors, double cellExtent) {
    return ValueListenableBuilder<String>(
      valueListenable: selfMascotIdentity,
      builder: (context, sessionMascot, _) {
        final mascot = selfMascotId ?? sessionMascot;
        if (MascotCatalog.avatars.containsKey(mascot)) {
          return ColoredBox(
            color: (colors.isDark
                ? LicoPaneGlass.contentInnerCardFill
                : colors.surfaceLow),
            child: MascotImage.figure(
              mascot,
              semanticLabel: 'avatar',
              size: cellExtent,
            ),
          );
        }
        return ColoredBox(
          color: (colors.isDark
              ? LicoPaneGlass.contentInnerCardFill
              : colors.surfaceLow),
          child: Icon(
            Icons.person_outline_rounded,
            size: cellExtent * 0.55,
            color: colors.textMuted,
          ),
        );
      },
    );
  }

  Widget _agentCell(
    LicoThemeColors colors,
    TargetCandidate target,
    double cellExtent,
  ) {
    return ColoredBox(
      color: (colors.isDark
          ? LicoPaneGlass.contentInnerCardFill
          : colors.surfaceLow),
      child: Center(
        child: AgentBrandIcon(
          target: target,
          size: cellExtent,
          iconSize: cellExtent * 0.58,
          detected:
              target.status == TargetCandidateStatus.detected ||
              target.configured,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final cornerRadius = cornerRadiusFor(context);
    final cellExtent = (extent - 1) / 2;
    final cells = <Widget>[
      if (hasLocalOwner) _selfCell(colors, cellExtent),
      for (final target in rosterTargets.take(4 - (hasLocalOwner ? 1 : 0)))
        _agentCell(colors, target, cellExtent),
    ];
    if (cells.isEmpty) {
      return Container(
        width: extent,
        height: extent,
        decoration: BoxDecoration(
          color: ConversationVisualTokens.identityWellFill(colors),
          borderRadius: BorderRadius.circular(cornerRadius),
        ),
        child: Icon(
          Icons.groups_2_rounded,
          color: ConversationVisualTokens.groupIdentityMark(colors),
          size: extent * 0.52,
        ),
      );
    }
    while (cells.length < 4) {
      cells.add(const SizedBox.shrink());
    }

    return Container(
      width: extent,
      height: extent,
      decoration: BoxDecoration(
        color: colors.line,
        borderRadius: BorderRadius.circular(cornerRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: cells[0]),
                const SizedBox(width: 1),
                Expanded(child: cells[1]),
              ],
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(child: cells[2]),
                const SizedBox(width: 1),
                Expanded(child: cells[3]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
