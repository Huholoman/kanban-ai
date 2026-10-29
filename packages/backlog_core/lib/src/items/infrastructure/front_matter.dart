/// A Markdown document split into its YAML front matter and body.
final class FrontMatterDocument {
  const FrontMatterDocument(this.frontMatter, this.body, [this.rawBody = '']);

  /// The YAML between the `---` fences, or null when there is none.
  final String? frontMatter;

  /// Everything after the closing fence, without the blank lines that
  /// separate it from the front matter.
  final String body;

  /// Everything after the closing fence, byte for byte.
  final String rawBody;

  static FrontMatterDocument parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceFirst('\uFEFF', '');
    final lines = normalized.split('\n');
    if (lines.isEmpty || lines.first.trimRight() != '---') {
      return FrontMatterDocument(null, normalized);
    }
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trimRight();
      if (line == '---' || line == '...') {
        final yaml = lines.sublist(1, i).join('\n');
        final rawBody = lines.sublist(i + 1).join('\n');
        final body = rawBody.replaceFirst(RegExp(r'^\n+'), '');
        return FrontMatterDocument(yaml.isEmpty ? '' : '$yaml\n', body, rawBody);
      }
    }
    return FrontMatterDocument(null, normalized);
  }

  /// [frontMatter] must end with a newline.
  static String compose(String frontMatter, String body) {
    final trimmed = body.trimRight();
    return trimmed.isEmpty ? '---\n$frontMatter---\n' : '---\n$frontMatter---\n\n$trimmed\n';
  }
}
