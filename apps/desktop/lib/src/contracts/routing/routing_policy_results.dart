import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/routing/routing_policy_models.dart';

@immutable
class RoutingPolicyValidationError {
  const RoutingPolicyValidationError({
    required this.path,
    required this.message,
    this.line = 0,
    this.column = 0,
  });

  final String path;
  final String message;
  final int line;
  final int column;

  @override
  String toString() {
    if (line > 0) {
      return '$path: $message (line $line, col $column)';
    }
    return '$path: $message';
  }
}

sealed class RoutingPolicyParseResult {
  const RoutingPolicyParseResult();
}

class RoutingPolicyParseSuccess extends RoutingPolicyParseResult {
  const RoutingPolicyParseSuccess(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyParseFailure extends RoutingPolicyParseResult {
  const RoutingPolicyParseFailure(this.error);

  final RoutingPolicyValidationError error;
}

sealed class RoutingPolicyStoreEvent {
  const RoutingPolicyStoreEvent();
}

class RoutingPolicyStoreLoaded extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreLoaded(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyStoreReloaded extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreReloaded(this.document);

  final RoutingPolicyDocument document;
}

class RoutingPolicyStoreValidationFailed extends RoutingPolicyStoreEvent {
  const RoutingPolicyStoreValidationFailed(this.error);

  final RoutingPolicyValidationError error;
}

abstract class RoutingPolicyStore {
  Future<RoutingPolicyDocument> load();
  Future<void> save(RoutingPolicyDocument policy);
  Future<void> clear();
  Stream<RoutingPolicyStoreEvent> watch();
  RoutingPolicyDocument get active;
  RoutingPolicyValidationError? get lastError;
  Future<void> dispose();
}
