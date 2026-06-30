import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import 'panel_frame.dart';

class ModelForwardingPanel extends StatefulWidget {
  const ModelForwardingPanel({super.key, required this.controller});

  final FutureClientController controller;

  @override
  State<ModelForwardingPanel> createState() => _ModelForwardingPanelState();
}

class _ModelForwardingPanelState extends State<ModelForwardingPanel> {
  final TextEditingController _profileController = TextEditingController(
    text: 'local-echo',
  );
  final TextEditingController _commandController = TextEditingController(
    text: 'cat',
  );
  final TextEditingController _textController = TextEditingController(
    text: 'thin forwarding smoke',
  );

  @override
  void dispose() {
    _profileController.dispose();
    _commandController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final result = controller.modelForwardingResult;
    return PanelFrame(
      child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.send_outlined),
            title: const Text('Model Forwarding'),
            subtitle: const Text(
              'Manage thin-forward profiles without starting a session harness.',
            ),
            trailing: IconButton(
              tooltip: 'Refresh profiles',
              onPressed: controller.isModelForwardingBusy
                  ? null
                  : controller.refreshModelProfiles,
              icon: controller.isModelForwardingBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _PanelTextField(
                  controller: _profileController,
                  label: 'Profile',
                  width: 180,
                ),
                _PanelTextField(
                  controller: _commandController,
                  label: 'Command',
                  width: 180,
                ),
                FilledButton.icon(
                  onPressed: controller.isModelForwardingBusy
                      ? null
                      : _saveProfile,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _textController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Forward Text',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: controller.isModelForwardingBusy ? null : _forward,
                icon: const Icon(Icons.play_arrow_outlined, size: 18),
                label: const Text('Forward'),
              ),
            ),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            title: const Text('Profiles'),
            trailing: Text('${controller.modelProfiles.length}'),
          ),
          for (final profile in controller.modelProfiles)
            ListTile(
              dense: true,
              title: Text((profile['id'] ?? '').toString()),
              subtitle: Text(
                (profile['command'] ?? profile['url'] ?? '').toString(),
              ),
              trailing: Text((profile['provider'] ?? '').toString()),
            ),
          if (result != null) ...[
            const Divider(height: 1),
            ListTile(
              dense: true,
              title: Text(
                (result['mode'] ?? result['status'] ?? 'result').toString(),
              ),
              subtitle: Text(
                (result['output'] ?? result['path'] ?? '').toString(),
              ),
              trailing: Text((result['ok'] ?? '').toString()),
            ),
          ],
        ],
      ),
    );
  }

  void _saveProfile() {
    widget.controller.saveCommandModelProfile(
      profileId: _profileController.text.trim(),
      command: _commandController.text.trim(),
    );
  }

  void _forward() {
    widget.controller.forwardModelText(
      profileId: _profileController.text.trim(),
      text: _textController.text,
    );
  }
}

class _PanelTextField extends StatelessWidget {
  const _PanelTextField({
    required this.controller,
    required this.label,
    required this.width,
  });

  final TextEditingController controller;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
