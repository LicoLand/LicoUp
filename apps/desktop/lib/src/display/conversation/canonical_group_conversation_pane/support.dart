import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class CanonicalGroupFailureCapsule extends StatelessWidget {
  const CanonicalGroupFailureCapsule({
    super.key,
    required this.code,
    required this.failureRef,
    required this.recovery,
    required this.copyBlob,
    required this.onCopy,
  });

  final String code;
  final String failureRef;
  final String recovery;
  final String copyBlob;
  final Future<void> Function(String) onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final reference = failureRef.isEmpty ? code : failureRef;
    final guidance = strings.groupConversationFailureRecovery(recovery);
    const radius =
        MessagingDesktopMetrics.conversationHeaderCapsuleCornerRadius;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: DecoratedBox(
        key: const Key('canonical-group-failure'),
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: colors.error, width: 1.25),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.groupConversationFailureSummary(code, reference),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.error,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (guidance.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        guidance,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              LicoIconButton(
                key: const Key('canonical-group-failure-copy'),
                icon: Icon(Icons.copy_outlined, color: colors.error),
                tooltip: strings.copyFailureReport,
                size: LicoIconButtonSize.small,
                shape: LicoIconButtonShape.concentric,
                radius: LicoRadius.nested(radius, 6),
                onPressed: () => unawaited(onCopy(copyBlob)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CanonicalGroupLoadingOrEmpty extends StatelessWidget {
  const CanonicalGroupLoadingOrEmpty({super.key, required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const CircularProgressIndicator()
          else
            Icon(Icons.groups_2_outlined, size: 30, color: colors.textMuted),
          const SizedBox(height: 12),
          Text(
            loading
                ? strings.loadingNativeHistories
                : strings.groupConversation,
            style: TextStyle(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
