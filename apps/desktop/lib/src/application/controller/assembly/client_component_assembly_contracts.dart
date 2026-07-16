import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';

typedef ClientComponentStatusSink =
    void Function({
      required String chinese,
      required String english,
      required String caption,
      required String errorCode,
    });

typedef ClientRoutingPolicySink =
    void Function(
      RoutingPolicyDocument document,
      TaskRouteCoordinatorPort? coordinator,
    );
