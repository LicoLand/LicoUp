import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Telegram Communication Channel configuration under the Gateway Runtime.
///
/// Token, pairing approve/revoke, refresh, and apply-via-restart are all
/// available on this card — no CLI required.
final class TelegramChannelCard extends StatefulWidget {
  const TelegramChannelCard({
    super.key,
    required this.agentService,
    this.lifecycleController,
  });

  final AgentCommandRunner agentService;
  final LlmGatewayLifecycleController? lifecycleController;

  @override
  State<TelegramChannelCard> createState() => _TelegramChannelCardState();
}

final class _TelegramChannelCardState extends State<TelegramChannelCard> {
  late final TextEditingController _tokenController;
  late final TextEditingController _pairingCodeController;
  bool _busy = false;
  bool _obscureToken = true;
  String? _message;
  bool _messageIsError = false;
  String _channelState = 'unknown';
  bool _configured = false;
  String? _botUsername;
  String _tokenSource = 'none';
  List<_PendingPairing> _pairings = const [];
  List<_PairedChat> _chats = const [];

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController();
    _pairingCodeController = TextEditingController();
    widget.lifecycleController?.addListener(_onLifecycle);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant TelegramChannelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lifecycleController != widget.lifecycleController) {
      oldWidget.lifecycleController?.removeListener(_onLifecycle);
      widget.lifecycleController?.addListener(_onLifecycle);
    }
  }

  @override
  void dispose() {
    widget.lifecycleController?.removeListener(_onLifecycle);
    _tokenController.dispose();
    _pairingCodeController.dispose();
    super.dispose();
  }

  void _onLifecycle() {
    if (!mounted || _busy) return;
    unawaited(_refresh(silent: true));
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _busy = true;
        _message = null;
      });
    }
    try {
      final status = await widget.agentService.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'status',
      ]);
      final channel = await widget.agentService.runCli(const [
        'gateway',
        'channel',
        'status',
      ]);
      final pairingsResult = await widget.agentService.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'pairing',
        'list',
      ]);
      final telegram =
          (channel['channels'] as Map<String, dynamic>?)?['telegram']
              as Map<String, dynamic>? ??
          const {};
      final pairings =
          (pairingsResult['pairings'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(_PendingPairing.fromJson)
              .where((item) => item.code.isNotEmpty)
              .toList(growable: false);
      final chats = (pairingsResult['chats'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_PairedChat.fromJson)
          .where((item) => item.chatId != 0)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _configured = status['configured'] == true;
        _tokenSource = '${status['tokenSource'] ?? 'none'}';
        _channelState = '${telegram['state'] ?? status['token'] ?? 'unknown'}';
        final bot = telegram['botUsername'];
        _botUsername = bot is String && bot.trim().isNotEmpty
            ? bot.trim()
            : null;
        _pairings = pairings;
        _chats = chats;
        if (!silent) {
          _busy = false;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = LicoStrings.of(context).isChinese
            ? 'Telegram 通道状态未能载入。'
            : 'Telegram channel status failed to load.';
      });
    }
  }

  Future<void> _saveToken() async {
    final token = _tokenController.text.trim();
    final chinese = LicoStrings.of(context).isChinese;
    if (token.isEmpty || !token.contains(':')) {
      setState(() {
        _messageIsError = true;
        _message = chinese
            ? '请输入有效的 BotFather token。'
            : 'Enter a valid BotFather token.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.agentService.runCliWithStdin(const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'set',
        '--stdin-json',
        'true',
      ], jsonEncode({'botToken': token}));
      _tokenController.clear();
      await _restartGateway();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = false;
        _message = chinese
            ? 'Token 已保存，Gateway 已重新加载通道。'
            : 'Token saved; Gateway reloaded the channel.';
      });
      await _refresh(silent: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = chinese ? 'Token 保存失败。' : 'Failed to save token.';
      });
    }
  }

  Future<void> _clearToken() async {
    final chinese = LicoStrings.of(context).isChinese;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.agentService.runCli(const [
        'gateway',
        'channel',
        'telegram',
        'credentials',
        'clear',
      ]);
      await _restartGateway();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = false;
        _message = chinese ? 'Token 已清除。' : 'Token cleared.';
      });
      await _refresh(silent: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = chinese ? 'Token 清除失败。' : 'Failed to clear token.';
      });
    }
  }

  Future<void> _restartGateway() async {
    final lifecycle = widget.lifecycleController;
    if (lifecycle != null) {
      // Stop first so a running sidecar reloads the channel with the new token.
      await lifecycle.stop();
      await lifecycle.start();
      return;
    }
    final port = defaultLlmGatewayPort;
    await widget.agentService.runCli([
      'gateway',
      'service',
      'stop',
      '--port',
      '$port',
    ]);
    await widget.agentService.runCli([
      'gateway',
      'service',
      'start',
      '--port',
      '$port',
    ]);
  }

  Future<void> _approve(String code) async {
    final chinese = LicoStrings.of(context).isChinese;
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      setState(() {
        _messageIsError = true;
        _message = chinese ? '请输入配对码。' : 'Enter a pairing code.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.agentService.runCli([
        'gateway',
        'channel',
        'telegram',
        'pairing',
        'approve',
        normalized,
      ]);
      _pairingCodeController.clear();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = false;
        _message = chinese
            ? '已批准配对 $normalized。'
            : 'Approved pairing $normalized.';
      });
      await _refresh(silent: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = chinese ? '配对批准失败。' : 'Pairing approval failed.';
      });
    }
  }

  Future<void> _revoke(int chatId) async {
    final chinese = LicoStrings.of(context).isChinese;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.agentService.runCli([
        'gateway',
        'channel',
        'telegram',
        'pairing',
        'revoke',
        '$chatId',
      ]);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = false;
        _message = chinese ? '已撤销 chat $chatId。' : 'Revoked chat $chatId.';
      });
      await _refresh(silent: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = chinese ? '撤销失败。' : 'Revoke failed.';
      });
    }
  }

  String _stateLabel(bool chinese) {
    return switch (_channelState) {
      'running' => chinese ? '运行中' : 'Running',
      'configured' => chinese ? '已配置' : 'Configured',
      'unconfigured' => chinese ? '未配置' : 'Unconfigured',
      'missing' => chinese ? '未配置' : 'Unconfigured',
      _ => _channelState,
    };
  }

  @override
  Widget build(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    final colors = context.licoColors;
    return Card(
      key: const Key('telegram-channel-card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.telegram),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    chinese ? 'Telegram 通道' : 'Telegram Channel',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  key: const Key('telegram-channel-refresh'),
                  tooltip: chinese ? '刷新' : 'Refresh',
                  onPressed: _busy ? null : () => unawaited(_refresh()),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              chinese
                  ? '在 Gateway 上层接入 Telegram 私聊。保存 token 后会重启网关以加载通道。Telegram 可读经此 bot 发送的内容。'
                  : 'Admit Telegram DMs on the Gateway channel layer. Saving a token restarts the gateway to load the channel. Telegram can read content sent through this bot.',
              style: TextStyle(color: colors.textMuted, height: 1.35),
            ),
            const SizedBox(height: 14),
            EndpointStatusRow(
              key: const Key('telegram-channel-state'),
              label: chinese ? '状态' : 'State',
              value: _stateLabel(chinese),
            ),
            EndpointStatusRow(
              key: const Key('telegram-channel-configured'),
              label: chinese ? 'Token' : 'Token',
              value: _configured
                  ? (chinese
                        ? '已配置（$_tokenSource）'
                        : 'configured ($_tokenSource)')
                  : (chinese ? '未配置' : 'missing'),
            ),
            EndpointStatusRow(
              key: const Key('telegram-channel-bot'),
              label: chinese ? 'Bot' : 'Bot',
              value: _botUsername == null ? '-' : '@$_botUsername',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('telegram-channel-token-field'),
              controller: _tokenController,
              enabled: !_busy,
              obscureText: _obscureToken,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.key_outlined),
                hintText: chinese
                    ? '粘贴 BotFather token'
                    : 'Paste BotFather token',
                suffixIcon: IconButton(
                  tooltip: _obscureToken
                      ? (chinese ? '显示' : 'Show')
                      : (chinese ? '隐藏' : 'Hide'),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
              onSubmitted: (_) => unawaited(_saveToken()),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('telegram-channel-save-token'),
                  onPressed: _busy ? null : () => unawaited(_saveToken()),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(chinese ? '保存并应用' : 'Save and apply'),
                ),
                FilledButton.tonal(
                  key: const Key('telegram-channel-clear-token'),
                  style: FilledButton.styleFrom(foregroundColor: colors.error),
                  onPressed: _busy || !_configured
                      ? null
                      : () => unawaited(_clearToken()),
                  child: Text(chinese ? '清除 Token' : 'Clear token'),
                ),
              ],
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  key: const Key('telegram-channel-message'),
                  _message!,
                  style: TextStyle(
                    color: _messageIsError ? colors.error : colors.textMuted,
                  ),
                ),
              ),
            const Divider(height: 32),
            Text(
              chinese ? '配对' : 'Pairing',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              chinese
                  ? '在 Telegram 私聊 bot 发送 /start，将配对码填入下方或点击批准。'
                  : 'DM the bot with /start in Telegram, then enter the code below or tap Approve.',
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('telegram-channel-pairing-code'),
                    controller: _pairingCodeController,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.pin_outlined),
                      hintText: chinese ? '配对码' : 'Pairing code',
                    ),
                    onSubmitted: (value) => unawaited(_approve(value)),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const Key('telegram-channel-approve-code'),
                  onPressed: _busy
                      ? null
                      : () => unawaited(_approve(_pairingCodeController.text)),
                  child: Text(chinese ? '批准' : 'Approve'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              chinese ? '待批准' : 'Pending',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            if (_pairings.isEmpty)
              Text(
                key: const Key('telegram-channel-pairings-empty'),
                chinese ? '暂无待批准配对。' : 'No pending pairings.',
                style: TextStyle(color: colors.textMuted),
              )
            else
              ..._pairings.map(
                (pairing) => _PairingTile(
                  key: Key('telegram-pairing-${pairing.code}'),
                  title: pairing.code,
                  subtitle: [
                    if (pairing.username != null) '@${pairing.username}',
                    'user ${pairing.userId}',
                    'chat ${pairing.chatId}',
                  ].join(' · '),
                  primaryLabel: chinese ? '批准' : 'Approve',
                  primaryKey: Key('telegram-pairing-approve-${pairing.code}'),
                  onPrimary: _busy
                      ? null
                      : () => unawaited(_approve(pairing.code)),
                  secondaryLabel: chinese ? '拒绝' : 'Dismiss',
                  secondaryKey: Key(
                    'telegram-pairing-dismiss-${pairing.chatId}',
                  ),
                  onSecondary: _busy
                      ? null
                      : () => unawaited(_revoke(pairing.chatId)),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              chinese ? '已批准会话' : 'Approved chats',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            if (_chats.isEmpty)
              Text(
                key: const Key('telegram-channel-chats-empty'),
                chinese ? '暂无已批准会话。' : 'No approved chats.',
                style: TextStyle(color: colors.textMuted),
              )
            else
              ..._chats.map(
                (chat) => _PairingTile(
                  key: Key('telegram-chat-${chat.chatId}'),
                  title: chat.username == null
                      ? 'chat ${chat.chatId}'
                      : '@${chat.username}',
                  subtitle: [
                    'user ${chat.userId}',
                    'chat ${chat.chatId}',
                    if (chat.agentId != null) 'agent ${chat.agentId}',
                  ].join(' · '),
                  primaryLabel: chinese ? '撤销' : 'Revoke',
                  primaryKey: Key('telegram-chat-revoke-${chat.chatId}'),
                  onPrimary: _busy
                      ? null
                      : () => unawaited(_revoke(chat.chatId)),
                  primaryIsDestructive: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _PairingTile extends StatelessWidget {
  const _PairingTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.primaryLabel,
    required this.primaryKey,
    required this.onPrimary,
    this.secondaryLabel,
    this.secondaryKey,
    this.onSecondary,
    this.primaryIsDestructive = false,
  });

  final String title;
  final String subtitle;
  final String primaryLabel;
  final Key primaryKey;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final Key? secondaryKey;
  final VoidCallback? onSecondary;
  final bool primaryIsDestructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceLow,
          borderRadius: BorderRadius.circular(LicoRadius.card),
          border: Border.all(color: colors.line.withAlpha(110)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (primaryIsDestructive)
              FilledButton.tonal(
                key: primaryKey,
                style: FilledButton.styleFrom(foregroundColor: colors.error),
                onPressed: onPrimary,
                child: Text(primaryLabel),
              )
            else
              FilledButton(
                key: primaryKey,
                onPressed: onPrimary,
                child: Text(primaryLabel),
              ),
            if (secondaryLabel != null) ...[
              const SizedBox(width: 8),
              TextButton(
                key: secondaryKey,
                onPressed: onSecondary,
                child: Text(secondaryLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _PendingPairing {
  const _PendingPairing({
    required this.code,
    required this.chatId,
    required this.userId,
    this.username,
  });

  final String code;
  final int chatId;
  final int userId;
  final String? username;

  factory _PendingPairing.fromJson(Map<String, dynamic> json) {
    return _PendingPairing(
      code: '${json['code'] ?? ''}'.trim().toUpperCase(),
      chatId: (json['chatId'] as num?)?.toInt() ?? 0,
      userId: (json['userId'] as num?)?.toInt() ?? 0,
      username: _optionalString(json['username']),
    );
  }
}

final class _PairedChat {
  const _PairedChat({
    required this.chatId,
    required this.userId,
    this.username,
    this.agentId,
  });

  final int chatId;
  final int userId;
  final String? username;
  final String? agentId;

  factory _PairedChat.fromJson(Map<String, dynamic> json) {
    return _PairedChat(
      chatId: (json['chatId'] as num?)?.toInt() ?? 0,
      userId: (json['userId'] as num?)?.toInt() ?? 0,
      username: _optionalString(json['username']),
      agentId: _optionalString(json['agentId']),
    );
  }
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
