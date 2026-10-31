import 'dart:convert';

/// The keys the TUI reacts to.
enum KeyKind {
  char,
  enter,
  escape,
  backspace,
  delete,
  tab,
  up,
  down,
  left,
  right,
  home,
  end,
  pageUp,
  pageDown,
  interrupt,
  unknown,
}

/// One key press; [char] is set for [KeyKind.char].
final class Key {
  const Key(this.kind, [this.char]);

  const Key.char(String this.char) : kind = KeyKind.char;

  final KeyKind kind;
  final String? char;

  bool isChar(String c) => kind == KeyKind.char && char == c;

  @override
  bool operator ==(Object other) => other is Key && other.kind == kind && other.char == char;

  @override
  int get hashCode => Object.hash(kind, char);

  @override
  String toString() => kind == KeyKind.char ? 'Key($char)' : 'Key(${kind.name})';
}

const _csi = {
  'A': KeyKind.up,
  'B': KeyKind.down,
  'C': KeyKind.right,
  'D': KeyKind.left,
  'H': KeyKind.home,
  'F': KeyKind.end,
  '1~': KeyKind.home,
  '7~': KeyKind.home,
  '4~': KeyKind.end,
  '8~': KeyKind.end,
  '3~': KeyKind.delete,
  '5~': KeyKind.pageUp,
  '6~': KeyKind.pageDown,
};

/// The keys in one chunk of terminal input (raw mode). A lone ESC byte is
/// [KeyKind.escape]; `ESC [` / `ESC O` start the sequences of arrows and
/// the like; other bytes are UTF-8 text and control characters.
List<Key> decodeKeys(List<int> bytes) {
  final keys = <Key>[];
  final text = utf8.decode(bytes, allowMalformed: true);
  var i = 0;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x1b) {
      if (i + 1 < text.length && (text[i + 1] == '[' || text[i + 1] == 'O')) {
        var end = i + 2;
        while (end < text.length && !_isFinal(text.codeUnitAt(end))) {
          end++;
        }
        final body = text.substring(i + 2, end < text.length ? end + 1 : end);
        keys.add(Key(_csi[body.replaceFirst(RegExp(r'^1;\d+'), '')] ?? KeyKind.unknown));
        i = end + 1;
      } else {
        keys.add(const Key(KeyKind.escape));
        i++;
      }
      continue;
    }
    final width = c >= 0xd800 && c < 0xdc00 && i + 1 < text.length ? 2 : 1; // a surrogate pair
    keys.add(switch (c) {
      0x0d || 0x0a => const Key(KeyKind.enter),
      0x7f || 0x08 => const Key(KeyKind.backspace),
      0x09 => const Key(KeyKind.tab),
      0x03 => const Key(KeyKind.interrupt),
      < 0x20 => const Key(KeyKind.unknown),
      _ => Key.char(text.substring(i, i + width)),
    });
    i += width;
  }
  return keys;
}

/// `ESC [` sequences end with a byte in `@`–`~`.
bool _isFinal(int c) => c >= 0x40 && c <= 0x7e;
