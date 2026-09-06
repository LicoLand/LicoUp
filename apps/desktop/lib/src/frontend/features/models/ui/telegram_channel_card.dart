import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Telegram Communication Channel configuration under the Gateway Runtime.
///
/// The renderer retains the established card layout while all state and
/// operations cross the semantic Models binding.
final class TelegramChannelCard extends StatefulWidget {
  const TelegramChannelCard({
    super.key,
    required this.projection,
    required this.phase,
    required this.intents,
    this.notice,
  });

  final TelegramProjection projection;
  final PresentationPhase phase;
  final IntentSink<ModelsIntent> intents;
  final PresentationNotice? notice;

  @override
  State<TelegramChannelCard> createState() => _TelegramChannelCardState();
}

final class _TelegramChannelCardState extends State<TelegramChannelCard> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController();
  bool _obscureToken = true;

  bool get _busy =>
      widget.phase == PresentationPhase.loading ||
      widget.phase == PresentationPhase.applying;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.intents.send(const RefreshTelegramChannel());
    }, debugLabel: 'TelegramChannelCard.initialRefresh');
  }

  @override
  void didUpdateWidget(covariant TelegramChannelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.notice?.reasonCode;
    final current = widget.notice?.reasonCode;
    if (current == previous) return;
    if (current == 'telegram_token_saved') _tokenController.clear();
    if (current == 'telegram_pairing_approved') {
      _pairingCodeController.clear();
    }
  }

  @override
  void dispose() {
    _tokenController.clear();
    _tokenController.dispose();
    _pairingCodeController.dispose();
    super.dispose();
  }

  String _stateLabel(bool chinese) => switch (widget.projection.stateLabel) {
    'running' => chinese ? '运行中' : 'Running',
    'configured' => chinese ? '已配置' : 'Configured',
    'unconfigured' || 'missing' => chinese ? '未配置' : 'Unconfigured',
    final value => value,
  };

  @override
  Widget build(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    final colors = context.licoColors;
    final state = widget.projection;
    final message = _telegramMessage(widget.notice?.reasonCode, chinese);
    final messageIsError =
        widget.notice?.severity == PresentationNoticeSeverity.error;
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
                  onPressed: _busy
                      ? null
                      : () =>
                            widget.intents.send(const RefreshTelegramChannel()),
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
              label: 'Token',
              value: state.configured
                  ? (chinese
                        ? '已配置（${state.tokenSourceLabel}）'
                        : 'configured (${state.tokenSourceLabel})')
                  : (chinese ? '未配置' : 'missing'),
            ),
            EndpointStatusRow(
              key: const Key('telegram-channel-bot'),
              label: 'Bot',
              value: state.botUsername == null ? '-' : '@${state.botUsername}',
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
              onSubmitted: (_) => _saveToken(),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const Key('telegram-channel-save-token'),
                  onPressed: _busy ? null : _saveToken,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(chinese ? '保存并应用' : 'Save and apply'),
                ),
                FilledButton.tonal(
                  key: const Key('telegram-channel-clear-token'),
                  style: FilledButton.styleFrom(foregroundColor: colors.error),
                  onPressed: _busy || !state.configured
                      ? null
                      : () => widget.intents.send(const ClearTelegramToken()),
                  child: Text(chinese ? '清除 Token' : 'Clear token'),
                ),
              ],
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  key: const Key('telegram-channel-message'),
                  message,
                  style: TextStyle(
                    color: messageIsError ? colors.error : colors.textMuted,
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
                    onSubmitted: _busy ? null : _approve,
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const Key('telegram-channel-approve-code'),
                  onPressed: _busy
                      ? null
                      : () => _approve(_pairingCodeController.text),
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
            if (state.pairings.isEmpty)
              Text(
                key: const Key('telegram-channel-pairings-empty'),
                chinese ? '暂无待批准配对。' : 'No pending pairings.',
                style: TextStyle(color: colors.textMuted),
              )
            else
              ...state.pairings.map(
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
                  onPrimary: _busy ? null : () => _approve(pairing.code),
                  secondaryLabel: chinese ? '拒绝' : 'Dismiss',
                  secondaryKey: Key(
                    'telegram-pairing-dismiss-${pairing.chatId}',
                  ),
                  onSecondary: _busy ? null : () => _revoke(pairing.chatId),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              chinese ? '已批准会话' : 'Approved chats',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            if (state.chats.isEmpty)
              Text(
                key: const Key('telegram-channel-chats-empty'),
                chinese ? '暂无已批准会话。' : 'No approved chats.',
                style: TextStyle(color: colors.textMuted),
              )
            else
              ...state.chats.map(
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
                  onPrimary: _busy ? null : () => _revoke(chat.chatId),
                  primaryIsDestructive: true,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _saveToken() =>
      widget.intents.send(SaveTelegramToken(_tokenController.text));

  void _approve(String code) =>
      widget.intents.send(ApproveTelegramPairing(code));

  void _revoke(int chatId) => widget.intents.send(RevokeTelegramChat(chatId));
}

String? _telegramMessage(String? code, bool chinese) => switch (code) {
  'telegram_refresh_failed' =>
    chinese ? 'Telegram 通道状态未能载入。' : 'Telegram channel status failed to load.',
  'telegram_token_invalid' =>
    chinese ? '请输入有效的 BotFather token。' : 'Enter a valid BotFather token.',
  'telegram_token_saved' =>
    chinese
        ? 'Token 已保存，Gateway 已重新加载通道。'
        : 'Token saved; Gateway reloaded the channel.',
  'telegram_token_save_failed' =>
    chinese ? 'Token 保存失败。' : 'Failed to save token.',
  'telegram_token_cleared' => chinese ? 'Token 已清除。' : 'Token cleared.',
  'telegram_token_clear_failed' =>
    chinese ? 'Token 清除失败。' : 'Failed to clear token.',
  'telegram_pairing_code_required' =>
    chinese ? '请输入配对码。' : 'Enter a pairing code.',
  'telegram_pairing_approved' => chinese ? '已批准配对。' : 'Pairing approved.',
  'telegram_pairing_approve_failed' =>
    chinese ? '配对批准失败。' : 'Pairing approval failed.',
  'telegram_chat_revoked' => chinese ? '已撤销配对会话。' : 'Paired chat revoked.',
  'telegram_chat_revoke_failed' => chinese ? '撤销失败。' : 'Revoke failed.',
  _ => null,
};

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
