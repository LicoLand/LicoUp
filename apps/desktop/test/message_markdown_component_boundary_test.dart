import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('message markdown composer delegates independent parsing and views', () {
    final root = File(
      'lib/src/frontend/shared/ui/message_markdown.dart',
    ).readAsStringSync();
    final parser = File(
      'lib/src/frontend/shared/ui/message_markdown_parser.dart',
    ).readAsStringSync();
    final view = File(
      'lib/src/frontend/shared/ui/message_markdown_block_view.dart',
    ).readAsStringSync();
    expect(root, contains('MessageMarkdownBlockView('));
    expect(root, isNot(contains("RegExp(r'^:?-{3,}:?\$')")));
    expect(parser, isNot(contains("package:flutter/material.dart")));
    expect(view, isNot(contains('parseMessageMarkdownBlocks(')));
  });
}
