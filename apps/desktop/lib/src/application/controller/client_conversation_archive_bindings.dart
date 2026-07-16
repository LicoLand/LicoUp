import 'package:flutter/widgets.dart';

mixin ClientConversationArchiveBindings {
  TextEditingController get snapshotRootController;
  TextEditingController get archiveQueryController;
  TextEditingController get archiveDestinationController;

  String get snapshotRootDraft => snapshotRootController.text;

  set snapshotRootDraft(String value) {
    snapshotRootController.text = value;
  }

  String get archiveQueryDraft => archiveQueryController.text;

  set archiveQueryDraft(String value) {
    archiveQueryController.text = value;
  }

  String get archiveDestinationDraft => archiveDestinationController.text;

  set archiveDestinationDraft(String value) {
    archiveDestinationController.text = value;
  }
}
