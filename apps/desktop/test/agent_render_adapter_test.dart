import 'dart:io';

import 'package:licoup/src/contracts/agent_render_adapter_source.dart';
import 'package:licoup/src/platform/agent_render_adapter/agent_render_adapter_service.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('agent render adapter parses document profile settings', () {
    final adapter = AgentRenderAdapter.fromJson(const {
      'id': 'claude-code',
      'displayName': 'Claude Code',
      'match': {
        'agentIds': ['claude-code'],
        'sourceClients': ['claude-code'],
      },
      'layout': {
        'assistant': 'document',
        'assistantMaxWidth': 760,
        'assistantHorizontalInset': 32,
        'showAssistantRoleLabel': false,
      },
      'userBubble': {
        'maxWidth': 620,
        'radius': 24,
        'paddingX': 18,
        'paddingY': 13,
        'tone': 'neutral',
      },
      'markdown': {
        'bodyFontSize': 15,
        'headingWeight': 800,
        'codeRadius': 16,
        'showCodeLanguage': true,
      },
      'tones': {'code': 'raised', 'quote': 'subtle'},
    });

    expect(adapter.id, 'claude-code');
    expect(adapter.assistantLayout, AgentAssistantLayout.document);
    expect(adapter.assistantMaxWidth, 760);
    expect(adapter.userBubble.radius, 24);
    expect(adapter.markdownStyle.codeRadius, 16);
    expect(adapter.markdownStyle.showCodeLanguage, isTrue);
  });

  test('agent render adapter prefers source client over host agent id', () {
    final genericCode = AgentRenderAdapter.fromJson(const {
      'id': 'code',
      'displayName': 'VS Code',
      'match': {
        'agentIds': ['code'],
      },
    });
    final copilot = AgentRenderAdapter.fromJson(const {
      'id': 'copilot',
      'displayName': 'GitHub Copilot',
      'match': {
        'agentIds': ['copilot'],
        'sourceClients': ['copilot'],
      },
    });

    expect(
      copilot.matchScore(agentId: 'code', sourceClient: 'copilot'),
      greaterThan(genericCode.matchScore(agentId: 'code')),
    );
  });

  test('fallback render adapter keeps assistant output in document layout', () {
    final fallback = AgentRenderAdapter.fallback();

    expect(fallback.assistantLayout, AgentAssistantLayout.document);
    expect(fallback.matchScore(agentId: 'unknown-agent'), 1);
  });

  test('registry resolves adapters from injected service source', () async {
    final registry = AgentRenderAdapterRegistry(
      jsonSource: _MemoryAgentRenderAdapterJsonSource([
        const {
          'id': 'mobile-copilot',
          'displayName': 'Mobile Copilot',
          'match': {
            'sourceClients': ['copilot'],
          },
          'layout': {'assistant': 'bubble'},
        },
      ]),
    );

    final adapter = await registry.resolve(
      agentId: 'code',
      sourceClient: 'copilot',
    );

    expect(adapter.id, 'mobile-copilot');
    expect(adapter.assistantLayout, AgentAssistantLayout.bubble);
  });

  test('default adapter source loads external profiles outside UI', () async {
    final root = await Directory.systemTemp.createTemp(
      'lico-agent-render-adapters-',
    );
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/index.json').writeAsString('''
{"adapters":["external.json"]}
''');
    await File('${root.path}/external.json').writeAsString('''
{"id":"external-agent","displayName":"External Agent","match":{"agentIds":["external"]}}
''');

    final source = DefaultAgentRenderAdapterJsonSource(
      environmentOverride: {
        DefaultAgentRenderAdapterJsonSource.externalRootsEnvironmentKey:
            root.path,
      },
    );

    final adapters = await source.loadAdapterJson();

    expect(adapters.map((json) => json['id']), contains('external-agent'));
  });

  test(
    'packaged Kimi adapters keep desktop and CLI identities separate',
    () async {
      final adapters =
          (await AssetAgentRenderAdapterJsonSource().loadAdapterJson())
              .map(AgentRenderAdapter.fromJson)
              .toList(growable: false);
      final desktop = adapters.singleWhere((adapter) => adapter.id == 'kimi');
      final cli = adapters.singleWhere((adapter) => adapter.id == 'kimi-code');

      expect(desktop.displayName, 'Kimi - Desktop');
      expect(cli.displayName, 'Kimi Code - CLI');
      expect(desktop.matchScore(agentId: 'kimi'), greaterThan(0));
      expect(desktop.matchScore(agentId: 'kimi-code'), 0);
      expect(cli.matchScore(agentId: 'kimi-code'), greaterThan(0));
      expect(cli.matchScore(agentId: 'kimi'), 0);
    },
  );
}

class _MemoryAgentRenderAdapterJsonSource
    implements AgentRenderAdapterJsonSource {
  const _MemoryAgentRenderAdapterJsonSource(this.adapters);

  final List<Map<String, dynamic>> adapters;

  @override
  Future<List<Map<String, dynamic>>> loadAdapterJson() async => adapters;
}
