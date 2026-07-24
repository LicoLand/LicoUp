import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_display.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('display parser separates plugins and metadata from visible body', () {
    final display = splitMessageDisplayBlocks('''
Visible answer.

<recommended_plugins>
- Atlassian Rovo (atlassian-rovo@openai-curated-remote)
- Google Drive (google-drive@openai-curated-remote)
</recommended_plugins>

<additional_metadata>
Hidden detail.
</additional_metadata>
''');

    expect(display.body, 'Visible answer.');
    expect(display.recommendedPluginsBlocks, hasLength(1));
    expect(display.recommendedPluginsBlocks.single, contains('Atlassian Rovo'));
    expect(display.recommendedPluginsBlocks.single, contains('Google Drive'));
    expect(display.metadataBlocks, ['Hidden detail.']);
  });

  test('plugin counter counts only markdown bullet entries', () {
    expect(recommendedPluginsCount(const []), 0);
    expect(recommendedPluginsCount(const ['- One\n- Two\n* Three']), 3);
    expect(
      recommendedPluginsCount(const [
        'Intro text\n- Plugin A (id-a)\n- Plugin B (id-b)',
        '- Plugin C',
      ]),
      3,
    );
  });
}
