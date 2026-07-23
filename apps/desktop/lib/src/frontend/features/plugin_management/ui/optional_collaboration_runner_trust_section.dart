import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationRunnerTrustSection extends StatefulWidget {
  const OptionalCollaborationRunnerTrustSection({
    super.key,
    required this.controller,
    required this.state,
    required this.busy,
    required this.isChinese,
  });

  final OptionalCollaborationController controller;
  final OptionalCollaborationRuntimeState state;
  final bool busy;
  final bool isChinese;

  @override
  State<OptionalCollaborationRunnerTrustSection> createState() =>
      _OptionalCollaborationRunnerTrustSectionState();
}

final class _OptionalCollaborationRunnerTrustSectionState
    extends State<OptionalCollaborationRunnerTrustSection> {
  final _keyIdController = TextEditingController();
  final _publicKeyController = TextEditingController();
  final _sourceRepositoryController = TextEditingController();
  final _fingerprintController = TextEditingController();
  bool _importConfirmed = false;
  bool _removeConfirmed = false;

  @override
  void dispose() {
    _keyIdController.dispose();
    _publicKeyController.dispose();
    _sourceRepositoryController.dispose();
    _fingerprintController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trust = widget.state.runnerTrust;
    final editable = !widget.busy && !widget.state.pluginInstalled;
    return Card(
      key: const Key('collaboration-runner-trust-section'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isChinese
                  ? '本机服务端 runner 信任根'
                  : 'Local server runner trust',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.isChinese
                  ? '信任根只用于验证指定 GitHub 仓库中、固定 identity 的 LicoMesh runner。导入不会下载、安装、组装或启动 runner。'
                  : 'This trust root verifies only the fixed-identity LicoMesh runner from the named GitHub repository. Import does not download, install, assemble, or start a runner.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            if (trust != null) ...[
              _TrustFact(
                label: widget.isChinese ? '已信任 key ID' : 'Trusted key ID',
                value: trust.keyId,
              ),
              _TrustFact(
                label: widget.isChinese ? '来源仓库' : 'Source repository',
                value: trust.sourceRepositoryUrl,
              ),
              _TrustFact(label: 'Runner identity', value: trust.runnerIdentity),
              _TrustFact(label: 'SHA-256', value: trust.fingerprintSha256),
              const Divider(height: 24),
            ],
            TextField(
              key: const Key('collaboration-runner-trust-key-id'),
              controller: _keyIdController,
              enabled: editable,
              decoration: InputDecoration(
                labelText: widget.isChinese ? '信任 key ID' : 'Trust key ID',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('collaboration-runner-trust-public-key-base64url'),
              controller: _publicKeyController,
              enabled: editable,
              decoration: InputDecoration(
                labelText: widget.isChinese
                    ? 'Ed25519 公钥（base64url，无填充）'
                    : 'Ed25519 public key (base64url, no padding)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key(
                'collaboration-runner-trust-source-repository-url',
              ),
              controller: _sourceRepositoryController,
              enabled: editable,
              decoration: InputDecoration(
                labelText: widget.isChinese
                    ? 'Runner GitHub 仓库 HTTPS 地址'
                    : 'Runner GitHub repository HTTPS URL',
                hintText: 'https://github.com/owner/repository',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('collaboration-runner-trust-fingerprint-sha256'),
              controller: _fingerprintController,
              enabled: editable,
              decoration: InputDecoration(
                labelText: widget.isChinese
                    ? '预期 SHA-256 公钥指纹'
                    : 'Expected SHA-256 public-key fingerprint',
              ),
            ),
            const SizedBox(height: 8),
            _TrustFact(
              label: 'Runner identity',
              value: optionalCollaborationOfficialRunnerIdentity,
              valueKey: const Key('collaboration-runner-trust-identity'),
            ),
            CheckboxListTile(
              key: const Key('collaboration-runner-trust-confirm'),
              contentPadding: EdgeInsets.zero,
              value: _importConfirmed,
              onChanged: editable
                  ? (value) => setState(() => _importConfirmed = value ?? false)
                  : null,
              title: Text(
                widget.isChinese
                    ? '我已独立核对 key ID、公钥、来源仓库、固定 runner identity 与预期指纹，并直接批准此次导入。'
                    : 'I independently reviewed the key ID, public key, source repository, fixed runner identity, and expected fingerprint and directly approve this import.',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('collaboration-runner-trust-import'),
                onPressed: editable && _importConfirmed ? _import : null,
                icon: const Icon(Icons.verified_user_outlined, size: 16),
                label: Text(
                  widget.isChinese ? '导入精确信任根' : 'Import exact trust',
                ),
              ),
            ),
            if (trust != null) ...[
              const Divider(height: 24),
              CheckboxListTile(
                key: const Key('collaboration-runner-trust-remove-confirm'),
                contentPadding: EdgeInsets.zero,
                value: _removeConfirmed,
                onChanged: editable
                    ? (value) =>
                          setState(() => _removeConfirmed = value ?? false)
                    : null,
                title: Text(
                  widget.isChinese
                      ? '我已核对上方来源仓库、runner identity 和精确指纹，并直接批准移除此信任根。'
                      : 'I reviewed the source repository, runner identity, and exact fingerprint above and directly approve removing this trust.',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  key: const Key('collaboration-runner-trust-remove'),
                  onPressed: editable && _removeConfirmed ? _remove : null,
                  child: Text(widget.isChinese ? '移除信任根' : 'Remove trust'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _import() async {
    final applied = await widget.controller.importRunnerTrust(
      keyId: _keyIdController.text,
      publicKeyBase64url: _publicKeyController.text,
      sourceRepositoryUrl: _sourceRepositoryController.text,
      expectedFingerprintSha256: _fingerprintController.text,
      confirmed: true,
    );
    if (mounted && applied) {
      _publicKeyController.clear();
      setState(() => _importConfirmed = false);
    }
  }

  Future<void> _remove() async {
    final applied = await widget.controller.removeRunnerTrust(confirmed: true);
    if (mounted && applied) setState(() => _removeConfirmed = false);
  }
}

final class _TrustFact extends StatelessWidget {
  const _TrustFact({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 132, child: Text(label)),
          Expanded(child: SelectableText(value, key: valueKey)),
        ],
      ),
    );
  }
}
