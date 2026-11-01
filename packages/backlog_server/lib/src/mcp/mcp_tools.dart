import 'dart:convert';

import 'package:backlog_core/backlog_core.dart';

import '../http/dto_mapper.dart';
import '../projects/hosted_project.dart';
import '../projects/project_hub.dart';

/// The MCP tools of the server: the work commands of the CLI (`ready`,
/// `next`, `claim`, `show`, `release`, `done`, `comment`) over the projects of
/// a [ProjectHub], each with an optional `project` (default: the default
/// project), plus `projects` and `instructions`.
///
/// Results are the JSON of the REST API (`ItemDto`, `ItemDetailDto`, …) as
/// text; failures (an unknown item, a claim held by somebody else, …) are
/// tool results with `isError`, so that the model reads them.
final class McpTools {
  McpTools(this._hub, {this.defaultAgent = 'mcp'});

  final ProjectHub _hub;

  /// Who claims items when a call does not name an agent.
  final String defaultAgent;

  /// Told to clients in `initialize`, and returned by the tool `instructions`.
  static const instructions = '''
kanban-ai backlog: work items (tasks, bugs, epics, …) kept as Markdown files, shared by people and coding agents.

- `projects` lists the backlogs of this server; every other tool takes an optional `project` (its id, default: the first project).
- `ready` lists the items that can start now (unblocked, unclaimed, no overlapping work in progress), most urgent first.
- `next` claims the most urgent ready item for `agent` and returns it; `claim` takes a specific one. A claim locks the item and moves it to its active status; it expires after the lease of the backlog.
- `show` returns an item with its body, relations and discussion.
- `comment` adds to the discussion (`question: true` asks a person and waits for an answer).
- `done` finishes an item and drops the claim; `release` gives an unfinished item back.

Name yourself with `agent` (the same name on every call) and never work on an item claimed by somebody else.''';

  late final Map<String, _Tool> _tools = {
    for (final tool in [
      _Tool(
        'projects',
        'List the backlogs (projects) of this server: id, name, folder and why one cannot be opened.',
        const {},
        _projects,
        readOnly: true,
      ),
      _Tool(
        'instructions',
        'How to work with the backlog through these tools.',
        const {},
        (_) async => instructions,
        readOnly: true,
      ),
      _Tool(
        'ready',
        'Items that can start now: pickable, unblocked, unclaimed, no overlapping work in progress, no open children; '
            'most urgent first.',
        {'project': _projectProperty},
        _ready,
        readOnly: true,
      ),
      _Tool(
        'show',
        'An item with its body, parent, children, dependencies, discussion and file.',
        {'project': _projectProperty, 'id': _idProperty},
        _show,
        required: ['id'],
        readOnly: true,
      ),
      _Tool('next', 'Claim the most urgent ready item for `agent` and return it; null when nothing is ready.', {
        'project': _projectProperty,
        'agent': _agentProperty,
      }, _next),
      _Tool(
        'claim',
        'Take an item: lock it for `agent` and move it to in-progress.',
        {
          'project': _projectProperty,
          'id': _idProperty,
          'agent': _agentProperty,
          'force': _flag('Claim even when blocked, waiting for overlapping work or with open children.'),
        },
        _claim,
        required: ['id'],
      ),
      _Tool(
        'release',
        'Give an unfinished item back: drop the claim, back to the pickable status (or `status`).',
        {
          'project': _projectProperty,
          'id': _idProperty,
          'agent': _agentProperty,
          'status': _text('Status to leave the item in.'),
          'force': _flag('Drop a claim held by somebody else.'),
        },
        _release,
        required: ['id'],
      ),
      _Tool(
        'done',
        'Finish an item and drop its claim.',
        {
          'project': _projectProperty,
          'id': _idProperty,
          'agent': _agentProperty,
          'status': _text('A done-category status, e.g. cancelled.'),
          'force': _flag('Even when somebody else holds the claim.'),
        },
        _done,
        required: ['id'],
      ),
      _Tool(
        'comment',
        'Add a comment to the discussion of an item; with `question` it asks a person and the item waits for an '
            'answer.',
        {
          'project': _projectProperty,
          'id': _idProperty,
          'text': _text('The comment (Markdown).'),
          'author': _text('Who writes it (default: the agent name `mcp`).'),
          'question': _flag('A question for a person.'),
        },
        _comment,
        required: ['id', 'text'],
      ),
    ])
      tool.name: tool,
  };

  /// The `tools` of `tools/list`.
  List<Map<String, Object?>> get definitions => [for (final tool in _tools.values) tool.definition];

  bool has(String name) => _tools.containsKey(name);

  /// The result of `tools/call`.
  Future<Map<String, Object?>> call(String name, Map<String, Object?> arguments) async {
    final Object? result;
    try {
      result = await _tools[name]!.run(arguments);
    } on BacklogException catch (error) {
      return _failure(error.message);
    } on _ArgumentError catch (error) {
      return _failure(error.message);
    }
    final text = result is String ? result : const JsonEncoder.withIndent('  ').convert(result);
    return {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'isError': false,
    };
  }

  static Map<String, Object?> _failure(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };

  Future<Object?> _projects(Map<String, Object?> _) async => [
    for (final project in _hub.projects) (await project.describe()).toJson(),
  ];

  Future<Object?> _ready(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final snapshot = await (await project.host.backlog).planning.snapshot();
    return [for (final planned in snapshot.ready) DtoMapper.item(planned, reviewing: _reviewing(project)).toJson()];
  }

  Future<Object?> _show(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    return _detail(project, await project.host.backlog, _required(arguments, 'id'));
  }

  Future<Object?> _next(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final backlog = await project.host.backlog;
    final outcome = await backlog.claims.claimNext(_agent(arguments));
    if (outcome == null) return 'Nothing ready.';
    return _detail(project, backlog, outcome.item.id.value);
  }

  Future<Object?> _claim(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final backlog = await project.host.backlog;
    final outcome = await backlog.claims.claim(
      _required(arguments, 'id'),
      _agent(arguments),
      force: _bool(arguments, 'force'),
    );
    return _detail(project, backlog, outcome.item.id.value);
  }

  Future<Object?> _release(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final backlog = await project.host.backlog;
    final item = await backlog.claims.release(
      _required(arguments, 'id'),
      agent: _agent(arguments),
      status: _optional(arguments, 'status'),
      force: _bool(arguments, 'force'),
    );
    return _detail(project, backlog, item.id.value);
  }

  Future<Object?> _done(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final backlog = await project.host.backlog;
    final item = await backlog.claims.complete(
      _required(arguments, 'id'),
      agent: _agent(arguments),
      status: _optional(arguments, 'status'),
      force: _bool(arguments, 'force'),
    );
    return _detail(project, backlog, item.id.value);
  }

  Future<Object?> _comment(Map<String, Object?> arguments) async {
    final project = _project(arguments);
    final backlog = await project.host.backlog;
    final item = await backlog.items.comment(
      _required(arguments, 'id'),
      author: _optional(arguments, 'author') ?? defaultAgent,
      text: _required(arguments, 'text'),
      question: _bool(arguments, 'question'),
    );
    return _detail(project, backlog, item.id.value);
  }

  Future<Object?> _detail(HostedProject project, Backlog backlog, String reference) async {
    final snapshot = await backlog.planning.snapshot();
    final planned = snapshot[ItemReference.resolve(reference, snapshot.ids)]!;
    final location = await backlog.items.locationOf(planned.id);
    return DtoMapper.detail(
      planned,
      snapshot,
      path: location == null ? null : backlog.storage.displayLocation(location),
      reviewing: _reviewing(project),
    ).toJson();
  }

  static Set<ItemId> _reviewing(HostedProject project) => project.dispatcher?.current?.reviewing ?? const {};

  HostedProject _project(Map<String, Object?> arguments) {
    final id = _optional(arguments, 'project');
    if (id == null) {
      return _hub.defaultProject ?? (throw const NotFoundException('No projects registered.'));
    }
    return _hub[id] ??
        (throw NotFoundException('No project "$id"; known: ${_hub.projects.map((p) => p.id).join(', ')}.'));
  }

  String _agent(Map<String, Object?> arguments) => _optional(arguments, 'agent') ?? defaultAgent;

  static String _required(Map<String, Object?> arguments, String name) =>
      _optional(arguments, name) ?? (throw _ArgumentError('Missing "$name".'));

  static String? _optional(Map<String, Object?> arguments, String name) => switch (arguments[name]) {
    null => null,
    final String text when text.trim().isEmpty => null,
    final String text => text.trim(),
    _ => throw _ArgumentError('"$name" must be a string.'),
  };

  static bool _bool(Map<String, Object?> arguments, String name) => switch (arguments[name]) {
    null => false,
    final bool value => value,
    _ => throw _ArgumentError('"$name" must be true or false.'),
  };

  static const _projectProperty = {
    'type': 'string',
    'description': 'Project id (see the tool `projects`); default: the first project.',
  };
  static const _idProperty = {
    'type': 'string',
    'description': 'Item id, e.g. KA-7f3a (a unique start such as 7f3a is enough).',
  };
  static const _agentProperty = {
    'type': 'string',
    'description': 'Your agent name, the same on every call (default: mcp).',
  };

  static Map<String, Object?> _text(String description) => {'type': 'string', 'description': description};

  static Map<String, Object?> _flag(String description) => {'type': 'boolean', 'description': description};
}

final class _Tool {
  _Tool(this.name, this.description, this.properties, this.run, {this.required = const [], this.readOnly = false});

  final String name;
  final String description;
  final Map<String, Object?> properties;
  final List<String> required;
  final bool readOnly;
  final Future<Object?> Function(Map<String, Object?> arguments) run;

  Map<String, Object?> get definition => {
    'name': name,
    'description': description,
    'inputSchema': {'type': 'object', 'properties': properties, if (required.isNotEmpty) 'required': required},
    'annotations': {'readOnlyHint': readOnly, if (!readOnly) 'destructiveHint': false},
  };
}

final class _ArgumentError implements Exception {
  const _ArgumentError(this.message);

  final String message;
}
