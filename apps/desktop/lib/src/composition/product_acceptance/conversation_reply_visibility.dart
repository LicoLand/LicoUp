import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks/disclosures.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';

/// Observes painted reply content, never treating a controller update as proof
/// that the corresponding message reached the user's viewport.
bool hasVisibleConversationReply(
  Element root,
  Iterable<AgentConversationMessage> messages,
) {
  final replies = <String, String>{
    for (final message in messages)
      if (message.role == 'assistant' && message.text.trim().isNotEmpty)
        agentConversationMarkdownIdentity(message): message.text,
  };
  var visible = false;
  void visit(Element element, String? replyIdentity, bool insideBody) {
    if (visible) return;
    final widget = element.widget;
    if (widget is AgentConversationMessageContent) {
      replyIdentity = replies[widget.identity] == widget.data
          ? widget.identity
          : null;
      insideBody = false;
    }
    if (widget is MessageMarkdown) {
      insideBody =
          replyIdentity != null &&
          widget.identity == '$replyIdentity/body' &&
          widget.data.trim().isNotEmpty;
    }
    if (insideBody && widget is RichText) {
      final paragraph = element.findRenderObject();
      if (paragraph is RenderParagraph &&
          paragraph.text.toPlainText().trim().isNotEmpty &&
          _isPaintedInView(element, paragraph)) {
        visible = true;
        return;
      }
    }
    element.visitChildElements(
      (child) => visit(child, replyIdentity, insideBody),
    );
  }

  visit(root, null, false);
  return visible;
}

bool _isPaintedInView(Element element, RenderParagraph paragraph) {
  if (!paragraph.attached || !paragraph.hasSize || paragraph.size.isEmpty) {
    return false;
  }
  final view = View.of(element);
  var visible = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  RenderObject child = paragraph;
  for (var parent = child.parent; parent != null; parent = child.parent) {
    if ((parent is RenderOffstage && parent.offstage) ||
        (parent is RenderOpacity && parent.opacity == 0) ||
        (parent is RenderAnimatedOpacity && parent.opacity.value == 0)) {
      return false;
    }
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      visible = visible.intersect(
        MatrixUtils.transformRect(parent.getTransformTo(null), clip),
      );
    }
    child = parent;
  }
  return !visible.isEmpty &&
      visible.overlaps(
        MatrixUtils.transformRect(
          paragraph.getTransformTo(null),
          paragraph.paintBounds,
        ),
      );
}
