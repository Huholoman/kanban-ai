import 'dart:io';
import 'dart:math';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ServerConfig _parse(String source) => parseServerConfigYaml(source, baseDir: '/etc/kanban', home: '/home/me');

void main() {
  test('reads every key; lists may be comma-separated, paths relative or under ~', () {
    final config = _parse('''
host: [127.0.0.1, 10.77.1.2]
port: 8642
allow: 10.77.0.0/16, ::1
token: abc-DEF_123
web: ../web
quiet: true
projects: ~/projects.yaml
''');
    expect(config.hosts, ['127.0.0.1', '10.77.1.2']);
    expect(config.port, 8642);
    expect(config.allow, ['10.77.0.0/16', '::1']);
    expect(config.token, 'abc-DEF_123');
    expect(config.web, '/etc/web');
    expect(config.quiet, isTrue);
    expect(config.projects, '/home/me/projects.yaml');
    expect(_parse('host: localhost').hosts, ['localhost']);
    expect(_parse('').port, isNull);
  });

  test('refuses what the server could not use', () {
    for (final (source, message) in [
      ('port: 0', 'port must be a number from 1 to 65535'),
      ('port: "8642"', 'port must be'),
      ('allow: [10.0.0.0/33]', 'not an IP address or CIDR range: 10.0.0.0/33'),
      ('allow: [example.com]', 'not an IP address'),
      ('token: "a b"', 'token must be a text without spaces'),
      ('quiet: yes please', 'quiet must be true or false'),
      ('host: []', 'host must name at least one address'),
      ('hosts: [a]', 'unknown key "hosts"'),
      ('- a', 'expected a mapping'),
    ]) {
      expect(
        () => _parse(source),
        throwsA(isA<ConfigurationException>().having((e) => e.message, 'message', contains(message))),
        reason: source,
      );
    }
  });

  test('address ranges', () {
    expect(['10.0.0.1', '10.0.0.0/8', '::1', 'fd00::/8', '0.0.0.0/0'].every(isAddressRange), isTrue);
    expect(['10.0.0', '10.0.0.1/40', 'fd00::/129', 'a/b/c', ''].any(isAddressRange), isFalse);
  });

  test('tokens are 22 URL-safe characters', () {
    final token = generateServerToken(random: Random(1));
    expect(token, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
    expect(generateServerToken(), isNot(generateServerToken()));
  });

  test('the file lives next to the registry; a missing one is empty', () async {
    expect(serverConfigFile({'HOME': '/home/me'}), '/home/me/.config/kanban-ai/server.yaml');
    expect(serverConfigFile({'XDG_CONFIG_HOME': '/cfg', 'HOME': '/home/me'}), '/cfg/kanban-ai/server.yaml');
    expect(serverConfigFile({'BACKLOG_SERVER_CONFIG': '/x/s.yaml'}), '/x/s.yaml');
    expect(serverConfigFile({}), isNull);

    final dir = await Directory.systemTemp.createTemp('server_config_');
    addTearDown(() => dir.delete(recursive: true));
    final file = p.join(dir.path, 'server.yaml');
    expect((await loadServerConfig(file)).port, isNull);

    final editor = serverConfigEditor(file);
    final draft = (await editor.open())..set(['port'], 70000);
    expect(editor.problem(draft), contains('port must be'));
    draft.set(['port'], 8642);
    await editor.save(draft);
    expect((await loadServerConfig(file)).port, 8642);
  });

  test('ServerSettings checks input; empty removes the key', () {
    final settings = ServerSettings(ConfigDraft('# server\nport: 8640 # default\n'));
    settings
      ..setHosts('127.0.0.1, 10.77.1.2')
      ..setPort('8642')
      ..setAllow('10.77.0.0/16 ::1')
      ..setQuiet(true);
    expect(settings.text('host'), '127.0.0.1, 10.77.1.2');
    expect(settings.draft.text, contains('port: 8642 # default'));
    final token = settings.generateToken();
    expect(settings.text('token'), token);
    final config = _parse(settings.draft.text);
    expect(config.hosts, ['127.0.0.1', '10.77.1.2']);
    expect(config.allow, ['10.77.0.0/16', '::1']);
    expect((config.port, config.quiet), (8642, true));

    settings
      ..setPort(' ')
      ..setToken('')
      ..setQuiet(false)
      ..setPath('web', '/srv/web');
    expect(settings.text('port'), isNull);
    expect(settings.text('token'), isNull);
    expect(settings.quiet, isFalse);
    expect(_parse(settings.draft.text).web, '/srv/web');
    expect(() => settings.setPort('80000'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setAllow('10.0.0.0/99'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setHosts('a/b'), throwsA(isA<InvalidInputException>()));
    expect(() => settings.setToken('a b'), throwsA(isA<InvalidInputException>()));
  });
}
