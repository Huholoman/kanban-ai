import 'dart:math';

import '../../shared/errors.dart';
import 'config_draft.dart';
import 'server_config.dart';

/// A global command as written in `server.yaml` ([ServerSettings.commands]):
/// [command] as text (a list joined by spaces), [restart] null for none and
/// [ServerCommand.sameProgram] for `true`.
final class ServerCommandSetting {
  const ServerCommandSetting({required this.name, required this.command, this.dir, this.restart});

  final String name;
  final String command;
  final String? dir;
  final String? restart;
}

/// Typed reads and edits of a `server.yaml` [draft] (see
/// [parseServerConfigYaml]). Input is checked here; an empty input removes
/// the key, so that the server's default applies again.
final class ServerSettings {
  ServerSettings(this.draft);

  final ConfigDraft draft;

  /// The value of [key] as text (lists comma-separated), null when absent.
  String? text(String key) => switch (draft.valueAt([key])) {
    null => null,
    final List<Object?> list => list.join(', '),
    final value => '$value',
  };

  /// Sets `host` from comma-separated addresses.
  void setHosts(String input) {
    final hosts = _items(input);
    for (final host in hosts) {
      if (host.contains(RegExp(r'[\s/]'))) throw InvalidInputException('"$host" is not an address.');
    }
    _set('host', hosts.isEmpty ? null : hosts);
  }

  void setPort(String input) {
    final text = input.trim();
    final port = int.tryParse(text);
    if (text.isNotEmpty && (port == null || port < 1 || port > 65535)) {
      throw InvalidInputException('The port must be a number from 1 to 65535, not "$text".');
    }
    _set('port', port);
  }

  /// Sets `allow` from comma-separated IPs or CIDR ranges.
  void setAllow(String input) {
    final ranges = _items(input);
    for (final range in ranges) {
      if (!isAddressRange(range)) throw InvalidInputException('Not an IP address or CIDR range: $range');
    }
    _set('allow', ranges.isEmpty ? null : ranges);
  }

  void setToken(String input) {
    final token = input.trim();
    if (token.contains(RegExp(r'\s'))) throw const InvalidInputException('The token must not contain spaces.');
    _set('token', token.isEmpty ? null : token);
  }

  /// Sets a new random token and returns it.
  String generateToken({Random? random}) {
    final token = generateServerToken(random: random);
    _set('token', token);
    return token;
  }

  void setPath(String key, String input) {
    if (key != 'web' && key != 'projects') throw InvalidInputException('$key is not a path.');
    final path = input.trim();
    _set(key, path.isEmpty ? null : path);
  }

  bool get quiet => draft.valueAt(['quiet']) == true;

  /// The global commands (`commands`) as written.
  List<ServerCommandSetting> get commands {
    final list = draft.valueAt(['commands']);
    if (list is! List) return const [];
    return [
      for (final entry in list)
        if (entry is Map)
          ServerCommandSetting(
            name: '${entry['name'] ?? ''}',
            command: switch (entry['command']) {
              final List<Object?> parts => parts.join(' '),
              final value => '${value ?? ''}',
            },
            dir: entry['dir'] == null ? null : '${entry['dir']}',
            restart: switch (entry['restart']) {
              true => ServerCommand.sameProgram,
              null || false => null,
              final program => '$program',
            },
          )
        else
          ServerCommandSetting(name: '$entry', command: ''),
    ];
  }

  /// Adds command [name] running [command] (with `sh -c`).
  void addCommand(String name, String command) {
    final label = name.trim();
    if (label.isEmpty) throw const InvalidInputException('Give the command a name.');
    if (commands.any((existing) => existing.name == label)) {
      throw InvalidInputException('There is a command "$label" already.');
    }
    final value = {'name': label, 'command': _commandText(command)};
    if (draft.valueAt(['commands']) is List) {
      draft.insert(['commands'], commands.length, value);
    } else {
      draft.set(['commands'], [value]);
    }
  }

  void removeCommand(int index) {
    _command(index);
    draft.remove(['commands', index]);
    if ((draft.valueAt(['commands']) as List?)?.isEmpty ?? false) draft.remove(['commands']);
  }

  /// Sets what command [index] runs (with `sh -c`).
  void setCommandRun(int index, String command) {
    _command(index);
    draft.set(['commands', index, 'command'], _commandText(command));
  }

  /// Sets the working folder of command [index] (empty: the server's).
  void setCommandDir(int index, String input) {
    _command(index);
    final dir = input.trim();
    if (dir.isEmpty) {
      draft.remove(['commands', index, 'dir']);
    } else {
      draft.set(['commands', index, 'dir'], dir);
    }
  }

  /// Sets what the server restarts as after command [index] succeeded:
  /// `true` (or `yes`) the program it runs as, another text that program,
  /// empty (or `false`, `no`) no restart.
  void setCommandRestart(int index, String input) {
    _command(index);
    final text = input.trim();
    if (text.contains(RegExp(r'\s'))) throw InvalidInputException('"$text" is not a program.');
    final Object? value = switch (text.toLowerCase()) {
      '' || 'false' || 'no' => null,
      'true' || 'yes' => true,
      _ => text,
    };
    if (value == null) {
      draft.remove(['commands', index, 'restart']);
    } else {
      draft.set(['commands', index, 'restart'], value);
    }
  }

  ServerCommandSetting _command(int index) {
    final all = commands;
    if (index < 0 || index >= all.length) throw InvalidInputException('There is no command ${index + 1}.');
    return all[index];
  }

  static String _commandText(String input) {
    final command = input.trim();
    if (command.isEmpty) throw const InvalidInputException('Give the shell command to run.');
    return command;
  }

  void setQuiet(bool quiet) => _set('quiet', quiet ? true : null);

  void _set(String key, Object? value) {
    if (value == null) {
      draft.remove([key]);
    } else {
      draft.set([key], value);
    }
  }

  static List<String> _items(String input) => [
    for (final part in input.split(RegExp(r'[,\s]+')))
      if (part.isNotEmpty) part,
  ];
}
