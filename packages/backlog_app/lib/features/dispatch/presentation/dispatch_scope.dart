import 'package:flutter/widgets.dart';

import '../application/dispatch_controller.dart';

/// Hands the board's [DispatchController] to the detail and the navigation;
/// widgets below rebuild when the plan changes.
class DispatchScope extends InheritedNotifier<DispatchController> {
  const DispatchScope({super.key, required DispatchController controller, required super.child})
    : super(notifier: controller);

  /// The controller, or null outside a board (tests of single screens).
  static DispatchController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DispatchScope>()?.notifier;
}
