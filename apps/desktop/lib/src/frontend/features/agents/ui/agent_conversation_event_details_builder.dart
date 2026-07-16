import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/message_markdown.dart';

typedef ConversationEventDetailsBuilder =
    Widget Function({
      required String data,
      required Color foreground,
      required Color accent,
      required Color codeBackground,
      required Color blockBackground,
      required Color borderColor,
      required MessageMarkdownStyle renderStyle,
    });
