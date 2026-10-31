import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../dispatch/presentation/agent_panel.dart';
import '../application/detail_navigation.dart';
import '../application/item_controller.dart';
import 'detail_content.dart';
import 'detail_header.dart';

/// The item detail as a full screen, for narrow windows.
class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.reference, this.onAddChild});

  final String reference;
  final ValueChanged<ItemDto>? onAddChild;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ItemDetailView(reference: reference, onClose: () => Navigator.of(context).pop(), onAddChild: onAddChild),
    ),
  );
}

/// Detail of one item: fields, relations and the Markdown body, all editable.
/// Used as a page and as the side panel next to the board. Linked items open
/// inside the view (parents from the breadcrumb, siblings with ‹ ›, children
/// and relations from their lists), with a back button for the way taken.
/// Give it a new key to start over at another [reference].
class ItemDetailView extends StatefulWidget {
  const ItemDetailView({
    super.key,
    required this.reference,
    this.onClose,
    this.closeIcon = Icons.close,
    this.onScope,
    this.onAddChild,
  });

  /// Id (or a shortened id) of the item shown first.
  final String reference;
  final VoidCallback? onClose;
  final IconData closeIcon;

  /// Narrows the board to everything under an epic; without it the epic has
  /// no *Scope board* button.
  final void Function(String epicId)? onScope;

  /// Opens the *New item* dialog for a child of the shown item; without it
  /// there is no *Add child* button.
  final ValueChanged<ItemDto>? onAddChild;

  @override
  State<ItemDetailView> createState() => _ItemDetailViewState();
}

class _ItemDetailViewState extends State<ItemDetailView> {
  late var _navigation = DetailNavigation(widget.reference);
  AppScope? _scope;
  ItemController? _controller;
  StreamSubscription<String>? _notices;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = AppScope.of(context);
    if (_controller == null) _start();
  }

  /// A controller for the item [_navigation] is at.
  void _start() {
    final scope = _scope!;
    final controller = _controller = ItemController(scope.api, _navigation.current, agent: scope.config.agent);
    _notices = controller.notices.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
    unawaited(controller.start());
  }

  void _stop() {
    unawaited(_notices?.cancel());
    _controller?.dispose();
  }

  void _go(DetailNavigation next) {
    if (next == _navigation) return;
    setState(() {
      _navigation = next;
      _stop();
      _start();
    });
  }

  void _open(String id) => _go(_navigation.open(id));

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Column(
        key: ObjectKey(controller), // fresh fold and edit state per item
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DetailHeader(
            controller: controller,
            onOpen: _open,
            onSibling: (id) => _go(_navigation.replace(id)),
            onBack: _navigation.canGoBack ? () => _go(_navigation.back()) : null,
            onClose: widget.onClose,
            closeIcon: widget.closeIcon,
            onScope: widget.onScope,
            onAddChild: widget.onAddChild,
          ),
          if (controller.item case final item?) AgentPanel(key: ValueKey('agent-${item.id}'), item: item),
          const Divider(height: 1),
          Expanded(
            child: switch ((controller.detail, controller.error)) {
              (_?, _) => DetailContent(controller: controller, onOpen: _open),
              (null, final Object error) => Center(child: Text('$error')),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}
