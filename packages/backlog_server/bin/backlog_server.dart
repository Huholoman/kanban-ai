import 'dart:io';

import 'package:args/args.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('dir', abbr: 'C', help: 'Backlog folder (default: found from the current folder, or BACKLOG_DIR).')
    ..addMultiOption(
      'host',
      defaultsTo: ['0.0.0.0'],
      help: 'Addresses to bind (repeat or comma-separate); 127.0.0.1 keeps it local.',
    )
    ..addMultiOption(
      'allow',
      valueHelp: 'ip[/prefix]',
      help: 'Answer only these clients (repeat or comma-separate, or BACKLOG_ALLOW); others get 403.',
    )
    ..addOption('port', abbr: 'p', defaultsTo: '8640')
    ..addOption('token', help: 'Require this token from clients (or BACKLOG_TOKEN).')
    ..addFlag('generate-token', negatable: false, help: 'Require a random token, printed at start.')
    ..addOption('web', help: 'Built web app to serve (or BACKLOG_WEB; default: packages/backlog_app/build/web).')
    ..addFlag('quiet', abbr: 'q', help: 'Do not log requests.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n\n${parser.usage}');
    exit(64);
  }
  if (options.flag('help')) {
    stdout.writeln('Usage: backlog_server [options]\n\n${parser.usage}');
    return;
  }
  if (options.flag('generate-token') && options.option('token') != null) {
    stderr.writeln('Use either --token or --generate-token.');
    exit(64);
  }

  final environment = Platform.environment;
  final root = options.option('dir') ?? environment['BACKLOG_DIR'] ?? Backlog.locate(Directory.current.path);
  if (root == null) {
    stderr.writeln('No backlog found from ${Directory.current.path}; pass --dir.');
    exit(4);
  }
  final port = int.tryParse(options.option('port')!);
  if (port == null) {
    stderr.writeln('--port must be a number.');
    exit(64);
  }
  final token = options.flag('generate-token')
      ? generateToken()
      : options.option('token') ?? environment['BACKLOG_TOKEN'];
  final webRoot = options.option('web') ?? environment['BACKLOG_WEB'] ?? _defaultWebRoot();
  final hosts = options.multiOption('host');
  final allowed = options.multiOption('allow').isNotEmpty
      ? options.multiOption('allow')
      : (environment['BACKLOG_ALLOW'] ?? '').split(',').where((range) => range.trim().isNotEmpty).toList();
  final List<AddressRange> allow;
  try {
    allow = [for (final range in allowed) AddressRange.parse(range)];
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(64);
  }

  final BacklogServer server;
  try {
    server = await BacklogServer.start(
      root: root,
      addresses: hosts,
      port: port,
      token: token,
      allow: allow.isEmpty ? null : allow,
      webRoot: webRoot,
      log: options.flag('quiet') ? null : stdout.writeln,
    );
  } on BacklogException catch (error) {
    stderr.writeln(error.message);
    exit(1);
  } on SocketException catch (error) {
    stderr.writeln('Cannot listen: ${error.message} (${error.address?.address ?? hosts.join(', ')}:$port)');
    exit(1);
  }

  stdout
    ..writeln('Backlog: ${server.host.root}')
    ..writeln(
      Directory(webRoot).existsSync() ? 'Web app: $webRoot' : 'Web app not built ($webRoot); serving the API only.',
    );
  if (options.flag('generate-token')) stdout.writeln('Token: $token');
  if (allowed.isNotEmpty) stdout.writeln('Allowed clients: ${allowed.join(', ')}');
  for (final url in await _urls(hosts, server.port)) {
    stdout.writeln('  $url${token == null ? '' : '/?token=$token'}');
  }

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    exit(0);
  });
}

String _defaultWebRoot() {
  final script = p.dirname(Platform.script.toFilePath());
  return p.normalize(p.join(script, '..', '..', 'backlog_app', 'build', 'web'));
}

Future<List<String>> _urls(List<String> hosts, int port) async {
  if (!hosts.contains('0.0.0.0')) return [for (final host in hosts) 'http://$host:$port'];
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return [
    'http://localhost:$port',
    for (final interface in interfaces)
      if (!interface.name.startsWith(RegExp('docker|br-|veth|virbr|mpqemu')))
        for (final address in interface.addresses) 'http://${address.address}:$port  (${interface.name})',
  ];
}
