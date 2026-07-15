import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/proxy_bridge_settings_widgets.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class ProxyBridgeSettings extends StatelessWidget {
  const ProxyBridgeSettings({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final busy = controller.isProxyBridgeBusy;
    final statusMap = controller.proxyBridgeStatus ?? const {};
    final planMap = controller.proxyBridgePlan ?? const {};
    final proxyUrl = controller.proxyBridgeProxyUrl.isEmpty
        ? 'http://127.0.0.1:7897'
        : controller.proxyBridgeProxyUrl;
    final tunAssist = proxyBridgeMap(planMap['tunAssist']).isNotEmpty
        ? proxyBridgeMap(planMap['tunAssist'])
        : tunAssistFromProxyBridgeStatus(statusMap);
    final yamlSnippet = (tunAssist['yamlSnippet'] ?? '').toString();
    final wrapperRoot = proxyBridgeWrapperRoot(statusMap, planMap);
    final selectedTargets = controller.proxyBridgeAvailableTargets;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.hub_outlined, color: colors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.proxyBridge,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      strings.proxyBridgeDescription,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: strings.proxyBridgeDetect,
                onPressed: busy
                    ? null
                    : () => unawaited(controller.refreshProxyBridgeStatus()),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined, size: 18),
              ),
              Switch.adaptive(
                value: controller.proxyBridgeEnabled,
                onChanged: busy
                    ? null
                    : (enabled) {
                        unawaited(
                          enabled
                              ? controller.applyProxyBridge()
                              : controller.rollbackProxyBridge(),
                        );
                      },
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Status indicators
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ProxyBridgeStatusPill(
                icon: controller.proxyBridgeEnabled
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
                label: controller.proxyBridgeEnabled
                    ? strings.proxyBridgeEnabled
                    : strings.proxyBridgeDisabled,
              ),
              ProxyBridgeStatusPill(
                icon: controller.proxyBridgeReachable
                    ? Icons.lan_outlined
                    : Icons.lan_outlined,
                label: controller.proxyBridgeReachable
                    ? strings.proxyBridgeReachable
                    : strings.proxyBridgeUnreachable,
              ),
              ProxyBridgeStatusPill(icon: Icons.link_outlined, label: proxyUrl),
            ],
          ),
          if (wrapperRoot.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              wrapperRoot,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontFamily: 'monospace',
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          const SizedBox(height: 14),
          // Agent selection
          Text(
            strings.proxyBridgeAgents,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final target in selectedTargets)
                FilterChip(
                  label: Text(proxyBridgeTargetLabel(target)),
                  selected: controller.isProxyBridgeTargetSelected(target),
                  onSelected: busy
                      ? null
                      : (selected) => controller.setProxyBridgeTargetSelected(
                          target,
                          selected,
                        ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // Actions
          Row(
            children: [
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => unawaited(controller.applyProxyBridge()),
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: Text(strings.proxyBridgeEnable),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => unawaited(controller.planProxyBridge()),
                icon: const Icon(Icons.rule_outlined, size: 15),
                label: Text(strings.proxyBridgePlan),
              ),
              const SizedBox(width: 8),
              if (controller.proxyBridgeEnabled)
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => unawaited(controller.rollbackProxyBridge()),
                  icon: const Icon(Icons.stop_circle_outlined, size: 15),
                  label: Text(strings.proxyBridgeDisable),
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                ),
            ],
          ),
          // TUN Assist (collapsible appearance)
          if (yamlSnippet.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              strings.proxyBridgeTunAssist,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              strings.proxyBridgeNoClashMutation,
              style: TextStyle(
                fontSize: 11,
                color: colors.textMuted.withAlpha(160),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                yamlSnippet,
                style: TextStyle(
                  color: colors.text,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              strings.proxyBridgeTunAssist,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              strings.proxyBridgeNoClashMutation,
              style: TextStyle(
                fontSize: 11,
                color: colors.textMuted.withAlpha(160),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
