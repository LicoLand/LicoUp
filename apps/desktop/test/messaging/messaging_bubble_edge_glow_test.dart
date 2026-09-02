import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_bubble_edge_glow.dart';

int _red8(Color color) => (color.toARGB32() >> 16) & 0xff;
int _green8(Color color) => (color.toARGB32() >> 8) & 0xff;
int _blue8(Color color) => color.toARGB32() & 0xff;

TargetCandidate _candidate(String target, {String? id}) => TargetCandidate(
  id: id,
  target: target,
  label: target,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'ready',
);

void main() {
  group('messagingBubbleGlow', () {
    test('default and unlisted targets share the white light', () {
      for (final key in [
        '',
        'hermes',
        'opencode',
        'codex',
        'cursor',
        'kimi',
        'kimi-code',
        'pi',
      ]) {
        final glow = messagingBubbleGlow(isDark: true, agentKey: key);
        final rim = glow.rimGradient as LinearGradient;
        expect(rim.colors.first.withAlpha(255), Colors.white, reason: key);
      }
    });

    test('claude-code lights the rim orange', () {
      final glow = messagingBubbleGlow(isDark: true, agentKey: 'claude-code');
      final rim = glow.rimGradient as LinearGradient;
      expect(_red8(rim.colors.first), 0xD9);
      expect(_green8(rim.colors.first), 0x77);
      expect(_blue8(rim.colors.first), 0x57);
    });

    test('kilo-code lights the rim yellow', () {
      final glow = messagingBubbleGlow(isDark: true, agentKey: 'kilo-code');
      final rim = glow.rimGradient as LinearGradient;
      expect(_red8(rim.colors.first), 0xFA);
      expect(_green8(rim.colors.first), 0xCC);
      expect(_blue8(rim.colors.first), 0x15);
    });

    test('deepseek-harness lights the rim blue', () {
      final glow = messagingBubbleGlow(
        isDark: true,
        agentKey: 'deepseek-harness',
      );
      final rim = glow.rimGradient as LinearGradient;
      expect(_red8(rim.colors.first), 0x4D);
      expect(_green8(rim.colors.first), 0x6B);
      expect(_blue8(rim.colors.first), 0xFE);
    });

    test('copilot and antigravity sweep a rainbow rim', () {
      for (final key in ['copilot', 'antigravity']) {
        final glow = messagingBubbleGlow(isDark: true, agentKey: key);
        expect(glow.rimGradient, isA<SweepGradient>(), reason: key);
        expect(glow.nearGradient, isA<SweepGradient>(), reason: key);
        expect(glow.midGradient, isA<SweepGradient>(), reason: key);
        expect(glow.farGradient, isA<SweepGradient>(), reason: key);
        final rim = glow.rimGradient as SweepGradient;
        expect(rim.colors.length, greaterThan(4), reason: key);
        expect(rim.colors.first, rim.colors.last, reason: key);
      }
    });

    test('the field decays with distance from the rim', () {
      final glow = messagingBubbleGlow(isDark: true, agentKey: 'claude-code');
      int topAlpha(Gradient gradient) =>
          (((gradient as LinearGradient).colors.first).toARGB32() >> 24) & 0xff;
      final rim = topAlpha(glow.rimGradient);
      final near = topAlpha(glow.nearGradient);
      final mid = topAlpha(glow.midGradient);
      final far = topAlpha(glow.farGradient);
      expect(near, lessThan(rim));
      expect(mid, lessThan(near));
      expect(far, lessThan(mid));
    });
  });

  group('messagingAgentBubbleGlowKey', () {
    test('null and unlisted candidates use the default light', () {
      expect(messagingAgentBubbleGlowKey(null), '');
      expect(messagingAgentBubbleGlowKey(_candidate('hermes')), '');
      expect(messagingAgentBubbleGlowKey(_candidate('codex')), '');
    });

    test('resolves by target first, then id', () {
      expect(
        messagingAgentBubbleGlowKey(_candidate('claude-code')),
        'claude-code',
      );
      expect(messagingAgentBubbleGlowKey(_candidate('kilo-code')), 'kilo-code');
      expect(
        messagingAgentBubbleGlowKey(_candidate('deepseek-harness')),
        'deepseek-harness',
      );
      expect(messagingAgentBubbleGlowKey(_candidate('copilot')), 'copilot');
      expect(
        messagingAgentBubbleGlowKey(_candidate('antigravity')),
        'antigravity',
      );
      expect(
        messagingAgentBubbleGlowKey(_candidate('custom', id: 'claude-code')),
        'claude-code',
      );
    });

    test('key lookup is case-insensitive', () {
      expect(
        messagingAgentBubbleGlowKey(_candidate('Claude-Code')),
        'claude-code',
      );
      final glow = messagingBubbleGlow(isDark: true, agentKey: ' Kilo-Code ');
      final rim = glow.rimGradient as LinearGradient;
      expect(_red8(rim.colors.first), 0xFA);
    });
  });
}
