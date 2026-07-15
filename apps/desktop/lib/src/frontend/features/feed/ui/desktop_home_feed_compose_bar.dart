import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Inline Apple-leaning glass compose bar for the desktop home feed / plaza.
class DesktopHomeFeedComposeBar extends StatefulWidget {
  const DesktopHomeFeedComposeBar({super.key, required this.controller});

  final ClientController controller;

  @override
  State<DesktopHomeFeedComposeBar> createState() =>
      _DesktopHomeFeedComposeBarState();
}

class _DesktopHomeFeedComposeBarState extends State<DesktopHomeFeedComposeBar> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<XFile> _attachments = [];
  bool _posting = false;
  bool _busyMedia = false;
  bool _focused = false;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onDraftChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onDraftChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onDraftChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onFocusChanged() {
    final next = _focusNode.hasFocus;
    if (next == _focused || !mounted) {
      return;
    }
    setState(() => _focused = next);
  }

  bool get _canSubmit =>
      !_posting &&
      !_busyMedia &&
      (_textController.text.trim().isNotEmpty || _attachments.isNotEmpty);

  List<TargetCandidate> get _mentionableAgents {
    return controller.scannedTargets
        .where((t) => t.isConversationAgent && t.canRelayRuntime)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final fieldRadius = BorderRadius.circular(12);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_attachments.isNotEmpty) ...[
          _AttachmentStrip(
            files: _attachments,
            colors: colors,
            onRemove: _removeAttachment,
          ),
          const SizedBox(height: 8),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ComposeCircleButton(
              key: const Key('desktop-home-feed-attach-button'),
              icon: Icons.attach_file_rounded,
              tooltip: strings.attachFiles,
              colors: colors,
              enabled: !_posting && !_busyMedia,
              onTap: _pickAttachments,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 36,
                child: AppleGlassSurface(
                  borderRadius: fieldRadius,
                  focused: _focused,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Center(
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          inputDecorationTheme: const InputDecorationTheme(
                            filled: false,
                            fillColor: Colors.transparent,
                            hoverColor: Colors.transparent,
                            focusColor: Colors.transparent,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                        ),
                        child: TextField(
                          key: const Key('desktop-home-feed-compose-button'),
                          controller: _textController,
                          focusNode: _focusNode,
                          enabled: !_posting,
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          style: TextStyle(
                            color: colors.text.withAlpha(235),
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            letterSpacing: -0.08,
                            height: 1.2,
                          ),
                          cursorColor: colors.info,
                          cursorWidth: 1.2,
                          decoration: InputDecoration.collapsed(
                            hintText: strings.composeFloatingHint,
                            hintStyle: TextStyle(
                              color: colors.textMuted.withAlpha(150),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              letterSpacing: -0.08,
                              height: 1.2,
                            ),
                          ),
                          onSubmitted: (_) {
                            if (_canSubmit) {
                              unawaited(_submit());
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _ComposeCircleButton(
              key: const Key('desktop-home-feed-compose-submit'),
              icon: Icons.arrow_upward_rounded,
              tooltip: strings.postUpdate,
              colors: colors,
              enabled: _canSubmit,
              emphasized: _canSubmit,
              onTap: () => unawaited(_submit()),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickAttachments() async {
    if (_busyMedia || _posting) {
      return;
    }
    setState(() => _busyMedia = true);
    try {
      final files = await openFiles();
      if (!mounted || files.isEmpty) {
        return;
      }
      setState(() {
        for (final file in files) {
          final path = file.path;
          if (path.isEmpty) {
            continue;
          }
          final exists = _attachments.any((item) => item.path == path);
          if (!exists) {
            _attachments.add(file);
          }
        }
      });
    } finally {
      if (mounted) {
        setState(() => _busyMedia = false);
      }
    }
  }

  void _removeAttachment(XFile file) {
    setState(() {
      _attachments.removeWhere((item) => item.path == file.path);
    });
  }

  Future<void> _submit() async {
    if (!_canSubmit) {
      return;
    }
    final body = _textController.text.trim();
    final attachmentPaths = [
      for (final file in _attachments)
        if (file.path.trim().isNotEmpty) file.path.trim(),
    ];
    setState(() => _posting = true);
    try {
      await controller.createUserFeedPost(
        body: body,
        mentionedAgentIds: _mentionedAgentIds(body),
        attachmentPaths: attachmentPaths,
      );
      if (!mounted) {
        return;
      }
      _textController.clear();
      setState(() => _attachments.clear());
      _focusNode.requestFocus();
    } finally {
      if (mounted) {
        setState(() => _posting = false);
      }
    }
  }

  List<String> _mentionedAgentIds(String body) {
    final ids = <String>{};
    for (final agent in _mentionableAgents) {
      final label = agent.label.trim().isEmpty ? agent.target : agent.label;
      if (body.contains('@$label') || body.contains('@${agent.target}')) {
        ids.add(agent.target);
      }
    }
    return ids.toList(growable: false);
  }
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({
    required this.files,
    required this.colors,
    required this.onRemove,
  });

  final List<XFile> files;
  final LicoThemeColors colors;
  final ValueChanged<XFile> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: files.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final file = files[index];
          final name = p.basename(file.path);
          return AppleGlassSurface(
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.insert_drive_file_outlined,
                    size: 13,
                    color: colors.text.withAlpha(210),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text.withAlpha(220),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.08,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    onPressed: () => onRemove(file),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: colors.textMuted.withAlpha(200),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ComposeCircleButton extends StatelessWidget {
  const _ComposeCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.onTap,
    this.enabled = true,
    this.emphasized = false,
  });

  final IconData icon;
  final String tooltip;
  final LicoThemeColors colors;
  final VoidCallback onTap;
  final bool enabled;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final iconColor = !enabled
        ? colors.text.withAlpha(90)
        : emphasized
        ? colors.text.withAlpha(245)
        : colors.text.withAlpha(220);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: AppleGlassSurface(
            borderRadius: BorderRadius.circular(18),
            focused: emphasized && enabled,
            fillAlpha: emphasized && enabled ? 40 : null,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(icon, size: 17, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}
