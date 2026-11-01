import 'dart:convert';
import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late Backlog backlog;
  late Handler handler;
  final clock = FixedClock(DateTime.utc(2026, 11, 1, 12));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('backlog_mcp_');
    await Backlog.init(dir.path, idPrefix: 'M');
    backlog = await Backlog.open(dir.path, clock: clock);
    handler = BacklogServer.buildHandler(
      projects: ProjectHub.single(BacklogHost.folder(dir.path, clock: clock)),
      token: 'secret',
    );
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Response> post(Object? message, {Map<String, String> headers = const {}}) async => handler(
    Request(
      'POST',
      Uri.parse('http://backlog.test/mcp'),
      headers: {'authorization': 'Bearer secret', 'content-type': 'application/json', ...headers},
      body: jsonEncode(message),
    ),
  );

  Future<Map<String, Object?>> rpc(String method, [Map<String, Object?> params = const {}]) async {
    final response = await post({'jsonrpc': '2.0', 'id': 7, 'method': method, 'params': params});
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('application/json'));
    final body = jsonDecode(await response.readAsString()) as Map<String, Object?>;
    expect(body['id'], 7);
    return body;
  }

  Future<Map<String, Object?>> call(String tool, [Map<String, Object?> arguments = const {}]) async =>
      (await rpc('tools/call', {'name': tool, 'arguments': arguments}))['result'] as Map<String, Object?>;

  String text(Map<String, Object?> result) => ((result['content'] as List).single as Map)['text'] as String;

  Map<String, Object?> json(Map<String, Object?> result) {
    expect(result['isError'], isFalse, reason: text(result));
    return jsonDecode(text(result)) as Map<String, Object?>;
  }

  test('initialize negotiates the protocol and gives the instructions', () async {
    final result = (await rpc('initialize', {'protocolVersion': '2025-03-26', 'capabilities': {}}))['result'] as Map;
    expect(result['protocolVersion'], '2025-03-26');
    expect(result['capabilities'], containsPair('tools', isA<Map<String, Object?>>()));
    expect((result['serverInfo'] as Map)['name'], 'kanban-ai');
    expect(result['instructions'], contains('`next`'));

    final unknown = (await rpc('initialize', {'protocolVersion': '1999-01-01'}))['result'] as Map;
    expect(unknown['protocolVersion'], McpHandler.protocolVersions.first);
  });

  test('lists the tools with their input schemas', () async {
    final tools = ((await rpc('tools/list'))['result'] as Map)['tools'] as List;
    final names = [for (final tool in tools.cast<Map<String, Object?>>()) tool['name']];
    expect(names, containsAll(['projects', 'instructions', 'ready', 'next', 'claim', 'show', 'done', 'comment']));
    final claim = tools.cast<Map<String, Object?>>().firstWhere((tool) => tool['name'] == 'claim');
    expect(claim['inputSchema'], containsPair('required', ['id']));
  });

  test('ready, next, show, comment and done work on the backlog', () async {
    final item = await backlog.items.create(const NewItem(title: 'Wire MCP', status: 'todo'));
    final id = item.id.value;

    final ready = jsonDecode(text(await call('ready'))) as List;
    expect([for (final entry in ready.cast<Map<String, Object?>>()) entry['id']], [id]);

    final claimed = json(await call('next', {'agent': 'desktop'}));
    expect((claimed['item'] as Map)['claim'], containsPair('agent', 'desktop'));
    expect(text(await call('next', {'agent': 'desktop'})), 'Nothing ready.');

    final conflict = await call('done', {'id': id, 'agent': 'someone-else'});
    expect(conflict['isError'], isTrue);
    expect(text(conflict), contains('claimed by desktop'));

    await call('comment', {'id': id, 'text': 'Looks good.', 'author': 'desktop'});
    final shown = json(await call('show', {'id': id.substring(2)}));
    expect((shown['discussion'] as List).single, containsPair('text', 'Looks good.'));

    final done = json(await call('done', {'id': id, 'agent': 'desktop'}));
    expect((done['item'] as Map)['status'], 'done');
  });

  test('projects lists the hosted backlog; an unknown project or item is a tool error', () async {
    final projects = jsonDecode(text(await call('projects'))) as List;
    expect(projects, hasLength(1));

    final project = await call('ready', {'project': 'nope'});
    expect(project['isError'], isTrue);
    expect(text(project), contains('No project "nope"'));

    final item = await call('show', {'id': 'M-0000'});
    expect(item['isError'], isTrue);
    final missing = await call('show');
    expect(text(missing), 'Missing "id".');
  });

  test('protocol errors, notifications and other methods', () async {
    final unknownMethod = await rpc('resources/list');
    expect((unknownMethod['error'] as Map)['code'], -32601);
    final unknownTool = await rpc('tools/call', {'name': 'rm'});
    expect((unknownTool['error'] as Map)['code'], -32602);

    final notification = await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    expect(notification.statusCode, 202);

    final get = await handler(
      Request('GET', Uri.parse('http://backlog.test/mcp'), headers: {'authorization': 'Bearer secret'}),
    );
    expect(get.statusCode, 405);

    final garbage = await handler(
      Request('POST', Uri.parse('http://backlog.test/mcp'), headers: {'authorization': 'Bearer secret'}, body: '{'),
    );
    expect(garbage.statusCode, 400);
  });

  test('needs the token and refuses pages of other origins', () async {
    final anonymous = await handler(
      Request('POST', Uri.parse('http://backlog.test/mcp'), body: jsonEncode({'jsonrpc': '2.0', 'id': 1})),
    );
    expect(anonymous.statusCode, 401);

    final query = await handler(
      Request(
        'POST',
        Uri.parse('http://backlog.test/mcp?token=secret'),
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
      ),
    );
    expect(query.statusCode, 200);

    final foreign = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}, headers: {'origin': 'http://evil.test'});
    expect(foreign.statusCode, 403);
    final own = await post(
      {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
      headers: {'origin': 'http://backlog.test', 'host': 'backlog.test'},
    );
    expect(own.statusCode, 200);
  });
}
