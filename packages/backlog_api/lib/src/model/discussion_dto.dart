import 'json.dart';

/// One comment of an item's discussion (the `## Discussion` section of its
/// body), as `backlog --json show` gives it.
final class CommentDto {
  const CommentDto({
    required this.author,
    required this.at,
    required this.text,
    this.question = false,
    this.note = false,
  });

  factory CommentDto.fromJson(Json json) => CommentDto(
    author: json.string('author'),
    at: DateTime.parse(json.string('at')),
    text: json.string('text'),
    question: json.boolean('question'),
    note: json.boolean('note'),
  );

  final String author;
  final DateTime at;

  /// Markdown.
  final String text;

  /// An agent's question that waits for a person until someone else comments.
  final bool question;

  /// Only a note: it neither answers a question nor wakes the item's agent.
  final bool note;

  Json toJson() => {
    'author': author,
    'at': at.toUtc().toIso8601String(),
    'text': text,
    'question': question,
    'note': note,
  };
}

/// `POST /api/items/<ref>/comments`: a comment by [author] (the server's
/// default when null); [question] makes the item need a person; a [note]
/// neither answers a question nor wakes the item's agent.
final class CommentRequest {
  const CommentRequest(this.text, {this.author, this.question = false, this.note = false});

  factory CommentRequest.fromJson(Json json) => CommentRequest(
    json.string('text'),
    author: json.optionalString('author'),
    question: json.boolean('question'),
    note: json.boolean('note'),
  );

  final String text;
  final String? author;
  final bool question;
  final bool note;

  Json toJson() => {'text': text, 'author': ?author, if (question) 'question': question, if (note) 'note': note};
}
