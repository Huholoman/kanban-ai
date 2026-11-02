import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../tokens.dart';

/// Shows [child] whole when it is at most [maxHeight] high; a taller child is
/// cut to [maxHeight] (fading out at the bottom) with *Show more* under it,
/// which unfolds it (and *Show less* folds it again).
class FoldBox extends StatefulWidget {
  const FoldBox({super.key, required this.child, this.maxHeight = 240});

  final Widget child;
  final double maxHeight;

  @override
  State<FoldBox> createState() => _FoldBoxState();
}

class _FoldBoxState extends State<FoldBox> {
  var _tall = false;
  var _open = false;

  void _measured(bool tall) {
    if (tall == _tall) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && tall != _tall) setState(() => _tall = tall);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final folded = _tall && !_open;
    Widget content = _HeightLimit(
      maxHeight: widget.maxHeight,
      fold: !_open,
      onMeasured: _measured,
      child: widget.child,
    );
    if (folded) {
      content = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black, Colors.black, Colors.transparent],
          stops: [0, 0.75, 1],
        ).createShader(bounds),
        child: content,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        content,
        if (_tall)
          TextButton.icon(
            key: const ValueKey('fold-toggle'),
            onPressed: () => setState(() => _open = !_open),
            style: TextButton.styleFrom(
              foregroundColor: tokens.accent,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: tokens.accent),
            label: Text(_open ? 'Show less' : 'Show more', style: TextStyle(color: tokens.accent)),
          ),
      ],
    );
  }
}

/// Lays its child out at its full height; with [fold] it is at most
/// [maxHeight] high itself (clipping the rest). Tells [onMeasured] whether
/// the child is taller than [maxHeight].
class _HeightLimit extends SingleChildRenderObjectWidget {
  const _HeightLimit({required this.maxHeight, required this.fold, required this.onMeasured, required super.child});

  final double maxHeight;
  final bool fold;
  final ValueChanged<bool> onMeasured;

  @override
  _RenderHeightLimit createRenderObject(BuildContext context) =>
      _RenderHeightLimit(maxHeight: maxHeight, fold: fold, onMeasured: onMeasured);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightLimit renderObject) {
    renderObject
      ..maxHeight = maxHeight
      ..fold = fold
      ..onMeasured = onMeasured;
  }
}

class _RenderHeightLimit extends RenderProxyBox {
  _RenderHeightLimit({required double maxHeight, required bool fold, required this.onMeasured})
    : _maxHeight = maxHeight,
      _fold = fold;

  double _maxHeight;
  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  bool _fold;
  set fold(bool value) {
    if (value == _fold) return;
    _fold = value;
    markNeedsLayout();
  }

  ValueChanged<bool> onMeasured;
  var _clipped = false;

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(BoxConstraints(minWidth: constraints.minWidth, maxWidth: constraints.maxWidth), parentUsesSize: true);
    final full = child.size.height;
    final tall = full > _maxHeight;
    onMeasured(tall);
    _clipped = _fold && tall;
    size = constraints.constrain(Size(child.size.width, _clipped ? _maxHeight : full));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_clipped) {
      layer = null;
      return super.paint(context, offset);
    }
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      super.paint,
      oldLayer: layer as ClipRectLayer?,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!(Offset.zero & size).contains(position)) return false;
    return super.hitTestChildren(result, position: position);
  }
}
