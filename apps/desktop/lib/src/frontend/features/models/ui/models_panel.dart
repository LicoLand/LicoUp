import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_card.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_credentials_card.dart';
import 'package:licoup/src/frontend/features/models/ui/telegram_channel_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_value_builder.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

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
  const ModelsPanel({super.key, required this.binding, this.pane});

  final ModelsBinding binding;

  /// An explicit pane pin, or null to follow the shared pane channel and
  /// re-resolve it on every layout-state change.
  final ModelsPanelPane? pane;

  @override
  Widget build(BuildContext context) {
    final pinned = pane;
    if (pinned != null) {
      return _buildFor(context, pinned);
    }
    final state = LayoutScope.maybeOf(context)?.state;
    return LayoutValuesBuilder(
      state: state,
      valuesOf: (context) => [modelsPanelPaneOf(context)],
      builder: (context) => _buildFor(context, modelsPanelPaneOf(context)),
    );
  }

  /// Both panes inherit the standard feature-page structure
  /// ([LicoPaneScaffold]: title bar on top, content below); only the title,
  /// refresh intent, and body cards differ per pane.
  Widget _buildFor(BuildContext context, ModelsPanelPane resolvedPane) {
    final strings = LicoStrings.of(context);
    return ProjectionBuilder<ModelsProjection, ModelsProjection>(
      source: binding.projection,
      select: (projection) => projection,
      builder: (context, projection) {
        final refreshing = projection.phase == PresentationPhase.loading;
        if (resolvedPane == ModelsPanelPane.chatChannels) {
          return LicoPaneScaffold(
            title: strings.chatChannels,
            refreshTooltip: strings.refresh,
            onRefresh: refreshing
                ? null
                : () => binding.intents.send(const RefreshTelegramChannel()),
            refreshing: refreshing,
            refreshButtonKey: const Key('models-chat-channels-refresh'),
            body: ListView(
              key: const Key('models-panel-chat-channels'),
              padding: EdgeInsets.zero,
              children: [
                TelegramChannelCard(
                  projection: projection.telegram,
                  phase: projection.phase,
                  notice: projection.notice,
                  intents: binding.intents,
                ),
              ],
            ),
          );
        }
        return LicoPaneScaffold(
          title: strings.modelGateway,
          refreshTooltip: strings.refresh,
          onRefresh: refreshing
              ? null
              : () => binding.intents.send(const RefreshGateway()),
          refreshing: refreshing,
          refreshButtonKey: const Key('models-gateway-refresh'),
          body: ListView(
            key: const Key('models-panel-licoup-keys-layout-v3-gateway-first'),
            padding: EdgeInsets.zero,
            children: [
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
      },
    );
  }
}
