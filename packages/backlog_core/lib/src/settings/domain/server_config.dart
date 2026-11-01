import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../shared/errors.dart';

/// The settings of `backlog-server` on this machine (`server.yaml`), used
/// where neither an option nor an environment variable says otherwise.
/// Every field is optional; null means the server's own default.
final class ServerConfig {
  const ServerConfig({this.hosts, this.port, this.allow, this.token, this.web, this.quiet, this.projects});

  static const empty = ServerConfig();

  static const keys = ['host', 'port', 'allow', 'token', 'web', 'quiet', 'projects'];

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
}

/// Parses `server.yaml`: `host` (an address or a list; also
/// comma-separated), `port` (1–65535), `allow` (IPs or CIDR ranges, a list
/// or comma-separated), `token` (no spaces), `web` and `projects` (paths,
/// relative to [baseDir], `~/` under [home]) and `quiet` (a boolean). An
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

  String? path(String key) {
    final value = yaml[key];
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
  return ServerConfig(
    hosts: hosts,
    port: port as int?,
    allow: allow,
    token: token as String?,
    web: path('web'),
    quiet: quiet as bool?,
    projects: path('projects'),
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
