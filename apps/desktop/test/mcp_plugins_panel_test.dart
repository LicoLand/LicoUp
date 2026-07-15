import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/panel_frame.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MCP plugin panel shows agent cards and configure popup', (
    tester,
  ) async {
    final controller = ClientController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        configPath: '/tmp/codex/config.toml',
        adapterStatus: 'partial',
        supportedActions: const [
          'mcp.plugin.status',
          'mcp.plugin.update',
          'mcp.plugin.rollback',
          'mcp.config.plan',
        ],
      ),
      TargetCandidate(
        target: 'claude-code',
        label: 'Claude Code',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        configPath: '/tmp/claude/settings.json',
        adapterStatus: 'implemented',
        supportedActions: const [
          'mcp.plugin.status',
          'mcp.plugin.update',
          'mcp.plugin.rollback',
        ],
      ),
      TargetCandidate(
        target: 'cursor',
        label: 'Cursor',
        kind: 'ide',
        status: 'detected',
        configured: true,
        confidence: 0.9,
        configPath: '/tmp/cursor/mcp.json',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationProtocol': 'cursor-acp-v1',
          'conversationReadiness': 'unverified',
          'conversationCapabilityMatrix': {'laneFamily': 'acp'},
        },
        supportedActions: const [
          'mcp.plugin.status',
          'mcp.plugin.update',
          'mcp.plugin.rollback',
        ],
      ),
      TargetCandidate(
        target: 'code',
        label: 'VS Code',
        kind: 'desktop-agent',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        configPath: '/tmp/code/settings.json',
        adapterStatus: 'unsupported',
        supportedActions: const ['mcp.plugin.status'],
      ),
      TargetCandidate(
        target: 'copilot',
        label: 'Copilot',
        kind: 'cli',
        status: 'detected',
        configured: false,
        confidence: 0.9,
        detail:
            'binary: ${['', 'opt', 'homebrew', 'bin', 'copilot'].join('/')}',
        adapterStatus: '',
        supportedActions: const ['mcp.plugin.status'],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: SizedBox(
          width: 1100,
          height: 720,
          child: McpPluginsPanel(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(PanelFrame), findsNothing);
    expect(find.byKey(const Key('mcp-plugins-agent-grid')), findsOneWidget);
    expect(find.byKey(const Key('mcp-plugin-card-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('mcp-plugin-card-claude-code')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mcp-plugin-card-cursor')), findsOneWidget);
    expect(find.byKey(const Key('mcp-plugin-card-copilot')), findsOneWidget);
    expect(find.byKey(const Key('mcp-plugin-card-code')), findsNothing);
    expect(find.text('LicoLite MCP Plugins'), findsNothing);
    expect(find.text('Codex / LicoLite MCP'), findsNothing);
    expect(find.text('VS Code / LicoLite MCP'), findsNothing);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('VS Code'), findsNothing);
    expect(find.text('Copilot'), findsOneWidget);
    expect(find.text('Configure'), findsWidgets);
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Not configured'), findsWidgets);
    expect(find.byType(AgentBrandIcon), findsNWidgets(4));
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
    expect(find.text('MCP plugin'), findsNothing);
    expect(find.text('ACP plugin'), findsNothing);
    expect(find.text('Reinstall'), findsNothing);
    expect(find.text('Install'), findsNothing);
    expect(find.text('Update'), findsNothing);

    await tester.tap(find.byKey(const Key('mcp-plugin-card-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mcp-plugin-config-card-codex')), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mcp-plugin-card-codex')),
        matching: find.byKey(const Key('mcp-plugin-configure-button')),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('mcp-plugin-config-card-codex')),
      findsOneWidget,
    );
    expect(find.text('MCP plugin'), findsOneWidget);
    expect(find.text('ACP plugin'), findsOneWidget);
    expect(find.text('/tmp/codex/config.toml'), findsOneWidget);
    expect(find.text('Reinstall'), findsOneWidget);
    expect(find.text('Unsupported'), findsWidgets);
    expect(find.byIcon(Icons.block), findsWidgets);
    expect(find.byIcon(Icons.open_in_new_outlined), findsWidgets);

    Navigator.of(
      tester.element(find.byKey(const Key('mcp-plugin-config-card-codex'))),
    ).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mcp-plugin-card-claude-code')),
        matching: find.byKey(const Key('mcp-plugin-configure-button')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mcp-plugin-config-card-claude-code')),
      findsOneWidget,
    );
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('/tmp/claude/settings.json'), findsOneWidget);

    Navigator.of(
      tester.element(
        find.byKey(const Key('mcp-plugin-config-card-claude-code')),
      ),
    ).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mcp-plugin-card-cursor')),
        matching: find.byKey(const Key('mcp-plugin-configure-button')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('mcp-plugin-config-card-cursor')),
      findsOneWidget,
    );
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Unverified'), findsWidgets);
    expect(find.byIcon(Icons.priority_high_rounded), findsWidgets);
    expect(find.byIcon(Icons.check_circle_outline_rounded), findsWidgets);
  });

  test('TargetCandidate derives MCP and ACP support from real metadata', () {
    final mcpOnly = TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      adapterStatus: 'partial',
      adapterCapabilities: const {
        'conversationProtocol': 'codex-app-server',
        'conversationCapabilityMatrix': {'laneFamily': 'app-server'},
      },
      supportedActions: const ['mcp.plugin.status', 'mcp.config.plan'],
    );
    final acpReady = TargetCandidate(
      target: 'cursor',
      label: 'Cursor',
      kind: 'ide',
      status: 'detected',
      configured: true,
      confidence: 1,
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'conversationProtocol': 'cursor-acp-v1',
        'conversationCapabilityMatrix': {'laneFamily': 'acp'},
      },
      supportedActions: const ['mcp.plugin.status', 'mcp.plugin.update'],
    );
    final unsupported = TargetCandidate(
      target: 'copilot',
      label: 'Copilot',
      kind: 'cli',
      status: 'detected',
      configured: false,
      confidence: 1,
      adapterStatus: 'unsupported',
      supportedActions: const ['mcp.plugin.status'],
    );

    expect(mcpOnly.supportsMcpPluginInstall, isTrue);
    expect(mcpOnly.supportsAcpPlugin, isFalse);
    expect(acpReady.supportsMcpPluginInstall, isTrue);
    expect(acpReady.supportsAcpPlugin, isTrue);
    expect(unsupported.supportsMcpPluginInstall, isFalse);
    expect(unsupported.supportsAcpPlugin, isFalse);
  });
}
