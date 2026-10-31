import 'package:flutter/material.dart';

import '../tokens.dart';

/// Label (and optional icon) of the kit's buttons. The colours are set
/// explicitly: on the web a button's label did not follow `foregroundColor`.
Widget _content(String label, IconData? icon, Color color, {double iconSize = 16}) {
  final text = Text(label, style: TextStyle(color: color));
  if (icon == null) return text;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: iconSize, color: color),
      const SizedBox(width: 6),
      Flexible(child: text),
    ],
  );
}

const _padding = EdgeInsets.symmetric(horizontal: 14);

/// The filled accent button of the main action, [BoardTokens.controlHeight]
/// high. Disabled when [onPressed] is null.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final color = onPressed == null ? tokens.faint : tokens.onAccent;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: tokens.accent,
        foregroundColor: tokens.onAccent,
        disabledForegroundColor: tokens.faint,
        minimumSize: const Size(0, BoardTokens.controlHeight),
        // The theme is compact, which would take 8 px off the minimum height.
        visualDensity: VisualDensity.standard,
        padding: _padding,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: _content(label, icon, color),
    );
  }
}

/// The outlined button of a secondary action, as high as [PrimaryButton].
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.trailing});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  /// Shown after the label (a badge).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final color = onPressed == null ? tokens.faint : tokens.text;
    final content = _content(label, icon, color);
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.text,
        disabledForegroundColor: tokens.faint,
        side: BorderSide(color: tokens.borderStrong),
        minimumSize: const Size(0, BoardTokens.controlHeight),
        // The theme is compact, which would take 8 px off the minimum height.
        visualDensity: VisualDensity.standard,
        padding: _padding,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: trailing == null
          ? content
          : Row(mainAxisSize: MainAxisSize.min, children: [content, const SizedBox(width: 6), trailing!]),
    );
  }
}

/// A borderless text button for dialog dismissals and inline links
/// ("Cancel", "Clear"). [accent] colours it as a link; [compact] drops the
/// minimum size and shrinks the padding.
class LinkButton extends StatelessWidget {
  const LinkButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.accent = false,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    final base = accent ? tokens.accent : tokens.text;
    final color = onPressed == null ? tokens.faint : base;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: base,
        disabledForegroundColor: tokens.faint,
        minimumSize: compact ? Size.zero : const Size(0, BoardTokens.controlHeight),
        visualDensity: compact ? null : VisualDensity.standard,
        padding: compact ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4) : _padding,
        tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
      ),
      child: _content(label, icon, color, iconSize: 18),
    );
  }
}

/// A compact muted icon button with a tooltip.
class IconActionButton extends StatelessWidget {
  const IconActionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 20,
    this.box,
  });

  final String tooltip;
  final IconData icon;

  /// Null disables it.
  final VoidCallback? onPressed;
  final double size;

  /// Fixed square side; the default icon-button size when null.
  final double? box;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: size,
    padding: box == null ? null : EdgeInsets.zero,
    constraints: box == null ? null : BoxConstraints.tightFor(width: box, height: box),
    color: BoardTokens.of(context).muted,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
