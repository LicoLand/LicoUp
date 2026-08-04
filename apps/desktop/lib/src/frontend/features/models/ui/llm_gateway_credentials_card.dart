import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';

/// Fixed validity periods offered when a key is created or extended.
const _validityDayOptions = [7, 30, 60, 90, 180, 365];

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
  });
  final AgentCommandRunner agentService;
  final LlmVaultAuthorization authorization;

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
    widget.authorization.addListener(_inventoryChanged);
    if (!widget.authorization.inventoryHydrated) {
      // The normal bootstrap has already hydrated this cache. This fallback is
      // for isolated widgets and startup races; it still reads metadata only.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadInventory());
    }
  }

  @override
  void didUpdateWidget(covariant LlmGatewayCredentialsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authorization == widget.authorization) return;
    oldWidget.authorization.removeListener(_inventoryChanged);
    _entries = widget.authorization.inventoryEntries;
    widget.authorization.addListener(_inventoryChanged);
  }

  @override
  void dispose() {
    widget.authorization.removeListener(_inventoryChanged);
    super.dispose();
  }

  void _inventoryChanged() {
    if (!mounted) return;
    setState(() => _entries = widget.authorization.inventoryEntries);
  }

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
      final entries = _entriesFrom(result);
      widget.authorization
        ..authorized = entries.isNotEmpty
        ..adoptInventory(result);
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
      final entries = _entriesFrom(result);
      widget.authorization
        ..authorized = entries.isNotEmpty
        ..adoptInventory(result);
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
              onEdit: (entry) => unawaited(_edit(entry)),
              onDelete: (id) => unawaited(_delete(id)),
            ),
          ],
        ),
      ),
    );
  }
}

class _CredentialsTable extends StatelessWidget {
  const _CredentialsTable({
    required this.entries,
    required this.busy,
    required this.chinese,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Map<String, dynamic>> entries;
  final bool busy;
  final bool chinese;
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
              const SizedBox(width: 88),
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
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, dynamic> entry;
  final bool busy;
  final bool chinese;
  final int nowEpoch;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            width: 88,
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
