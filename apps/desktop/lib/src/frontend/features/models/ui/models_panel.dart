import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_card.dart';
import 'package:licoup/src/frontend/features/models/ui/llm_gateway_credentials_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Top-level Keys destination: model API keys, the local LLM gateway
/// entrypoint, and the agents that consume it — lifted out of Settings into
/// its own sidebar navigation entry.
final class ModelsPanel extends StatelessWidget {
  const ModelsPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ListView(
      key: const Key('models-panel'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Text(
          strings.keys,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        LlmGatewayCredentialsCard(
          agentService: controller.agentService,
          authorization: controller.llmVaultAuthorization,
        ),
        const SizedBox(height: 16),
        LlmGatewayCard(
          agentService: controller.agentService,
          authorization: controller.llmVaultAuthorization,
          readSettings: controller.agentWorkspaceReadSettingsState,
          writeSettings: controller.agentWorkspaceWriteSettingsState,
          lifecycleController: controller.llmGatewayLifecycleController,
        ),
      ],
    );
  }
}
