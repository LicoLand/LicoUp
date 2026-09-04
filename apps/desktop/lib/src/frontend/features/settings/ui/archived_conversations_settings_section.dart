import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/lico_surface.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

class ArchivedConversationsSettingsSection extends StatefulWidget {
  const ArchivedConversationsSettingsSection({
    super.key,
    required this.binding,
  });

  final SettingsBinding binding;

  @override
  State<ArchivedConversationsSettingsSection> createState() =>
      _ArchivedConversationsSettingsSectionState();
}

class _ArchivedConversationsSettingsSectionState
    extends State<ArchivedConversationsSettingsSection> {
  final _searchController = TextEditingController();
  final _restoringIds = <String>{};
  final _pendingRestoreTitles = <String, String>{};
  StreamSubscription<SettingsEffect>? _restoreSubscription;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    _listenForRestoreResults();
    widget.binding.intents.send(const RefreshArchivedConversations());
  }

  @override
  void didUpdateWidget(ArchivedConversationsSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      unawaited(_restoreSubscription?.cancel());
      _listenForRestoreResults();
      widget.binding.intents.send(const RefreshArchivedConversations());
    }
  }

  void _listenForRestoreResults() {
    _restoreSubscription = widget.binding.effects.effects.listen((effect) {
      if (effect case ArchivedConversationRestoreCompleted()) {
        _handleRestoreResult(effect);
      }
    });
  }

  void _handleRestoreResult(ArchivedConversationRestoreCompleted result) {
    final title = _pendingRestoreTitles.remove(result.conversationId);
    if (!mounted) return;
    setState(() => _restoringIds.remove(result.conversationId));
    if (result.restored && title != null) {
      final strings = LicoStrings.of(context);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(strings.conversationRestored(title))),
      );
    }
  }

  void _handleSearchChanged() {
    if (mounted) setState(() {});
  }

  void _restore(ArchivedConversationProjection conversation) {
    if (_restoringIds.contains(conversation.id)) return;
    setState(() {
      _restoringIds.add(conversation.id);
      _pendingRestoreTitles[conversation.id] = conversation.title;
    });
    widget.binding.intents.send(RestoreArchivedConversation(conversation.id));
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_handleSearchChanged)
      ..dispose();
    unawaited(_restoreSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final presentation = layoutSettingsPresentationOf(context);
    return ProjectionBuilder<SettingsProjection, SettingsProjection>(
      source: widget.binding.projection,
      select: _settingsIdentity,
      builder: (context, projection) {
        final archived = projection.archivedConversations;
        final query = _searchController.text.trim().toLowerCase();
        final visible = query.isEmpty
            ? archived
            : archived
                  .where(
                    (conversation) =>
                        conversation.title.toLowerCase().contains(query),
                  )
                  .toList(growable: false);
        final notice = projection.notice;
        final failureStage =
            notice?.id.startsWith('settings-conversation-') == true
            ? notice!.id.substring('settings-conversation-'.length)
            : '';
        final failureCode = notice?.reasonCode ?? '';
        final hasFailure =
            failureCode.isNotEmpty &&
            (failureStage == 'archived-list' || failureStage == 'restore');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LicoSectionHeader(
              title: strings.archivedConversationsTitle,
              leading: Icon(
                Icons.archive_outlined,
                size: 18,
                color: colors.textSecondary,
              ),
              padding: presentation.sectionHeaderPadding,
            ),
            Padding(
              padding: presentation.rowPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('archived-conversation-search'),
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: strings.searchArchivedConversations,
                      prefixIcon: const Icon(Icons.search_outlined, size: 20),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: strings.clearSearch,
                              onPressed: _searchController.clear,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                    ),
                  ),
                  const SizedBox(height: LicoContentSpacing.compact),
                  Text(
                    strings.archivedConversationsHint,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(height: LicoContentSpacing.item),
                  if (hasFailure) ...[
                    LicoSurface(
                      key: const Key('archived-conversation-failure'),
                      tone: LicoSurfaceTone.danger,
                      elevation: LicoElevation.flat,
                      padding: const EdgeInsets.all(LicoContentSpacing.item),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colors.error,
                            size: 18,
                          ),
                          const SizedBox(width: LicoContentSpacing.compact),
                          Expanded(
                            child: Text(
                              strings.archivedConversationFailure(
                                failureStage,
                                failureCode,
                              ),
                            ),
                          ),
                          if (failureStage == 'archived-list')
                            TextButton(
                              onPressed:
                                  projection.phase == PresentationPhase.applying
                                  ? null
                                  : () => widget.binding.intents.send(
                                      const RefreshArchivedConversations(),
                                    ),
                              child: Text(strings.retry),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: LicoContentSpacing.item),
                  ],
                  if (projection.phase == PresentationPhase.applying &&
                      archived.isEmpty)
                    const _ArchivedConversationsLoading()
                  else if (visible.isEmpty)
                    LicoSurface(
                      elevation: LicoElevation.flat,
                      child: LicoEmptyState(
                        key: const Key('archived-conversation-empty'),
                        icon: query.isEmpty
                            ? Icons.archive_outlined
                            : Icons.search_off_outlined,
                        title: query.isEmpty
                            ? strings.noArchivedConversations
                            : strings.noMatchingArchivedConversations,
                      ),
                    )
                  else
                    LicoSurface(
                      key: const Key('archived-conversation-list'),
                      elevation: LicoElevation.flat,
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (
                            var index = 0;
                            index < visible.length;
                            index++
                          ) ...[
                            _ArchivedConversationRow(
                              conversation: visible[index],
                              restoring: _restoringIds.contains(
                                visible[index].id,
                              ),
                              onRestore: () => _restore(visible[index]),
                            ),
                            if (index != visible.length - 1)
                              Divider(height: 1, color: colors.line),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ArchivedConversationsLoading extends StatelessWidget {
  const _ArchivedConversationsLoading();

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return LicoSurface(
      key: const Key('archived-conversation-loading'),
      elevation: LicoElevation.flat,
      padding: const EdgeInsets.all(LicoContentSpacing.section),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: LicoContentSpacing.compact),
          Text(strings.loading),
        ],
      ),
    );
  }
}

class _ArchivedConversationRow extends StatelessWidget {
  const _ArchivedConversationRow({
    required this.conversation,
    required this.restoring,
    required this.onRestore,
  });

  final ArchivedConversationProjection conversation;
  final bool restoring;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final localizations = MaterialLocalizations.of(context);
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(
      conversation.updatedAtUnixMs,
    );
    final updatedLabel =
        '${localizations.formatMediumDate(updatedAt)} · '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(updatedAt))}';
    final metadata = conversation.isGroup
        ? '${strings.groupConversationMemberCount(conversation.membershipCount)} · $updatedLabel'
        : updatedLabel;
    final restoreButton = FilledButton.tonalIcon(
      key: Key('restore-archived-conversation-${conversation.id}'),
      onPressed: restoring ? null : onRestore,
      icon: restoring
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.unarchive_outlined, size: 17),
      label: Text(strings.restore),
    );
    final rowContent = Row(
      children: [
        Icon(
          conversation.isGroup
              ? Icons.forum_outlined
              : Icons.chat_bubble_outline,
          size: 20,
          color: colors.textMuted,
        ),
        const SizedBox(width: LicoContentSpacing.item),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: LicoContentSpacing.inline),
              Text(
                metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      key: Key('archived-conversation-row-${conversation.id}'),
      padding: const EdgeInsets.all(LicoContentSpacing.item),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                rowContent,
                const SizedBox(height: LicoContentSpacing.compact),
                Align(alignment: Alignment.centerRight, child: restoreButton),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: rowContent),
              const SizedBox(width: LicoContentSpacing.item),
              restoreButton,
            ],
          );
        },
      ),
    );
  }
}

SettingsProjection _settingsIdentity(SettingsProjection value) => value;
