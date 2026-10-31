import 'dart:convert';

/// What `dispatcher.pr.state` says about a pull request.
enum PullRequestState {
  open,
  merged,

  /// Closed without being merged.
  closed,

  /// The output said none of these.
  unknown;

  /// Reads the output of `dispatcher.pr.state`: JSON with `merged`
  /// (`true`), `merged_at`/`mergedAt` or `state` (`open`, `closed`,
  /// `merged`; also a list, the first entry counts) — Gitea's API, `gh --json`
  /// — or plain text, whose first of the words `merged`, `closed`, `open`
  /// decides (case does not matter; `MERGED` from `gh … --jq .state`).
  static PullRequestState parse(String output) {
    final text = output.trim();
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        var json = jsonDecode(text);
        if (json is List && json.isNotEmpty) json = json.first;
        if (json is Map) {
          final at = json['merged_at'] ?? json['mergedAt'];
          if (json['merged'] == true || (at is String && at.isNotEmpty)) return merged;
          return _word('${json['state'] ?? ''}');
        }
      } on FormatException {
        // Not JSON after all; read it as text.
      }
    }
    return _word(text);
  }

  static PullRequestState _word(String text) {
    final match = RegExp(r'\b(merged|closed|open|opened)\b', caseSensitive: false).firstMatch(text);
    return switch (match?.group(1)?.toLowerCase()) {
      'merged' => merged,
      'closed' => closed,
      'open' || 'opened' => open,
      _ => unknown,
    };
  }
}
