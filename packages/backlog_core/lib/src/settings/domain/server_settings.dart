import 'dart:math';

import '../../shared/errors.dart';
import 'config_draft.dart';
import 'server_config.dart';

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
