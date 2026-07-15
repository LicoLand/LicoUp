import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentFeedFollowingSheet extends StatelessWidget {
  const AgentFeedFollowingSheet({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final following = controller.feedTimeline.following;

    final suggestions = _buildSuggestions(controller, following);

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.line.withAlpha(100)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.following,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: colors.textMuted),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: following.isEmpty && suggestions.isEmpty
                ? _EmptyFollowing(strings: strings)
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (following.isNotEmpty) ...[
                        _SectionHeader(title: strings.following),
                        for (final item in following)
                          _AuthorTile(
                            author: item.author,
                            trailing: TextButton(
                              onPressed: () =>
                                  controller.toggleFollowAuthor(item.author),
                              child: Text(
                                strings.unfollow,
                                style: TextStyle(
                                  color: colors.textMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                      if (suggestions.isNotEmpty) ...[
                        _SectionHeader(title: strings.addToFollowing),
                        for (final author in suggestions)
                          _AuthorTile(
                            author: author,
                            trailing: TextButton(
                              onPressed: () =>
                                  controller.toggleFollowAuthor(author),
                              child: Text(
                                strings.follow,
                                style: TextStyle(
                                  color: colors.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<AgentFeedAuthor> _buildSuggestions(
    ClientController controller,
    List<AgentFeedFollowing> following,
  ) {
    final followedIds = following.map((f) => f.author.id).toSet();
    final suggestions = <AgentFeedAuthor>[];
    for (final target in controller.scannedTargets.where(
      (t) => t.visibleInClient,
    )) {
      final author = AgentFeedAuthor(
        id: 'target:${target.target}',
        displayName: target.label.trim().isNotEmpty
            ? target.label
            : target.target,
        isAgent: true,
        targetId: target.target,
      );
      if (!followedIds.contains(author.id)) {
        suggestions.add(author);
      }
    }
    for (final account in controller.mobileAgentAccounts) {
      final author = AgentFeedAuthor(
        id: 'account:${account.id}',
        displayName: account.label.trim().isNotEmpty
            ? account.label
            : account.provider.label,
        isAgent: true,
        accountId: account.id,
      );
      if (!followedIds.contains(author.id)) {
        suggestions.add(author);
      }
    }
    return suggestions;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AuthorTile extends StatelessWidget {
  const _AuthorTile({required this.author, required this.trailing});

  final AgentFeedAuthor author;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return ListTile(
      dense: true,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Icon(
            author.isAgent ? Icons.smart_toy_outlined : Icons.person_outline,
            size: 18,
            color: colors.textMuted,
          ),
        ),
      ),
      title: Text(
        author.displayName,
        style: TextStyle(
          color: colors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Builder(
        builder: (context) {
          final sectionStrings = LicoStrings.of(context);
          return Text(
            author.isAgent
                ? sectionStrings.myAgents
                : sectionStrings.otherUsers,
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          );
        },
      ),
      trailing: trailing,
    );
  }
}

class _EmptyFollowing extends StatelessWidget {
  const _EmptyFollowing({required this.strings});

  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          strings.followingEmpty,
          style: TextStyle(color: colors.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}
