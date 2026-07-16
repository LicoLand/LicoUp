import 'package:flutter/widgets.dart';
import 'package:flutter_client/src/application/controller/client_conversation_archive_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('archive draft bindings own only local text-controller state', () {
    final host = _ArchiveBindingsHost();
    addTearDown(host.dispose);

    host.snapshotRootDraft = '/local/snapshots';
    host.archiveQueryDraft = 'local keyword';
    host.archiveDestinationDraft = '/local/archive';

    expect(host.snapshotRootController.text, '/local/snapshots');
    expect(host.archiveQueryController.text, 'local keyword');
    expect(host.archiveDestinationController.text, '/local/archive');
  });
}

final class _ArchiveBindingsHost with ClientConversationArchiveBindings {
  @override
  final snapshotRootController = TextEditingController();
  @override
  final archiveQueryController = TextEditingController();
  @override
  final archiveDestinationController = TextEditingController();

  void dispose() {
    snapshotRootController.dispose();
    archiveQueryController.dispose();
    archiveDestinationController.dispose();
  }
}
