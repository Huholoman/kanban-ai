import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../shared/errors.dart';

/// The settings of `kanban-ai-server` on this machine (`server.yaml`), used
/// where neither an option nor an environment variable says otherwise.
/// Every field is optional; null means the server's own default.
final class ServerConfig {
  const ServerConfig({
    this.hosts,
    this.port,
    this.allow,
    this.token,
    this.web,
    this.quiet,
    this.projects,
    this.commands = const [],
  });

  static const empty = ServerConfig();

  static const keys = ['host', 'port', 'allow', 'token', 'web', 'quiet', 'projects', 'commands'];

  /// Addresses to bind (`host`).
  final List<String>? hosts;
  final int? port;

  /// Client IPs or CIDR ranges allowed (`allow`).
  final List<String>? allow;

  /// The token clients must send.
  final String? token;

  /// The built web app to serve, absolute.
  final String? web;

  /// No request log.
  final bool? quiet;

  /// The project registry to serve, absolute.
  final String? projects;

  /// The global commands the board offers (`commands`), in order.
  final List<ServerCommand> commands;
}

/// A global command of the server (`commands` in `server.yaml`), offered by
/// the board's command menu, e.g. "Update": [command] runs in [dir]; when
/// it succeeds and [restart] is given, the server restarts as that program.
final class ServerCommand {
  const ServerCommand({required this.name, required this.command, this.dir, this.restart});

  static const keys = ['name', 'command', 'dir', 'restart'];

  /// Shown in the menu; unique.
  final String name;

  /// The program and its arguments; a single text runs with `sh -c`.
  final List<String> command;

  /// The working folder, absolute; null: the server's own.
  final String? dir;

  /// The program the server restarts as once [command] succeeded
  /// (`restart: true` is the program it runs as, [sameProgram]); null: no
  /// restart.
  final String? restart;

  /// The value of [restart] for `restart: true`.
  static const sameProgram = '';
}

/// Parses `server.yaml`: `host` (an address or a list; also
/// comma-separated), `port` (1–65535), `allow` (IPs or CIDR ranges, a list
/// or comma-separated), `token` (no spaces), `web` and `projects` (paths,
/// relative to [baseDir], `~/` under [home]), `quiet` (a boolean) and
/// `commands` (see [ServerCommand]; `dir` is a path like `web`). An
/// empty file is [ServerConfig.empty]; anything else (unknown keys too) is
/// a [ConfigurationException].
ServerConfig parseServerConfigYaml(
  String source, {
  required String baseDir,
  String? home,
  String origin = 'server.yaml',
}) {
  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException('$origin: ${e.message}');
  }
  if (document == null) return ServerConfig.empty;
  if (document is! YamlMap) throw ConfigurationException('$origin: expected a mapping at the top level.');
  final yaml = document;
  Never fail(String message) => throw ConfigurationException('$origin: $message');
  for (final key in yaml.keys) {
    if (!ServerConfig.keys.contains('$key')) {
      fail('unknown key "$key" (expected ${ServerConfig.keys.join(', ')}).');
    }
  }

  List<String>? list(String key) {
    final value = yaml[key];
    if (value == null) return null;
    final parts = switch (value) {
      final String text => text.split(','),
      final YamlList list when list.every((v) => v is String || v is num) => [for (final v in list) '$v'],
      _ => fail('$key must be a text or a list of texts.'),
    };
    return [
      for (final part in parts)
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  String? path(String key, [Map<dynamic, dynamic>? map]) {
    final value = (map ?? yaml)[key];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) fail('$key must be a path.');
    final text = value.trim();
    if (text == '~' || text.startsWith('~/')) {
      if (home == null) fail('$key: ~ needs HOME.');
      return p.normalize(p.join(home, text.length == 1 ? '.' : text.substring(2)));
    }
    return p.normalize(p.join(baseDir, text));
  }

  final hosts = list('host');
  if (hosts != null && hosts.isEmpty) fail('host must name at least one address.');
  for (final host in hosts ?? const <String>[]) {
    if (host.contains(RegExp(r'[\s/]'))) fail('host "$host" is not an address.');
  }
  final port = yaml['port'];
  if (port != null && (port is! int || port < 1 || port > 65535)) fail('port must be a number from 1 to 65535.');
  final allow = list('allow');
  for (final range in allow ?? const <String>[]) {
    if (!isAddressRange(range)) fail('allow: not an IP address or CIDR range: $range');
  }
  final token = yaml['token'];
  if (token != null && (token is! String || token.isEmpty || token.contains(RegExp(r'\s')))) {
    fail('token must be a text without spaces.');
  }
  final quiet = yaml['quiet'];
  if (quiet != null && quiet is! bool) fail('quiet must be true or false.');
  final commands = <ServerCommand>[];
  switch (yaml['commands']) {
    case null:
      break;
    case final YamlList list:
      for (final (i, entry) in list.indexed) {
        final at = 'commands[${i + 1}]';
        if (entry is! YamlMap) fail('$at must be a mapping with name and command.');
        for (final key in entry.keys) {
          if (!ServerCommand.keys.contains('$key')) {
            fail('$at: unknown key "$key" (expected ${ServerCommand.keys.join(', ')}).');
          }
        }
        final name = entry['name'];
        if (name is! String || name.trim().isEmpty) fail('$at: name must be a text.');
        if (commands.any((command) => command.name == name.trim())) fail('$at: there are two commands "$name".');
        final command = switch (entry['command']) {
          final String text when text.trim().isNotEmpty => ['sh', '-c', text],
          final YamlList parts when parts.isNotEmpty && parts.every((v) => v is String || v is num) => [
            for (final part in parts) '$part',
          ],
          _ => fail('$at: command must be a text (run with sh -c) or a list of the program and its arguments.'),
        };
        final restart = switch (entry['restart']) {
          null || false => null,
          true => ServerCommand.sameProgram,
          final String program when program.trim().isNotEmpty => program.trim(),
          _ => fail('$at: restart must be true or the program to restart as.'),
        };
        commands.add(ServerCommand(name: name.trim(), command: command, dir: path('dir', entry), restart: restart));
      }
    default:
      fail('commands must be a list.');
  }
  return ServerConfig(
    hosts: hosts,
    port: port as int?,
    allow: allow,
    token: token as String?,
    web: path('web'),
    quiet: quiet as bool?,
    projects: path('projects'),
    commands: commands,
  );
}

/// Whether [text] is an IP address with an optional `/prefix`
/// (`10.77.0.0/16`, `::1`).
bool isAddressRange(String text) {
  final [address, ...prefix] = text.trim().split('/');
  if (prefix.length > 1) return false;
  int bits;
  try {
    bits = address.contains(':') ? (Uri.parseIPv6Address(address), 128).$2 : (Uri.parseIPv4Address(address), 32).$2;
  } on FormatException {
    return false;
  }
  if (prefix.isEmpty) return true;
  final length = int.tryParse(prefix.single);
  return length != null && length >= 0 && length <= bits;
}

/// A random URL-safe token for the server: 22 characters, ~130 bits.
String generateServerToken({Random? random}) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final source = random ?? Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 22; i++) alphabet.codeUnitAt(source.nextInt(alphabet.length))]);
}
