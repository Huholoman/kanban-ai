import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Scrolls [controller] (a vertical page) with Page Up, Page Down, Home and
/// End wherever the focus is, as long as the page is on top and the keys do
/// not belong to something else: a text field, or another vertical
/// scrollable holding the focus (Flutter's own shortcuts scroll that one).
/// Flutter scrolls with these keys only when the focus sits inside the
/// scrollable, and on a board nothing usually has the focus.
class PageKeys extends StatefulWidget {
  const PageKeys({super.key, required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  State<PageKeys> createState() => _PageKeysState();
}

class _PageKeysState extends State<PageKeys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handle);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handle);
    super.dispose();
  }

  bool _handle(KeyEvent event) {
    if (event is KeyUpEvent || !mounted) return false;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed || keyboard.isShiftPressed) {
      return false;
    }
    if (key != LogicalKeyboardKey.pageUp &&
        key != LogicalKeyboardKey.pageDown &&
        key != LogicalKeyboardKey.home &&
        key != LogicalKeyboardKey.end) {
      return false;
    }
    final controller = widget.controller;
    if (!controller.hasClients || !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus != null) {
      if (focus.findAncestorStateOfType<EditableTextState>() != null) return false;
      final nearest = Scrollable.maybeOf(focus);
      if (nearest != null && nearest.position.axis == Axis.vertical) return false;
      final vertical = Scrollable.maybeOf(focus, axis: Axis.vertical);
      if (vertical != null && vertical.position != controller.position) return false;
    }
    final position = controller.position;
    final page = 0.8 * position.viewportDimension;
    final target = switch (key) {
      LogicalKeyboardKey.pageUp => position.pixels - page,
      LogicalKeyboardKey.pageDown => position.pixels + page,
      LogicalKeyboardKey.home => position.minScrollExtent,
      _ => position.maxScrollExtent,
    };
    position.moveTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeInOut,
    );
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
