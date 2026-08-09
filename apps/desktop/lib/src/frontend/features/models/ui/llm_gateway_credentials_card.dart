import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Fixed validity periods offered when a key is created or extended.
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

class LlmGatewayCredentialsCard extends StatefulWidget {
  const LlmGatewayCredentialsCard({
    super.key,
    required this.agentService,
    required this.authorization,
    this.lifecycleController,
  });
  final AgentCommandRunner agentService;
  final LlmVaultAuthorization authorization;

  /// When present, the per-row authorize toggle is enabled only while the
  /// local Gateway reports [LlmGatewayRuntimeState.running]. Authorization
  /// hot-applies credentials in native code and never restarts that process
  /// from this UI.
  final LlmGatewayLifecycleController? lifecycleController;

  @override
  State<LlmGatewayCredentialsCard> createState() =>
      _LlmGatewayCredentialsCardState();
}

class _LlmGatewayCredentialsCardState extends State<LlmGatewayCredentialsCard> {
  List<Map<String, dynamic>> _entries = const [];
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _entries = widget.authorization.inventoryEntries;
    widget.authorization.addListener(_sessionChanged);
    widget.lifecycleController?.addListener(_sessionChanged);
    if (!widget.authorization.inventoryHydrated) {
      // The normal bootstrap has already hydrated this cache. This fallback is
      // for isolated widgets and startup races; it still reads metadata only.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadInventory());
    }
  }

  @override
  void didUpdateWidget(covariant LlmGatewayCredentialsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authorization != widget.authorization) {
      oldWidget.authorization.removeListener(_sessionChanged);
      _entries = widget.authorization.inventoryEntries;
      widget.authorization.addListener(_sessionChanged);
    }
    if (oldWidget.lifecycleController != widget.lifecycleController) {
      oldWidget.lifecycleController?.removeListener(_sessionChanged);
      widget.lifecycleController?.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    widget.authorization.removeListener(_sessionChanged);
    widget.lifecycleController?.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(() => _entries = widget.authorization.inventoryEntries);
  }

  bool get _serviceRunning =>
      widget.lifecycleController?.state == LlmGatewayRuntimeState.running;

  List<Map<String, dynamic>> _entriesFrom(Map<String, dynamic> result) =>
      (result['entries'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);

  Future<void> _loadInventory() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.authorization.refreshInventory(widget.agentService);
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = chinese
              ? '密钥清单未能载入。'
              : 'The key inventory could not be loaded.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final input = await showDialog<_NewKeyInput>(
      context: context,
      builder: (_) => const _NewKeyDialog(),
    );
    if (input == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.agentService.runCliWithStdin(
        const ['llm-gateway', 'credentials', 'create', '--stdin-json', 'true'],
        jsonEncode({
          'provider': input.provider,
          'label': input.label,
          'apiKey': input.apiKey,
          'leaseDays': input.validityDays,
        }),
      );
      if (!mounted) return;
      widget.authorization.adoptInventory(result);
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = chinese ? '密钥未能保存。' : 'The API key was not saved.',
        );
      }
    } finally {
      input.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authorizeAll() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final authorized = await widget.authorization.authorize(
        widget.agentService,
      );
      if (!mounted) return;
      final failure = widget.authorization.failure;
      if (authorized || failure == LlmVaultAuthorizationFailure.noCredentials) {
        await widget.authorization.refreshInventory(widget.agentService);
      }
      if (!mounted) return;
      if (!authorized) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = failure == LlmVaultAuthorizationFailure.noCredentials
              ? (chinese
                    ? '没有可授权的 API 密钥，请先添加。'
                    : 'No API key to authorize. Add one first.')
              : (chinese
                    ? '系统授权未完成，请重试。'
                    : 'System authorization did not complete. Try again.'),
        );
        return;
      }
      await widget.lifecycleController?.pollNow();
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = chinese
              ? '授权未完成，请重试。'
              : 'Authorization did not complete. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> entry) async {
    final input = await showDialog<_EditKeyInput>(
      context: context,
      builder: (_) => _EditKeyDialog(entry: entry),
    );
    if (input == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await widget.agentService.runCliWithStdin(
        [
          'llm-gateway',
          'credentials',
          'update',
          '${entry['credentialId']}',
          '--stdin-json',
          'true',
        ],
        jsonEncode({
          if (input.label != null) 'label': input.label,
          if (input.extendDays != null) 'extendDays': input.extendDays,
        }),
      );
      if (!mounted) return;
      widget.authorization.adoptInventory(result);
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = chinese ? '密钥未能更新。' : 'The API key was not updated.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canToggleAuthorization =>
      !_busy && !widget.authorization.busy && _serviceRunning;

  /// Authorizes one credential into the Gateway session. Native authorize
  /// hot-applies the lease to a running managed Gateway; this UI only refreshes
  /// status and never restarts the process.
  Future<void> _authorizeAccess(String credentialId) async {
    if (!_canToggleAuthorization ||
        widget.authorization.isCredentialAuthorized(credentialId)) {
      return;
    }
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final lifecycle = widget.lifecycleController;
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final authorized = await widget.authorization.authorizeCredential(
        widget.agentService,
        credentialId,
      );
      if (!mounted) return;
      final failure = widget.authorization.failure;
      if (authorized || failure == LlmVaultAuthorizationFailure.noCredentials) {
        await widget.authorization.refreshInventory(widget.agentService);
      }
      if (!authorized) {
        setState(() {
          _messageIsError = true;
          _message = failure == LlmVaultAuthorizationFailure.noCredentials
              ? (chinese
                    ? '没有可加载的 API Key，请先添加。'
                    : 'No API keys are available. Add one first.')
              : (chinese
                    ? '系统授权未完成，请重试。'
                    : 'System authorization did not complete. Try again.');
        });
        return;
      }
      await lifecycle?.pollNow();
      if (!mounted) return;
      setState(() {
        _messageIsError = false;
        _message = chinese ? '已授权该密钥。' : 'Authorized this key.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = chinese
            ? '系统授权未完成，请重试。'
            : 'System authorization did not complete. Try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Revokes one credential from the Gateway session. Native clear hot-applies
  /// the updated lease; this UI only refreshes status.
  Future<void> _revokeAccess(String credentialId) async {
    if (!_canToggleAuthorization ||
        !widget.authorization.isCredentialAuthorized(credentialId)) {
      return;
    }
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final lifecycle = widget.lifecycleController;
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final cleared = await widget.authorization.clearCredential(
        widget.agentService,
        credentialId,
      );
      if (!mounted) return;
      if (!cleared) {
        setState(() {
          _messageIsError = true;
          _message = chinese
              ? '未能撤销授权，请重试。'
              : 'Could not revoke authorization. Try again.';
        });
        return;
      }
      await lifecycle?.pollNow();
      if (!mounted) return;
      setState(() {
        _messageIsError = false;
        _message = chinese ? '已撤销该密钥授权。' : 'Revoked this key authorization.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = chinese
            ? '未能撤销授权，请重试。'
            : 'Could not revoke authorization. Try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(String id) async {
    setState(() => _busy = true);
    try {
      final result = await widget.agentService.runCli([
        'llm-gateway',
        'credentials',
        'delete',
        id,
      ]);
      if (!mounted) return;
      if (widget.authorization.isCredentialAuthorized(id)) {
        await widget.authorization.clearCredential(widget.agentService, id);
      }
      if (!mounted) return;
      widget.authorization.adoptInventory(result);
    } catch (_) {
      if (mounted) {
        final chinese = Localizations.localeOf(context).languageCode == 'zh';
        _messageIsError = true;
        setState(
          () => _message = chinese ? '密钥未能删除。' : 'The API key was not deleted.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
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
                    chinese ? '模型 API 密钥' : 'Model API keys',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('credentials-add'),
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add),
                  label: Text(chinese ? '添加' : 'Add'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey<String>('credentials-authorize'),
                  onPressed: _busy || widget.authorization.busy
                      ? null
                      : () => unawaited(_authorizeAll()),
                  icon: widget.authorization.busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fingerprint, size: 18),
                  label: Text(
                    widget.authorization.busy
                        ? (chinese ? '授权中…' : 'Authorizing…')
                        : (chinese ? '授权' : 'Authorize'),
                  ),
                ),
              ],
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _messageIsError
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            _CredentialsTable(
              entries: _entries,
              busy: _busy,
              chinese: chinese,
              authorizedCredentialIds: widget
                  .authorization
                  .authorizedCredentialIds
                  .toSet(),
              canToggleAuthorization: _canToggleAuthorization,
              onAuthorizeChanged: (credentialId, enabled) => unawaited(
                enabled
                    ? _authorizeAccess(credentialId)
                    : _revokeAccess(credentialId),
              ),
              onEdit: (entry) => unawaited(_edit(entry)),
              onDelete: (id) => unawaited(_delete(id)),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _CredentialAuthorizeChanged =
    void Function(String credentialId, bool enabled);

class _CredentialsTable extends StatelessWidget {
  const _CredentialsTable({
    required this.entries,
    required this.busy,
    required this.chinese,
    required this.authorizedCredentialIds,
    required this.canToggleAuthorization,
    required this.onAuthorizeChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> entries;
  final bool busy;
  final bool chinese;
  final Set<String> authorizedCredentialIds;
  final bool canToggleAuthorization;
  final _CredentialAuthorizeChanged onAuthorizeChanged;
  final ValueChanged<Map<String, dynamic>> onEdit;
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
        if (entries.isEmpty)
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
          for (final entry in entries)
            _CredentialRow(
              entry: entry,
              busy: busy,
              chinese: chinese,
              nowEpoch: nowEpoch,
              authorizeOn: authorizedCredentialIds.contains(
                '${entry['credentialId']}',
              ),
              canToggleAuthorization: canToggleAuthorization,
              onAuthorizeChanged: onAuthorizeChanged,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
      ],
    );
  }
}

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.entry,
    required this.busy,
    required this.chinese,
    required this.nowEpoch,
    required this.authorizeOn,
    required this.canToggleAuthorization,
    required this.onAuthorizeChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> entry;
  final bool busy;
  final bool chinese;
  final int nowEpoch;
  final bool authorizeOn;
  final bool canToggleAuthorization;
  final _CredentialAuthorizeChanged onAuthorizeChanged;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credentialId = '${entry['credentialId']}';
    final provider = switch (entry['provider']) {
      'deepseek' => 'DeepSeek',
      'kilo' => 'Kilo',
      _ => 'Kimi',
    };
    final created = entry['createdAtEpochSeconds'] as int?;
    final expires = entry['expiresAtEpochSeconds'] as int?;
    final expired = expires != null && nowEpoch >= expires;
    final expiryStyle = expired
        ? TextStyle(color: theme.colorScheme.error)
        : null;
    final authorizeTooltip = !canToggleAuthorization
        ? (chinese
              ? 'Gateway 运行中才可切换授权'
              : 'Toggle authorization only while Gateway is running')
        : authorizeOn
        ? (chinese ? '撤销此密钥授权' : 'Revoke this key authorization')
        : (chinese ? '授权此密钥' : 'Authorize this key');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(provider)),
          Expanded(
            flex: 2,
            child: Text(
              '${entry['label'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(created == null ? '—' : _formatEpochDay(created)),
          ),
          Expanded(
            child: Text(
              expires == null
                  ? (chinese ? '永久' : 'Never')
                  : expired
                  ? '${_formatEpochDay(expires)}${chinese ? '（已到期）' : ' (expired)'}'
                  : _formatEpochDay(expires),
              style: expiryStyle,
            ),
          ),
          SizedBox(
            width: _authorizeToggleWidth,
            child: Center(
              child: Tooltip(
                message: authorizeTooltip,
                child: _AuthorizeSwitch(
                  credentialId: credentialId,
                  value: authorizeOn,
                  onChanged: canToggleAuthorization
                      ? (enabled) => onAuthorizeChanged(credentialId, enabled)
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
                  key: ValueKey<String>(
                    'credential-edit-${entry['credentialId']}',
                  ),
                  tooltip: chinese ? '编辑' : 'Edit',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  onPressed: busy ? null : () => onEdit(entry),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  key: ValueKey<String>(
                    'credential-delete-${entry['credentialId']}',
                  ),
                  tooltip: chinese ? '删除' : 'Delete',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                  onPressed: busy
                      ? null
                      : () => onDelete('${entry['credentialId']}'),
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

/// Authorization toggle uses success green when on — matching Gateway
/// "running" / "ready" — instead of the global brand-yellow switch track.
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

class _NewKeyInput {
  _NewKeyInput(this.provider, this.label, this.apiKey, this.validityDays);
  final String provider;
  final String label;
  String apiKey;
  final int validityDays;
  void clear() => apiKey = '';
}

class _NewKeyDialog extends StatefulWidget {
  const _NewKeyDialog();
  @override
  State<_NewKeyDialog> createState() => _NewKeyDialogState();
}

class _NewKeyDialogState extends State<_NewKeyDialog> {
  final _label = TextEditingController();
  final _secret = TextEditingController();
  String _provider = 'kimi';
  int _validityDays = 30;
  @override
  void dispose() {
    _label.dispose();
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return AlertDialog(
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
              controller: _label,
              decoration: InputDecoration(
                labelText: chinese ? '密钥名称' : 'Key name',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _secret,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey<String>('new-key-validity'),
              initialValue: _validityDays,
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
              onChanged: (value) => _validityDays = value ?? 30,
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
          key: const ValueKey<String>('new-key-save'),
          onPressed: () {
            final result = _NewKeyInput(
              _provider,
              _label.text.trim(),
              _secret.text.trim(),
              _validityDays,
            );
            _secret.clear();
            Navigator.pop(context, result);
          },
          child: Text(chinese ? '保存并验证' : 'Save & authenticate'),
        ),
      ],
    );
  }
}

class _EditKeyInput {
  _EditKeyInput(this.label, this.extendDays);
  final String? label;
  final int? extendDays;
}

class _EditKeyDialog extends StatefulWidget {
  const _EditKeyDialog({required this.entry});
  final Map<String, dynamic> entry;

  @override
  State<_EditKeyDialog> createState() => _EditKeyDialogState();
}

class _EditKeyDialogState extends State<_EditKeyDialog> {
  late final TextEditingController _label;
  int? _extendDays;

  bool get _hasExpiry => widget.entry['expiresAtEpochSeconds'] != null;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: '${widget.entry['label'] ?? ''}');
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final originalLabel = '${widget.entry['label'] ?? ''}';
    return AlertDialog(
      title: Text(chinese ? '编辑密钥' : 'Edit API key'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey<String>('edit-key-label'),
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
                DropdownMenuItem<int?>(
                  child: Text(chinese ? '不修改' : 'Keep unchanged'),
                ),
                for (final days in _validityDayOptions)
                  DropdownMenuItem<int?>(
                    value: days,
                    child: Text(
                      _hasExpiry
                          ? '+$days ${chinese ? '天' : 'days'}'
                          : '$days ${chinese ? '天' : 'days'}',
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _extendDays = value),
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
          key: const ValueKey<String>('edit-key-save'),
          onPressed: () {
            final newLabel = _label.text.trim();
            final renamed = newLabel.isNotEmpty && newLabel != originalLabel;
            if (!renamed && _extendDays == null) {
              Navigator.pop(context);
              return;
            }
            Navigator.pop(
              context,
              _EditKeyInput(renamed ? newLabel : null, _extendDays),
            );
          },
          child: Text(chinese ? '保存' : 'Save'),
        ),
      ],
    );
  }
}
