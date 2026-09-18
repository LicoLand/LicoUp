import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Highly responsive text input component designed for chat composers and form fields.
///
/// Guarantees:
/// - **Local state preservation:** Local editing, IME composition, and cursor position
///   are retained across parent rebuilds and stream updates without jumping or dropping keystrokes.
/// - **Instant local echo:** Typing and keystrokes are reflected immediately without waiting
///   for asynchronous provider recomputations.
/// - **IME composition awareness:** Pressing Enter while an IME composition is active confirms
///   the candidate rather than prematurely submitting the message.
/// - **Desktop-first key handling:** Enter triggers [onSubmit], Shift+Enter inserts a newline.
///   Escape triggers [onCancel].
class InputField extends StatefulWidget {
  const InputField({
    super.key,
    this.controller,
    this.focusNode,
    this.hintText,
    this.enabled = true,
    this.minLines = 1,
    this.maxLines = 4,
    this.submitOnEnter = true,
    this.clearOnSubmit = true,
    this.onSubmit,
    this.onChanged,
    this.onCancel,
    this.style,
    this.hintStyle,
    this.decoration,
    this.prefix,
    this.suffix,
    this.autofocus = false,
    this.textInputAction = TextInputAction.send,
  });

  /// Optional external text editing controller. If omitted, an internal
  /// controller is managed for the lifetime of this widget.
  final TextEditingController? controller;

  /// Optional external focus node. If omitted, an internal focus node is managed.
  final FocusNode? focusNode;

  /// Placeholder hint text displayed when the field is empty.
  final String? hintText;

  /// Whether user input is enabled.
  final bool enabled;

  /// Minimum number of lines for multiline text input.
  final int minLines;

  /// Maximum number of lines before scrolling begins.
  final int? maxLines;

  /// Whether pressing Enter (without Shift) triggers [onSubmit].
  final bool submitOnEnter;

  /// Whether the input field is automatically cleared after a successful submit.
  final bool clearOnSubmit;

  /// Callback executed when text is submitted.
  final void Function(String text)? onSubmit;

  /// Callback executed whenever the text changes.
  final void Function(String text)? onChanged;

  /// Callback executed when the Escape key is pressed.
  final VoidCallback? onCancel;

  /// Text style of the input text.
  final TextStyle? style;

  /// Text style of the hint text.
  final TextStyle? hintStyle;

  /// Custom input decoration override.
  final InputDecoration? decoration;

  /// Widget placed before the input text.
  final Widget? prefix;

  /// Widget placed after the input text.
  final Widget? suffix;

  /// Whether the field should automatically request focus.
  final bool autofocus;

  /// Keyboard action type (defaults to [TextInputAction.send]).
  final TextInputAction textInputAction;

  @override
  State<InputField> createState() => _InputFieldState();
}

class _InputFieldState extends State<InputField> {
  TextEditingController? _internalController;
  FocusNode? _internalFocusNode;

  TextEditingController get _effectiveController =>
      widget.controller ?? (_internalController ??= TextEditingController());

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  void didUpdateWidget(covariant InputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller &&
        oldWidget.controller == null) {
      _internalController?.dispose();
      _internalController = null;
    }
    if (widget.focusNode != oldWidget.focusNode &&
        oldWidget.focusNode == null) {
      _internalFocusNode?.dispose();
      _internalFocusNode = null;
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    _internalFocusNode?.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      // 1. Escape key -> onCancel
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (widget.onCancel != null) {
          widget.onCancel!();
          return KeyEventResult.handled;
        }
      }

      // 2. Enter key handling
      final isEnter =
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter;

      if (isEnter) {
        // IME composition check: If user is actively selecting IME candidate, ignore enter
        if (_effectiveController.value.isComposingRangeValid) {
          return KeyEventResult.ignored;
        }

        final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;

        if (widget.submitOnEnter && !isShiftPressed) {
          _submit();
          return KeyEventResult.handled;
        }
      }
    }

    return KeyEventResult.ignored;
  }

  int _lastSubmitTime = 0;

  void _submit() {
    if (!widget.enabled) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSubmitTime < 50) return;

    final text = _effectiveController.text;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _lastSubmitTime = now;
    widget.onSubmit?.call(trimmed);

    if (widget.clearOnSubmit) {
      _effectiveController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final effectiveDecoration =
        (widget.decoration ??
                InputDecoration(
                  hintText: widget.hintText,
                  hintStyle:
                      widget.hintStyle ??
                      theme.textTheme.bodyMedium?.copyWith(
                        color: theme.hintColor,
                      ),
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  prefixIcon: widget.prefix,
                  suffixIcon: widget.suffix,
                ))
            .copyWith(enabled: widget.enabled);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: TextField(
        controller: _effectiveController,
        focusNode: _effectiveFocusNode,
        enabled: widget.enabled,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        style: widget.style ?? theme.textTheme.bodyMedium,
        decoration: effectiveDecoration,
        onChanged: widget.onChanged,
        onSubmitted: (_) {
          if (widget.submitOnEnter &&
              !_effectiveController.value.isComposingRangeValid) {
            _submit();
          }
        },
      ),
    );
  }
}
