import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationFilteringScenarios() {
  test('filters background instruction blocks from visible conversations', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-context',
      'agentId': 'codex',
      'title':
          '<apps_instructions>\n# Apps (Connectors)\nDo not show this.\n</appsinstructions>',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:01Z',
      'messages': [
        {
          'id': 'msg-context',
          'role': 'user',
          'text':
              '<apps_instructions>\n# Apps (Connectors)\nConnector instructions.\n</appsinstructions>',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-system',
          'role': 'system',
          'text': 'You are Codex, a coding agent.',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-user',
          'role': 'user',
          'text':
              '# Files mentioned by the user:\n\n## clip.png: ${['', 'private', 'tmp', 'clip.png'].join('/')}\n\n## My request for Codex:\n真正的用户问题\n<image name=[Image #1] path="${['', 'private', 'tmp', 'clip.png'].join('/')}">\nprivate image metadata\n</image>',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '真正的回答',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '真正的用户问题');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '真正的用户问题',
      '真正的回答',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('Apps (Connectors)') ||
            message.text.contains(
              ['', 'private', 'tmp', 'clip.png'].join('/'),
            ) ||
            message.text.contains('You are Codex'),
      ),
      isFalse,
    );
  });

  test('decodes Antigravity protocol wrappers from native history', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-antigravity-protocol',
      'agentId': 'antigravity',
      'adapterId': 'antigravity',
      'sourceClient': 'antigravity',
      'hostApp': 'antigravity',
      'title': '<USER_REQUEST> 请找到本项目的开发规则文档入口 </USER_REQUEST>',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': '''
<SYSTEM_MESSAGE>
Hidden Antigravity runtime context.
</SYSTEM_MESSAGE>
<USER_REQUEST>请找到本项目的开发规则文档入口</USER_REQUEST>''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-system-boilerplate',
          'role': 'agent',
          'text':
              'The following is a <SYSTEM_MESSAGE> not actually sent by the user. It is provided by the system as important information to pay attention to.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-file-view',
          'role': 'view_file',
          'text': '''
2255 │ "coverageContribution": false,
2256 │ "artifacts": [],
2257 │ "command": "npm"
2258 │ "args": [
2259 │   "run",
2260 │   "verify"
2261 │ ]''',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-command',
          'role': 'run_command',
          'text': 'npm run verify\nPASS 133 tests',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'planner_response',
          'text': '开发规则入口在仓库根目录的 AGENTS.md。',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '请找到本项目的开发规则文档入口');
    expect(session.messageCount, 4);
    expect(session.messages[0].text, '请找到本项目的开发规则文档入口');
    expect(session.messages[1].kind, AgentConversationMessageKind.toolCall);
    expect(session.messages[1].cardTitle, 'Tool call');
    expect(session.messages[1].text, contains('coverageContribution'));
    expect(session.messages[1].text, contains('2255'));
    expect(session.messages[2].kind, AgentConversationMessageKind.toolCall);
    expect(session.messages[2].text, 'npm run verify\nPASS 133 tests');
    expect(session.messages[3].text, '开发规则入口在仓库根目录的 AGENTS.md。');
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('<USER_REQUEST>') ||
            message.text.contains('<SYSTEM_MESSAGE>') ||
            message.text.contains('not actually sent by the user'),
      ),
      isFalse,
    );
  });

  test('filters generated classifier notices from user messages', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-classifier-notice',
      'agentId': 'codex',
      'title':
          'deepseek-v4-pro[1m] is temporarily unavailable, so auto mode cannot determine the safety of Bash right now.',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user-notice',
          'role': 'user',
          'text': '''
deepseek-v4-pro[1m] is temporarily unavailable, so auto mode cannot determine the safety of Bash right now. Wait briefly and then try this action again. If it keeps failing, continue with other tasks that don't require this action and come back to it later. Note: reading files, searching code, and other read-only operations do not require the classifier and can still be used.''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-user-real',
          'role': 'user',
          'text': '帮我运行完整验证',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '我会继续验证。',
          'createdAt': '2026-06-12T00:00:02Z',
        },
      ],
    });

    expect(session.title, '帮我运行完整验证');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '帮我运行完整验证',
      '我会继续验证。',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('deepseek-v4-pro') ||
            message.text.contains('classifier'),
      ),
      isFalse,
    );
  });

  test('filters structured runtime results and automation checklists', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-structured-result',
      'agentId': 'codex',
      'title': '"ok": true,\n"command": "node --test"',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:04Z',
      'messages': [
        {
          'id': 'msg-structured-result',
          'role': 'user',
          'text': '''
"ok": true,
"command": "node --test --experimental-test-coverage",
"args": ["node", "--test"],
"sideEffects": "none",
"timeoutClass": "standard",
"requiredServices": [],
"profiles": ["external"]''',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-automation-checklist',
          'role': 'user',
          'text': '''
- [ ] confirm classifier approval state
- [ ] check sandbox policy before tool call
- [x] record local command timeoutClass''',
          'createdAt': '2026-06-12T00:00:01Z',
        },
        {
          'id': 'msg-real-user',
          'role': 'user',
          'text': '''
- [ ] 保留这个用户真正写的清单
- [ ] 第二条用户清单''',
          'createdAt': '2026-06-12T00:00:02Z',
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': '收到。',
          'createdAt': '2026-06-12T00:00:03Z',
        },
      ],
    });

    expect(session.title, '- [ ] 保留这个用户真正写的清单');
    expect(session.messageCount, 2);
    expect(session.messages.map((message) => message.text), [
      '- [ ] 保留这个用户真正写的清单\n- [ ] 第二条用户清单',
      '收到。',
    ]);
    expect(
      session.messages.any(
        (message) =>
            message.text.contains('"ok": true') ||
            message.text.contains('timeoutClass') ||
            message.text.contains('classifier') ||
            message.text.contains('sandbox policy'),
      ),
      isFalse,
    );
  });

  test('keeps delegated subagent cards inside visible conversations', () {
    final session = AgentConversationSession.fromJson({
      'id': 'session-subagent-card',
      'agentId': 'codex',
      'title': 'Run the security scan',
      'createdAt': '2026-06-12T00:00:00Z',
      'updatedAt': '2026-06-12T00:00:03Z',
      'messages': [
        {
          'id': 'msg-user',
          'role': 'user',
          'text': 'Run the security scan',
          'createdAt': '2026-06-12T00:00:00Z',
        },
        {
          'id': 'msg-worker',
          'role': 'subagent',
          'cardType': 'subagent',
          'cardTitle': 'discovery worker round-05/worker-03',
          'text': 'Worker found one candidate finding.',
          'createdAt': '2026-06-12T00:00:01Z',
          'messages': [
            {
              'id': 'msg-worker-output',
              'role': 'agent',
              'text': 'Worker found one candidate finding.',
              'createdAt': '2026-06-12T00:00:02Z',
            },
          ],
        },
        {
          'id': 'msg-agent',
          'role': 'agent',
          'text': 'Coordinator merged the result.',
          'createdAt': '2026-06-12T00:00:03Z',
        },
        {
          'id': 'msg-worker-prompt',
          'role': 'subagent_prompt',
          'text':
              'You are discovery worker round-05/worker-03 for a Codex Security Deep Security Scan.',
          'createdAt': '2026-06-12T00:00:01Z',
        },
      ],
    });

    expect(session.messageCount, 3);
    expect(session.messages[1].isSubagentCard, isTrue);
    expect(
      session.messages[1].cardTitle,
      'discovery worker round-05/worker-03',
    );
    expect(
      session.messages[1].childMessages.single.text,
      'Worker found one candidate finding.',
    );
    expect(
      session.messages.any((message) => message.role == 'subagent_prompt'),
      isFalse,
    );
  });
}

void main() => registerAgentConversationFilteringScenarios();
