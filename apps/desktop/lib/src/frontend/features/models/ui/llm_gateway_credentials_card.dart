import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

const _validityDayOptions = [7, 30, 60, 90, 180, 365];
const _authorizeToggleWidth = 52.0;
const _rowActionsWidth = 88.0;

String _formatEpochDay(int epochSeconds) {
  final local = DateTime.fromMillisecondsSinceEpoch(
    epochSeconds * 1000,
    isUtc: true,
  ).toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

final class LlmGatewayCredentialsCard extends StatelessWidget {
  const LlmGatewayCredentialsCard({
    super.key,
    required this.credentials,
    required this.gatewayRunning,
    required this.phase,
    required this.intents,
    this.notice,
  });

  final List<GatewayCredentialProjection> credentials;
  final bool gatewayRunning;
  final PresentationPhase phase;
  final IntentSink<ModelsIntent> intents;
  final PresentationNotice? notice;

  bool get _busy =>
      phase == PresentationPhase.loading || phase == PresentationPhase.applying;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final chinese = strings.isChinese;
    final message = _credentialMessage(notice?.reasonCode, chinese);
    final messageIsError = notice?.severity == PresentationNoticeSeverity.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.key_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.isChinese ? '模型 API 密钥' : 'Model API keys',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('credentials-add'),
                  onPressed: _busy ? null : () => unawaited(_add(context)),
                  icon: const Icon(Icons.add),
                  label: Text(chinese ? '添加' : 'Add'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey<String>('credentials-authorize'),
                  onPressed: _busy
                      ? null
                      : () => intents.send(
                          const AuthorizeAllGatewayCredentials(),
                        ),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fingerprint, size: 18),
                  label: Text(chinese ? '授权' : 'Authorize'),
                ),
              ],
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  message,
                  style: TextStyle(
                    color: messageIsError
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            _CredentialsTable(
              credentials: credentials,
              busy: _busy,
              chinese: chinese,
              canToggleAuthorization: !_busy && gatewayRunning,
              onAuthorizeChanged: (credentialId, enabled) => intents.send(
                SetGatewayCredentialAuthorized(credentialId, enabled),
              ),
              onEdit: (credential) => unawaited(_edit(context, credential)),
              onDelete: (id) => intents.send(DeleteGatewayCredential(id)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final input = await showDialog<_NewCredentialInput>(
      context: context,
      builder: (_) => const _NewCredentialDialog(),
    );
    if (input == null) return;
    intents.send(
      CreateGatewayCredential(
        provider: input.provider,
        label: input.label,
        apiKey: input.apiKey,
        leaseDays: input.leaseDays,
      ),
    );
    input.clear();
  }

  Future<void> _edit(
    BuildContext context,
    GatewayCredentialProjection credential,
  ) async {
    final input = await showDialog<_EditCredentialInput>(
      context: context,
      builder: (_) => _EditCredentialDialog(credential: credential),
    );
    if (input == null) return;
    intents.send(
      UpdateGatewayCredential(
        credentialId: credential.id,
        label: input.label,
        extendDays: input.extendDays,
      ),
    );
  }
}

String? _credentialMessage(String? code, bool chinese) => switch (code) {
  'credential_inventory_failed' =>
    chinese ? '密钥清单未能载入。' : 'The key inventory could not be loaded.',
  'credential_authorized' => chinese ? '已授权该密钥。' : 'Authorized this key.',
  'credential_revoked' =>
    chinese ? '已撤销该密钥授权。' : 'Revoked this key authorization.',
  'credential_create_failed' =>
    chinese ? '密钥未能保存。' : 'The API key was not saved.',
  'credential_update_failed' =>
    chinese ? '密钥未能更新。' : 'The API key was not updated.',
  'credential_delete_failed' =>
    chinese ? '密钥未能删除。' : 'The API key was not deleted.',
  'credential_authorization_failed' =>
    chinese
        ? '系统授权未完成，请重试。'
        : 'System authorization did not complete. Try again.',
  'credential_revoke_failed' =>
    chinese ? '未能撤销授权，请重试。' : 'Could not revoke authorization. Try again.',
  _ => null,
};

typedef _CredentialAuthorizeChanged =
    void Function(String credentialId, bool enabled);

final class _CredentialsTable extends StatelessWidget {
  const _CredentialsTable({
    required this.credentials,
    required this.busy,
    required this.chinese,
    required this.canToggleAuthorization,
    required this.onAuthorizeChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final List<GatewayCredentialProjection> credentials;
  final bool busy;
  final bool chinese;
  final bool canToggleAuthorization;
  final _CredentialAuthorizeChanged onAuthorizeChanged;
  final ValueChanged<GatewayCredentialProjection> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerStyle = theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Widget headerCell(String label, [int flex = 1]) => Expanded(
      flex: flex,
      child: Text(label, style: headerStyle),
    );
    return Column(
      key: const ValueKey<String>('credentials-table'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              headerCell(chinese ? '模型服务商' : 'Provider'),
              headerCell(chinese ? '密钥名称' : 'Name', 2),
              headerCell(chinese ? '创建时间' : 'Created'),
              headerCell(chinese ? '到期时间' : 'Expires'),
              SizedBox(
                width: _authorizeToggleWidth,
                child: Text(
                  chinese ? '授权' : 'Auth',
                  style: headerStyle,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: _rowActionsWidth),
            ],
          ),
        ),
        const Divider(height: 1),
        if (credentials.isEmpty)
          Padding(
            key: const ValueKey<String>('credentials-empty'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    chinese ? '尚未保存密钥。' : 'No keys saved yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          for (final credential in credentials)
            _CredentialRow(
              credential: credential,
              busy: busy,
              chinese: chinese,
              nowEpoch: nowEpoch,
              canToggleAuthorization: canToggleAuthorization,
              onAuthorizeChanged: onAuthorizeChanged,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
      ],
    );
  }
}

final class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.credential,
    required this.busy,
    required this.chinese,
    required this.nowEpoch,
    required this.canToggleAuthorization,
    required this.onAuthorizeChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final GatewayCredentialProjection credential;
  final bool busy;
  final bool chinese;
  final int nowEpoch;
  final bool canToggleAuthorization;
  final _CredentialAuthorizeChanged onAuthorizeChanged;
  final ValueChanged<GatewayCredentialProjection> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expires = credential.expiresAtEpochSeconds;
    final expired = expires != null && nowEpoch >= expires;
    final authorizeTooltip = !canToggleAuthorization
        ? (chinese
              ? 'Gateway 运行中才可切换授权'
              : 'Toggle authorization only while Gateway is running')
        : credential.authorized
        ? (chinese ? '撤销此密钥授权' : 'Revoke this key authorization')
        : (chinese ? '授权此密钥' : 'Authorize this key');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(_providerLabel(credential.providerLabel))),
          Expanded(
            flex: 2,
            child: Text(
              credential.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              credential.createdAtEpochSeconds == null
                  ? '—'
                  : _formatEpochDay(credential.createdAtEpochSeconds!),
            ),
          ),
          Expanded(
            child: Text(
              expires == null
                  ? (chinese ? '永久' : 'Never')
                  : expired
                  ? '${_formatEpochDay(expires)}${chinese ? '（已到期）' : ' (expired)'}'
                  : _formatEpochDay(expires),
              style: expired ? TextStyle(color: theme.colorScheme.error) : null,
            ),
          ),
          SizedBox(
            width: _authorizeToggleWidth,
            child: Center(
              child: Tooltip(
                message: authorizeTooltip,
                child: _AuthorizeSwitch(
                  credentialId: credential.id,
                  value: credential.authorized,
                  onChanged: canToggleAuthorization
                      ? (enabled) => onAuthorizeChanged(credential.id, enabled)
                      : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: _rowActionsWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  key: ValueKey<String>('credential-edit-${credential.id}'),
                  tooltip: chinese ? '编辑' : 'Edit',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  onPressed: busy ? null : () => onEdit(credential),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: ValueKey<String>('credential-delete-${credential.id}'),
                  tooltip: chinese ? '删除' : 'Delete',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  onPressed: busy ? null : () => onDelete(credential.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Matches the Gateway readiness color instead of the global accent switch.
final class _AuthorizeSwitch extends StatelessWidget {
  const _AuthorizeSwitch({
    required this.credentialId,
    required this.value,
    required this.onChanged,
  });

  final String credentialId;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Switch(
      key: ValueKey<String>('credential-authorize-$credentialId'),
      value: value,
      onChanged: onChanged,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const Color(0xFFFFFFFF);
        }
        return colors.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          final green = colors.success;
          return states.contains(WidgetState.disabled)
              ? green.withValues(alpha: 0.45)
              : green;
        }
        return colors.surfaceLow;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colors.success.withValues(alpha: 0.85);
        }
        return colors.line;
      }),
    );
  }
}

String _providerLabel(String provider) => switch (provider) {
  'deepseek' => 'DeepSeek',
  'kilo' => 'Kilo',
  _ => 'Kimi',
};

final class _NewCredentialInput {
  _NewCredentialInput({
    required this.provider,
    required this.label,
    required this.apiKey,
    required this.leaseDays,
  });

  final String provider;
  final String label;
  String apiKey;
  final int leaseDays;

  void clear() => apiKey = '';
}

final class _NewCredentialDialog extends StatefulWidget {
  const _NewCredentialDialog();

  @override
  State<_NewCredentialDialog> createState() => _NewCredentialDialogState();
}

final class _NewCredentialDialogState extends State<_NewCredentialDialog> {
  final TextEditingController _label = TextEditingController();
  final TextEditingController _apiKey = TextEditingController();
  String _provider = 'kimi';
  int _leaseDays = 30;

  @override
  void dispose() {
    _apiKey.clear();
    _apiKey.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    return AlertDialog(
      key: const Key('new-credential-dialog'),
      title: Text(chinese ? '添加模型 API 密钥' : 'Add model API key'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: InputDecoration(
                labelText: chinese ? '模型服务商' : 'Provider',
              ),
              items: const [
                DropdownMenuItem(value: 'kimi', child: Text('Kimi')),
                DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                DropdownMenuItem(value: 'kilo', child: Text('Kilo')),
              ],
              onChanged: (value) => _provider = value ?? 'kimi',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('new-key-label'),
              controller: _label,
              decoration: InputDecoration(
                labelText: chinese ? '密钥名称' : 'Key name',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('new-key-value'),
              controller: _apiKey,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey<String>('new-key-validity'),
              initialValue: _leaseDays,
              decoration: InputDecoration(
                labelText: chinese ? '存储有效期' : 'Storage period',
              ),
              items: [
                for (final days in _validityDayOptions)
                  DropdownMenuItem(
                    value: days,
                    child: Text('$days ${chinese ? '天' : 'days'}'),
                  ),
              ],
              onChanged: (value) => _leaseDays = value ?? 30,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(chinese ? '取消' : 'Cancel'),
        ),
        FilledButton(
          key: const Key('new-key-save'),
          onPressed: () {
            final apiKey = _apiKey.text.trim();
            final label = _label.text.trim();
            if (apiKey.isEmpty || label.isEmpty) return;
            Navigator.pop(
              context,
              _NewCredentialInput(
                provider: _provider,
                label: label,
                apiKey: apiKey,
                leaseDays: _leaseDays,
              ),
            );
            _apiKey.clear();
          },
          child: Text(chinese ? '保存并验证' : 'Save & authenticate'),
        ),
      ],
    );
  }
}

final class _EditCredentialInput {
  const _EditCredentialInput({this.label, this.extendDays});

  final String? label;
  final int? extendDays;
}

final class _EditCredentialDialog extends StatefulWidget {
  const _EditCredentialDialog({required this.credential});

  final GatewayCredentialProjection credential;

  @override
  State<_EditCredentialDialog> createState() => _EditCredentialDialogState();
}

final class _EditCredentialDialogState extends State<_EditCredentialDialog> {
  late final TextEditingController _label;
  int? _extendDays;

  bool get _hasExpiry => widget.credential.expiresAtEpochSeconds != null;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.credential.label);
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    return AlertDialog(
      key: const Key('edit-credential-dialog'),
      title: Text(chinese ? '编辑密钥' : 'Edit API key'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('edit-key-label'),
              controller: _label,
              decoration: InputDecoration(
                labelText: chinese ? '密钥名称' : 'Key name',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              key: const ValueKey<String>('edit-key-extend'),
              initialValue: _extendDays,
              decoration: InputDecoration(
                labelText: _hasExpiry
                    ? (chinese ? '延长有效期' : 'Extend validity')
                    : (chinese ? '设置有效期' : 'Set validity'),
              ),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(chinese ? '不修改' : 'Keep unchanged'),
                ),
                for (final days in _validityDayOptions)
                  DropdownMenuItem(
                    value: days,
                    child: Text(
                      _hasExpiry
                          ? '+$days ${chinese ? '天' : 'days'}'
                          : '$days ${chinese ? '天' : 'days'}',
                    ),
                  ),
              ],
              onChanged: (value) => _extendDays = value,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(chinese ? '取消' : 'Cancel'),
        ),
        FilledButton(
          key: const Key('edit-key-save'),
          onPressed: () {
            final label = _label.text.trim();
            final changedLabel = label == widget.credential.label
                ? null
                : label;
            if (changedLabel == null && _extendDays == null) {
              Navigator.pop(context);
              return;
            }
            Navigator.pop(
              context,
              _EditCredentialInput(
                label: changedLabel,
                extendDays: _extendDays,
              ),
            );
          },
          child: Text(chinese ? '保存' : 'Save'),
        ),
      ],
    );
  }
}
