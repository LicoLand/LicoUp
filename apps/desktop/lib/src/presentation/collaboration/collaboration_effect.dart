import 'package:presentation_contract/presentation_contract.dart';

sealed class CollaborationEffect {
  const CollaborationEffect({this.trace});

  final TraceContext? trace;
}

/// A command's expected head was stale; [currentHead] is the observed head.
final class CollaborationCommandConflicted extends CollaborationEffect {
  const CollaborationCommandConflicted(this.currentHead, {super.trace});

  final int currentHead;
}

/// A command or revision load was refused; [code] is the wire reason.
final class CollaborationCommandRejected extends CollaborationEffect {
  const CollaborationCommandRejected(this.code, {super.trace});

  final String code;
}
