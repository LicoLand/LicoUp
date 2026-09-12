import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/models/ui/telegram_channel_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Chat channel controls live beside device pairing and keep their own state.
final class MobilePairingChannels extends StatelessWidget {
  const MobilePairingChannels({super.key, required this.binding});

  final ModelsBinding binding;

  @override
  Widget build(BuildContext context) =>
      ProjectionBuilder<ModelsProjection, ModelsProjection>(
        source: binding.projection,
        select: (projection) => projection,
        builder: (context, projection) {
          final strings = LicoStrings.of(context);
          final loading = projection.phase == PresentationPhase.loading;
          return Column(
            key: const Key('mobile-pairing-chat-channels'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.chatChannels,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('models-chat-channels-refresh'),
                    onPressed: loading
                        ? null
                        : () => binding.intents.send(
                            const RefreshTelegramChannel(),
                          ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(strings.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TelegramChannelCard(
                projection: projection.telegram,
                phase: projection.phase,
                notice: projection.notice,
                intents: binding.intents,
              ),
            ],
          );
        },
      );
}
