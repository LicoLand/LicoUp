import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_card.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_credentials_card.dart';
import 'package:licoup/src/frontend/features/models/ui/telegram_channel_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';

enum ModelsPanelPane { gateway, chatChannels }

ModelsPanelPane modelsPanelPaneOf(BuildContext context) {
  final tab = LayoutScope.maybeOf(
    context,
  )?.state.readIfDeclared(LayoutStateChannels.communicationSection);
  return tab is LayoutTabState && tab.index == 1
      ? ModelsPanelPane.chatChannels
      : ModelsPanelPane.gateway;
}

final class ModelsPanel extends StatelessWidget {
  const ModelsPanel({
    super.key,
    required this.binding,
    this.pane = ModelsPanelPane.gateway,
  });

  final ModelsBinding binding;
  final ModelsPanelPane pane;

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<ModelsProjection, ModelsProjection>(
      source: binding.projection,
      select: (projection) => projection,
      builder: (context, projection) => pane == ModelsPanelPane.chatChannels
          ? ListView(
              key: const Key('models-panel-chat-channels'),
              padding: MessagingDesktopMetrics.mainPanePadding,
              children: [
                TelegramChannelCard(
                  projection: projection.telegram,
                  phase: projection.phase,
                  notice: projection.notice,
                  intents: binding.intents,
                ),
              ],
            )
          : ListView(
              key: const Key(
                'models-panel-licoup-keys-layout-v3-gateway-first',
              ),
              padding: MessagingDesktopMetrics.mainPanePadding,
              children: [
                Text(
                  LicoStrings.of(context).modelGateway,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                LlmGatewayCard(
                  projection: projection.gateway,
                  phase: projection.phase,
                  notice: projection.notice,
                  intents: binding.intents,
                  belowDivider: LlmGatewayCredentialsCard(
                    credentials: projection.credentials,
                    gatewayRunning: projection.gateway.running,
                    phase: projection.phase,
                    notice: projection.notice,
                    intents: binding.intents,
                  ),
                ),
              ],
            ),
    );
  }
}
