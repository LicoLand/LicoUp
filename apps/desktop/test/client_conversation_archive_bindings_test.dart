import 'package:licoup/src/application/controller/client_conversation_archive_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('archive draft bindings own only local semantic text state', () {
    final host = _ArchiveBindingsHost();

    host.snapshotRootDraft = '/local/snapshots';
    host.archiveQueryDraft = 'local keyword';
    host.archiveDestinationDraft = '/local/archive';

    expect(host.snapshotRootDraft, '/local/snapshots');
    expect(host.archiveQueryDraft, 'local keyword');
    expect(host.archiveDestinationDraft, '/local/archive');
  });
}

final class _ArchiveBindingsHost with ClientConversationArchiveBindings {}
