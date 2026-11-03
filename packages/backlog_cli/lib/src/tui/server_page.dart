import 'package:backlog_core/backlog_core.dart'
    show ConfigDraft, ConfigEditor, ServerCommand, ServerCommandSetting, ServerSettings;
import 'package:dart_tui/dart_tui.dart' show Cmd;

import 'config_app.dart';
import 'screen.dart';
import 'widgets.dart';

/// *Global › Server*: the settings `kanban-ai-server` reads from `server.yaml`
/// where neither an option nor an environment variable is given.
ConfigFileScreen serverScreen(ConfigEditor editor, ConfigDraft draft) => ConfigFileScreen(
  'Server',
  editor,
  draft,
  sections: (screen) {
    final settings = ServerSettings(screen.draft);
    String shown(String key, String otherwise) => settings.text(key) ?? otherwise;
    final token = settings.text('token');
    return [
      _entry(
        'Addresses',
        shown('host', '0.0.0.0 (every interface; the default)'),
        'Addresses to bind, comma-separated (127.0.0.1 keeps it local; empty: every interface):',
        initial: settings.text('host'),
        apply: (text) => ServerSettings(screen.draft).setHosts(text),
      ),
      _entry(
        'Port',
        shown('port', '8640 (the default)'),
        'Port (empty: 8640):',
        initial: settings.text('port'),
        apply: (text) => ServerSettings(screen.draft).setPort(text),
      ),
      _entry(
        'Allowed clients',
        shown('allow', 'everyone'),
        'Client IPs or CIDR ranges, comma-separated, e.g. 127.0.0.1, 10.77.0.0/16 (empty: everyone):',
        initial: settings.text('allow'),
        apply: (text) => ServerSettings(screen.draft).setAllow(text),
      ),
      MenuEntry(
        'Token',
        detail: token ?? 'none: whoever reaches the server may use it',
        onSelect: (navigator) {
          navigator.push(_tokenScreen(screen));
          return null;
        },
      ),
      _entry(
        'Web app',
        shown('web', 'the one installed with the server'),
        'Folder of the built web app (empty: the one installed with the server):',
        initial: settings.text('web'),
        apply: (text) => ServerSettings(screen.draft).setPath('web', text),
      ),
      _entry(
        'Project registry',
        shown('projects', 'the default registry (projects.yaml)'),
        'Registry file to serve, absolute, ~/… or relative to this file (empty: the default):',
        initial: settings.text('projects'),
        apply: (text) => ServerSettings(screen.draft).setPath('projects', text),
      ),
      MenuEntry(
        'Commands',
        detail: switch (settings.commands) {
          [] => "none (the board's command menu stays hidden)",
          final commands => commands.map((command) => command.name).join(', '),
        },
        onSelect: (navigator) {
          navigator.push(_commandsScreen(screen));
          return null;
        },
      ),
      MenuEntry(
        'Request log',
        detail: settings.quiet ? 'off (Enter: on)' : 'on (Enter: off)',
        onSelect: (navigator) {
          final quiet = !ServerSettings(screen.draft).quiet;
          ServerSettings(screen.draft).setQuiet(quiet);
          navigator.say('Request log ${quiet ? 'off' : 'on'} (not saved yet).');
          return null;
        },
      ),
    ];
  },
  notes: const [
    'Options and environment variables of kanban-ai-server win over these.',
    'A running server reads them only at its start.',
  ],
);

/// An entry whose value is typed in a prompt; [apply] checks and sets it.
MenuEntry _entry(
  String label,
  String detail,
  String question, {
  String? initial,
  required void Function(String text) apply,
}) => MenuEntry(
  label,
  detail: detail,
  onSelect: (navigator) {
    navigator.push(
      PromptScreen(
        label,
        question,
        initial: initial ?? '',
        onSubmit: (text, navigator) {
          apply(text);
          navigator.say('$label ${text.trim().isEmpty ? 'reset to the default' : 'set'} (not saved yet).');
          return null;
        },
      ),
    );
    return null;
  },
);

Screen _tokenScreen(ConfigFileScreen screen) => MenuScreen(
  'Token',
  intro: () => [
    switch (ServerSettings(screen.draft).text('token')) {
      final token? => 'Token: $token',
      null => 'No token: whoever reaches the server may use it.',
    },
    Look.dim('Clients send it as Authorization: Bearer <token> or ?token=; the board URLs include it.'),
  ],
  entries: () => [
    MenuEntry(
      'Generate a new token',
      detail: 'random, 22 characters',
      onSelect: (navigator) =>
          _done(navigator, 'New token ${ServerSettings(screen.draft).generateToken()} (not saved yet).'),
    ),
    MenuEntry(
      'Enter a token…',
      onSelect: (navigator) {
        navigator.push(
          PromptScreen(
            'Enter a token',
            'Token (no spaces):',
            initial: ServerSettings(screen.draft).text('token') ?? '',
            onSubmit: (text, navigator) {
              ServerSettings(screen.draft).setToken(text);
              navigator.say(text.trim().isEmpty ? 'Token removed (not saved yet).' : 'Token set (not saved yet).');
              return null;
            },
          ),
        );
        return null;
      },
    ),
    MenuEntry(
      'Remove the token',
      enabled: ServerSettings(screen.draft).text('token') != null,
      detail: 'whoever reaches the server may use it',
      onSelect: (navigator) {
        ServerSettings(screen.draft).setToken('');
        return _done(navigator, 'Token removed (not saved yet).');
      },
    ),
  ],
);

/// The global commands the board offers in its command menu at the top
/// right, and *Add a command…*.
Screen _commandsScreen(ConfigFileScreen screen) => MenuScreen(
  'Commands',
  intro: () => [
    'Commands the board runs on this machine from its menu at the top right, e.g. Update.',
    Look.dim('One runs at a time; with a restart the server restarts once the command succeeded.'),
  ],
  entries: () => [
    for (final (i, command) in ServerSettings(screen.draft).commands.indexed)
      MenuEntry(
        command.name,
        detail: [command.command, if (command.restart != null) 'then restarts'].join('  '),
        onSelect: (navigator) {
          navigator.push(_commandScreen(screen, i));
          return null;
        },
      ),
    MenuEntry(
      'Add a command…',
      detail: 'a name, then the shell command',
      onSelect: (navigator) {
        navigator.push(
          PromptScreen(
            'Add a command',
            'Name, as the menu shows it (e.g. Update):',
            onSubmit: (name, navigator) {
              navigator.push(
                PromptScreen(
                  'Add ${name.trim()}',
                  'Shell command (runs with sh -c, e.g. mise run -C ~/kanban-ai install):',
                  onSubmit: (command, navigator) =>
                      _done(navigator, _added(ServerSettings(screen.draft), name, command)),
                ),
              );
              return null;
            },
          ),
        );
        return null;
      },
    ),
  ],
);

String _added(ServerSettings settings, String name, String command) {
  settings.addCommand(name, command);
  return 'Added command ${name.trim()} (not saved yet).';
}

/// One global command: what it runs, where and whether the server restarts
/// after it.
Screen _commandScreen(ConfigFileScreen screen, int index) {
  ServerCommandSetting command() => ServerSettings(screen.draft).commands[index];
  return MenuScreen(
    command().name,
    entries: () => [
      _entry(
        'Command',
        command().command,
        'Shell command (runs with sh -c):',
        initial: command().command,
        apply: (text) => ServerSettings(screen.draft).setCommandRun(index, text),
      ),
      _entry(
        'Folder',
        command().dir ?? "the server's working folder",
        'Working folder, absolute, ~/… or relative to this file (empty: the server\'s):',
        initial: command().dir,
        apply: (text) => ServerSettings(screen.draft).setCommandDir(index, text),
      ),
      _entry(
        'Restart',
        switch (command().restart) {
          null => 'no',
          ServerCommand.sameProgram => 'yes, as the program it runs as',
          final program => 'yes, as $program',
        },
        'After a success restart the server: yes (as the program it runs as), a program, or empty (no):',
        initial: switch (command().restart) {
          ServerCommand.sameProgram => 'yes',
          final program => program,
        },
        apply: (text) => ServerSettings(screen.draft).setCommandRestart(index, text),
      ),
      MenuEntry(
        'Remove',
        onSelect: (navigator) {
          final name = command().name;
          ServerSettings(screen.draft).removeCommand(index);
          navigator.pop();
          return _done(navigator, 'Removed command $name (not saved yet).');
        },
      ),
    ],
  );
}

Cmd? _done(Navigator navigator, String message) {
  navigator.say(message);
  return null;
}
