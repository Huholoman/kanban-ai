import 'dart:io';

import 'package:args/args.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      valueHelp: 'file',
      help:
          'Server settings (or BACKLOG_SERVER_CONFIG; default: \$XDG_CONFIG_HOME/kanban-ai/server.yaml when it '
          'exists); options and the environment win over them.',
    )
    ..addOption(
      'dir',
      abbr: 'C',
      help: 'Serve only this backlog folder (or BACKLOG_DIR), ignoring the project registry.',
    )
    ..addOption(
      'projects',
      valueHelp: 'file',
      help:
          'Project registry to serve (or BACKLOG_PROJECTS; default: \$XDG_CONFIG_HOME/kanban-ai/projects.yaml '
          'when it exists, else the backlog found from the current folder).',
    )
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
  final configOption = options.option('config') ?? environment['BACKLOG_SERVER_CONFIG'];
  final configFile = configOption == null || configOption.trim().isEmpty
      ? serverConfigFile(environment)
      : p.normalize(p.absolute(configOption));
  var settings = ServerConfig.empty;
  if (configFile != null) {
    if (configOption != null && !File(configFile).existsSync()) {
      stderr.writeln('No server settings at $configFile; create them with `backlog config` (Global › Server).');
      exit(4);
    }
    try {
      settings = await loadServerConfig(configFile, home: environment['HOME']);
    } on BacklogException catch (error) {
      stderr.writeln(error.message);
      exit(1);
    }
  }
  final dirOption = options.option('dir');
  final projectsOption = options.option('projects');
  if (dirOption != null && projectsOption != null) {
    stderr.writeln('Both --dir and --projects given; serving only $dirOption.');
  }
  // --dir beats --projects, options beat the environment, and the registry
  // beats the backlog found from the current folder.
  final explicitDir = dirOption ?? (projectsOption == null ? environment['BACKLOG_DIR'] : null);
  final explicitRegistry = explicitDir != null
      ? null
      : projectsOption ?? environment['BACKLOG_PROJECTS'] ?? settings.projects;
  String? root;
  String? projectsFile;
  if (explicitDir != null) {
    root = explicitDir;
  } else if (explicitRegistry != null) {
    projectsFile = p.absolute(explicitRegistry);
    if (!File(projectsFile).existsSync()) {
      stderr.writeln('No project registry at $projectsFile; create it with `backlog projects add --projects <file>`.');
      exit(4);
    }
  } else if (projectRegistryFile(environment) case final file? when File(file).existsSync()) {
    projectsFile = file;
  } else {
    root = Backlog.locate(Directory.current.path);
    if (root == null) {
      stderr.writeln(
        'No backlog found from ${Directory.current.path} and no project registry; '
        'pass --dir or register backlogs with `backlog projects add`.',
      );
      exit(4);
    }
  }
  final port = options.wasParsed('port') ? int.tryParse(options.option('port')!) : settings.port ?? 8640;
  if (port == null) {
    stderr.writeln('--port must be a number.');
    exit(64);
  }
  final token = options.flag('generate-token')
      ? generateToken()
      : options.option('token') ?? environment['BACKLOG_TOKEN'] ?? settings.token;
  final webRoot = options.option('web') ?? environment['BACKLOG_WEB'] ?? settings.web ?? _defaultWebRoot();
  final hosts = options.wasParsed('host') ? options.multiOption('host') : settings.hosts ?? const ['0.0.0.0'];
  final allowedByEnvironment = (environment['BACKLOG_ALLOW'] ?? '').split(',').where((r) => r.trim().isNotEmpty);
  final allowed = options.multiOption('allow').isNotEmpty
      ? options.multiOption('allow')
      : allowedByEnvironment.isNotEmpty
      ? allowedByEnvironment.toList()
      : settings.allow ?? const <String>[];
  final quiet = options.wasParsed('quiet') ? options.flag('quiet') : settings.quiet ?? false;
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
      projectsFile: projectsFile,
      home: environment['HOME'],
      addresses: hosts,
      port: port,
      token: token,
      allow: allow.isEmpty ? null : allow,
      webRoot: webRoot,
      log: quiet ? null : stdout.writeln,
      stateDir: ProcessAgentLauncher.defaultStateDir(environment),
      launcher: (project, host, log) => WorktreeProvisioner(
        ProcessAgentLauncher(
          project: project,
          backlog: () => host.backlog,
          stateDir: ProcessAgentLauncher.defaultStateDir(environment),
          log: log,
        ),
        project: project,
        stateDir: ProcessAgentLauncher.defaultStateDir(environment),
        log: log,
      ),
    );
  } on BacklogException catch (error) {
    stderr.writeln(error.message);
    exit(1);
  } on SocketException catch (error) {
    stderr.writeln('Cannot listen: ${error.message} (${error.address?.address ?? hosts.join(', ')}:$port)');
    exit(1);
  }

  if (configFile != null && File(configFile).existsSync()) stdout.writeln('Settings from $configFile');
  if (projectsFile != null) {
    stdout.writeln('Projects from $projectsFile (watched; the first one is the default):');
  }
  final projects = server.projects.projects;
  if (projects.isEmpty) stdout.writeln('  (none yet; add some with `backlog projects add`)');
  for (final project in projects) {
    final dto = await project.describe();
    stdout.writeln(
      '  ${project.id}  ${dto.path}${project == projects.first ? '  (default)' : ''}'
      '${dto.error == null ? '' : '\n    error: ${dto.error}'}',
    );
  }
  stdout.writeln(
    Directory(webRoot).existsSync() ? 'Web app: $webRoot' : 'Web app not built ($webRoot); serving the API only.',
  );
  if (options.flag('generate-token')) stdout.writeln('Token: $token');
  if (allowed.isNotEmpty) stdout.writeln('Allowed clients: ${allowed.join(', ')}');
  stdout.writeln('Board:');
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
