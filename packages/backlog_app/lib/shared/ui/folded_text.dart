import 'package:flutter/material.dart';

import '../tokens.dart';

/// [text] folded to [maxLines] (ending with …) unless [open]; a text that
/// does not fit gets a chevron, and a tap on it calls [onToggle]. A text that
/// fits stays plain. [textKey] goes to the [Text] itself.
class FoldedText extends StatelessWidget {
  const FoldedText(
    this.text, {
    super.key,
    required this.open,
    required this.onToggle,
    this.style,
    this.maxLines = 2,
    this.textKey,
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final bool open;
  final VoidCallback onToggle;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final tokens = BoardTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const chevron = 18.0;
        final painter = TextPainter(
          text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth - chevron);
        final long = painter.didExceedMaxLines;
        painter.dispose();
        if (!long) return Text(text, key: textKey, style: style);
        return InkWell(
          onTap: onToggle,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  text,
                  key: textKey,
                  style: style,
                  maxLines: open ? null : maxLines,
                  overflow: open ? null : TextOverflow.ellipsis,
                ),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more, size: chevron - 2, color: tokens.muted),
            ],
          ),
        );
      },
    );
  }
}
