import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_card.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_credentials_card.dart';
import 'package:licoup/src/frontend/features/models/ui/telegram_channel_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

enum ModelsPanelPane { gateway, chatChannels }

ModelsPanelPane modelsPanelPaneOf(BuildContext context) {
  final tab = LayoutScope.maybeOf(
    context,
  )?.state.readIfDeclared(LayoutStateChannels.communicationSection);
  if (tab is LayoutTabState && tab.index == 1) {
    return ModelsPanelPane.chatChannels;
  }
  return ModelsPanelPane.gateway;
}

/// Models destination: the local LLM gateway, or the chat-channel pane that
/// hosts Telegram. Telegram is no longer stacked under the gateway body.
final class ModelsPanel extends StatelessWidget {
  const ModelsPanel({
    super.key,
    required this.controller,
    this.pane = ModelsPanelPane.gateway,
  });

  final ClientController controller;
  final ModelsPanelPane pane;

  @override
  Widget build(BuildContext context) {
    if (pane == ModelsPanelPane.chatChannels) {
      return ListView(
        key: const Key('models-panel-chat-channels'),
        padding: MessagingDesktopMetrics.mainPanePadding,
        children: [
          TelegramChannelCard(
            agentService: controller.agentService,
            lifecycleController: controller.llmGatewayLifecycleController,
          ),
        ],
      );
    }
    final strings = LicoStrings.of(context);
    return ListView(
      // Release AOT keeps ValueKey/Key strings; use this as an install canary.
      key: const Key('models-panel-licoup-keys-layout-v3-gateway-first'),
      padding: MessagingDesktopMetrics.mainPanePadding,
      children: [
        Text(
          strings.modelGateway,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        LlmGatewayCard(
          agentService: controller.agentService,
          authorization: controller.llmVaultAuthorization,
          readSettings: controller.agentWorkspaceReadSettingsState,
          writeSettings: controller.agentWorkspaceWriteSettingsState,
          lifecycleController: controller.llmGatewayLifecycleController,
          belowDivider: LlmGatewayCredentialsCard(
            agentService: controller.agentService,
            authorization: controller.llmVaultAuthorization,
            lifecycleController: controller.llmGatewayLifecycleController,
          ),
        ),
      ],
    );
  }
}
