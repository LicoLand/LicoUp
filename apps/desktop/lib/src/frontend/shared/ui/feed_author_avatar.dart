import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/provider_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Feed / post author avatar that prefers agent and provider brand marks.
class FeedAuthorAvatar extends StatelessWidget {
  const FeedAuthorAvatar({
    super.key,
    required this.author,
    this.size = 36,
    this.iconSize = 22,
  });

  final AgentFeedAuthor author;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final targetId = author.targetId?.trim() ?? '';
    if (targetId.isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: AgentBrandIcon(
            target: TargetCandidate(
              target: targetId,
              label: author.displayName.trim().isNotEmpty
                  ? author.displayName
                  : targetId,
              kind: 'agent',
              status: 'detected',
              configured: true,
              confidence: 1,
              adapterStatus: 'ready',
            ),
            size: size,
            iconSize: iconSize,
          ),
        ),
      );
    }
    final accountId = author.accountId?.trim() ?? '';
    if (accountId.isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: ProviderBrandIcon(
            providerId: accountId,
            color: colors.primary,
            size: iconSize,
          ),
        ),
      );
    }
    final name = author.displayName.trim();
    final initial = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: author.isAgent
          ? colors.primary.withAlpha(40)
          : colors.info.withAlpha(50),
      child: Text(
        initial,
        style: TextStyle(
          color: author.isAgent ? colors.primary : colors.info,
          fontSize: iconSize * 0.64,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
