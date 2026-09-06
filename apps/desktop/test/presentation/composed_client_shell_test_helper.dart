import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';

Widget composedClientShell(
  ClientController controller, {
  void Function(ClientAppComposition composition)? onComposed,
}) {
  final composition = ClientAppComposition(controller: controller);
  onComposed?.call(composition);
  addTearDown(composition.dispose);
  return ClientShell(
    binding: composition.binding,
    renderer: composition.renderer,
  );
}
