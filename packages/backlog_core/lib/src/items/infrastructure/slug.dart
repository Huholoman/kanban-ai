const _folded = {
  'á': 'a',
  'ä': 'a',
  'à': 'a',
  'â': 'a',
  'å': 'a',
  'ą': 'a',
  'č': 'c',
  'ć': 'c',
  'ç': 'c',
  'ď': 'd',
  'é': 'e',
  'ě': 'e',
  'ë': 'e',
  'è': 'e',
  'ê': 'e',
  'ę': 'e',
  'í': 'i',
  'ï': 'i',
  'ì': 'i',
  'î': 'i',
  'ľ': 'l',
  'ĺ': 'l',
  'ł': 'l',
  'ň': 'n',
  'ń': 'n',
  'ñ': 'n',
  'ó': 'o',
  'ö': 'o',
  'ô': 'o',
  'ò': 'o',
  'ő': 'o',
  'ř': 'r',
  'ŕ': 'r',
  'š': 's',
  'ś': 's',
  'ß': 'ss',
  'ť': 't',
  'ú': 'u',
  'ů': 'u',
  'ü': 'u',
  'ù': 'u',
  'û': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
};

/// `Zürich DB backups` → `zurich-db-backups`, for readable file names.
String slugify(String text, {int maxLength = 48}) {
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    buffer.write(_folded[char] ?? char);
  }
  var slug = buffer.toString().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > maxLength) {
    slug = slug.substring(0, maxLength).replaceAll(RegExp(r'-[^-]*$'), '');
  }
  return slug;
}
