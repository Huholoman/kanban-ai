import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../items/domain/item.dart';
import '../../shared/errors.dart';
import '../../workflow/domain/touches_config.dart';
import '../domain/touches_estimate.dart';

/// [TouchesModel] that runs `touches.suggest` (no shell) in the code
/// repository, the first of [candidates] that exists: the prompt goes on its standard input unless the
/// command takes it as `{prompt}`; its standard output is the answer.
final class CommandTouchesModel implements TouchesModel {
  CommandTouchesModel(this.config, {required this.backlog, required this.candidates, this.environment});

  final TouchesConfig config;

  /// The absolute path of the backlog folder (`{backlog}`).
  final String backlog;

  /// Folders the code repository may be in, in order (`{repo}`).
  final List<String> candidates;
  final Map<String, String>? environment;

  @override
  Future<String> ask(Item item, String prompt) async {
    String? repo;
    for (final folder in candidates) {
      if (await Directory(folder).exists()) {
        repo = folder;
        break;
      }
    }
    if (repo == null) throw const UnavailableException('touches.suggest: the code repository is not there.');
    final command = config.suggest.render({
      'id': item.id.value,
      'title': item.title,
      'backlog': backlog,
      'repo': repo,
      'prompt': prompt,
    });
    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.skip(1).toList(),
        workingDirectory: repo,
        environment: environment,
      );
    } on ProcessException catch (error) {
      throw UnavailableException('touches.suggest: cannot run "${command.first}": ${error.message}');
    }
    final output = StringBuffer(), errors = StringBuffer();
    final done = Future.wait([
      process.stdout.transform(utf8.decoder).forEach(output.write),
      process.stderr.transform(utf8.decoder).forEach(errors.write),
    ]);
    try {
      if (!config.promptInArguments) process.stdin.write(prompt);
      await process.stdin.close();
    } on Object {
      // The command does not read its standard input; that is fine.
    }
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(config.timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw UnavailableException('touches.suggest did not finish within ${config.timeout.inSeconds} s.');
    }
    await done;
    if (exitCode != 0) {
      final lines = LineSplitter.split(
        '$errors'.trim().isEmpty ? '$output' : '$errors',
      ).where((line) => line.trim().isNotEmpty).toList();
      final tail = lines.length <= 5 ? lines : lines.sublist(lines.length - 5);
      throw UnavailableException('touches.suggest failed with exit code $exitCode: ${tail.join(' | ')}');
    }
    return '$output';
  }
}
