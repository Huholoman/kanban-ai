import 'dart:async';
import 'dart:io';

import 'package:backlog_api/backlog_api.dart';
import 'package:backlog_core/backlog_core.dart';
import 'package:backlog_server/backlog_server.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ChangeFeed.isRelevant', () {
    test('ignores git internals, temp files and editor leftovers', () {
      expect(ChangeFeed.isRelevant('items/T-1-a.md'), isTrue);
      expect(ChangeFeed.isRelevant('.locks/T-1.lock'), isTrue);
      expect(ChangeFeed.isRelevant('backlog.yaml'), isTrue);
      expect(ChangeFeed.isRelevant('.git/index'), isFalse);
      expect(ChangeFeed.isRelevant('items/.T-1-a.md.123_4.tmp'), isFalse);
      expect(ChangeFeed.isRelevant('.locks/T-1.lock.9.stale'), isFalse);
      expect(ChangeFeed.isRelevant('items/T-1-a.md~'), isFalse);
    });
  });

  test('generateToken gives distinct URL-safe tokens', () {
    final tokens = {for (var i = 0; i < 100; i++) generateToken()};
    expect(tokens, hasLength(100));
    expect(tokens, everyElement(matches(RegExp(r'^[A-Za-z0-9_-]{22}$'))));
  });

  group('AddressRange', () {
    test('matches single addresses and CIDR ranges', () {
      final single = AddressRange.parse('10.77.11.22');
      expect(single.contains(InternetAddress('10.77.11.22')), isTrue);
      expect(single.contains(InternetAddress('10.77.11.23')), isFalse);

      final range = AddressRange.parse('10.77.0.0/16');
      expect(range.contains(InternetAddress('10.77.200.1')), isTrue);
      expect(range.contains(InternetAddress('10.78.0.1')), isFalse);
      expect(AddressRange.parse('0.0.0.0/0').contains(InternetAddress('8.8.8.8')), isTrue);
    });

    test('treats IPv4-mapped IPv6 as IPv4 and keeps families apart', () {
      expect(AddressRange.parse('127.0.0.1').contains(InternetAddress('::ffff:127.0.0.1')), isTrue);
      expect(AddressRange.parse('::1').contains(InternetAddress('::1')), isTrue);
      expect(AddressRange.parse('::1').contains(InternetAddress('127.0.0.1')), isFalse);
      expect(AddressRange.parse('fd00::/8').contains(InternetAddress('fd12::5')), isTrue);
    });

    test('rejects anything else', () {
      for (final text in ['localhost', '10.0.0.1/33', '10.0.0.1/x', '10.0.0.1/8/8', '']) {
        expect(() => AddressRange.parse(text), throwsFormatException, reason: text);
      }
    });
  });

  group('binding and client filter', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('backlog_bind_');
      await Backlog.init(dir.path, idPrefix: 'B');
    });

    tearDown(() => dir.delete(recursive: true));

    test('listens on every given address with one port', () async {
      final server = await BacklogServer.start(root: dir.path, addresses: ['127.0.0.1', '127.0.0.2'], port: 0);
      addTearDown(server.close);
      expect(server.uris.map((uri) => uri.host), ['127.0.0.1', '127.0.0.2']);
      for (final uri in server.uris) {
        expect(uri.port, server.port);
        expect((await http.get(uri.replace(path: ApiPaths.health))).statusCode, 200);
      }
    }, testOn: 'linux'); // the whole 127.0.0.0/8 is loopback only on Linux

    test('answers 403 to clients outside the allowed ranges', () async {
      final server = await BacklogServer.start(
        root: dir.path,
        addresses: [InternetAddress.loopbackIPv4],
        port: 0,
        allow: [AddressRange.parse('10.77.11.22')],
      );
      addTearDown(server.close);
      final response = await http.get(server.uri.replace(path: ApiPaths.health));
      expect(response.statusCode, 403);
      expect(response.body, contains('not allowed'));
    });

    test('serves allowed clients', () async {
      final server = await BacklogServer.start(
        root: dir.path,
        addresses: [InternetAddress.loopbackIPv4],
        port: 0,
        allow: [AddressRange.parse('10.77.11.22'), AddressRange.parse('127.0.0.0/8')],
      );
      addTearDown(server.close);
      expect((await http.get(server.uri.replace(path: ApiPaths.health))).statusCode, 200);
    });
  });

  group('running server', () {
    late Directory dir;
    late BacklogServer server;
    late HttpBacklogApi api;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('backlog_live_');
      await Backlog.init(dir.path, idPrefix: 'L');
      final web = await Directory(p.join(dir.path, '_web')).create();
      File(p.join(web.path, 'index.html')).writeAsStringSync('<p>app</p>');
      server = await BacklogServer.start(
        root: dir.path,
        addresses: [InternetAddress.loopbackIPv4],
        port: 0,
        token: 'secret',
        webRoot: web.path,
        debounce: const Duration(milliseconds: 50),
      );
      api = HttpBacklogApi(server.uri, token: 'secret', reconnectDelay: const Duration(milliseconds: 100));
    });

    tearDown(() async {
      api.close();
      await server.close();
      await dir.delete(recursive: true);
    });

    test('serves the web app without a token', () async {
      final response = await http.get(server.uri.replace(path: '/'));
      expect(response.statusCode, 200);
      expect(response.body, contains('app'));
    });

    test('compresses API responses with gzip for clients that accept it', () async {
      for (var i = 0; i < 5; i++) {
        await api.createItem(NewItemRequest(title: 'Item number $i with a longer title'));
      }
      final client = HttpClient()..autoUncompress = false;
      addTearDown(client.close);
      Future<(HttpClientResponse, List<int>)> get(String? accept) async {
        final request = await client.getUrl(server.uri.replace(path: ApiPaths.items));
        request.headers
          ..set('authorization', 'Bearer secret')
          ..removeAll('accept-encoding');
        if (accept != null) request.headers.set('accept-encoding', accept);
        final response = await request.close();
        return (response, await response.expand((chunk) => chunk).toList());
      }

      final (zipped, zippedBody) = await get('gzip, br');
      expect(zipped.headers.value('content-encoding'), 'gzip');
      expect(zipped.headers.value('vary'), 'Accept-Encoding');
      final (plain, plainBody) = await get(null);
      expect(plain.headers.value('content-encoding'), isNull);
      expect(gzip.decode(zippedBody), plainBody);
      expect(zippedBody.length, lessThan(plainBody.length));
    });

    test('the web app is revalidated by ETag, never by a fixed date', () async {
      final uri = server.uri.replace(path: '/index.html');
      final first = await http.get(uri);
      final tag = first.headers['etag'];
      expect(tag, isNotNull);
      expect(first.headers['cache-control'], 'no-cache');
      expect(first.headers.containsKey('last-modified'), isFalse);

      final same = await http.get(uri, headers: {'if-none-match': tag!});
      expect(same.statusCode, 304);
      // A date validator alone no longer short-circuits (Nix store files all
      // carry the same date).
      final dated = await http.get(uri, headers: {'if-modified-since': 'Thu, 01 Jan 2099 00:00:00 GMT'});
      expect(dated.statusCode, 200);

      File(p.join(dir.path, '_web', 'index.html')).writeAsStringSync('<p>new app build</p>');
      final rebuilt = await http.get(uri, headers: {'if-none-match': tag});
      expect(rebuilt.statusCode, 200);
      expect(rebuilt.body, contains('new app build'));
      expect(rebuilt.headers['etag'], isNot(tag));
      expect((await http.get(server.uri.replace(path: '/'))).headers['etag'], rebuilt.headers['etag']);
    });

    test('pushes changes made by anyone — the API or an agent on disk', () async {
      final events = StreamIterator(api.changes());
      addTearDown(events.cancel);
      var pending = events.moveNext();

      // The next event that touches a path matching [test], skipping others.
      Future<List<String>> nextWith(bool Function(String path) test) async {
        while (true) {
          expect(await pending.timeout(const Duration(seconds: 5)), isTrue);
          final paths = events.current.paths;
          pending = events.moveNext();
          if (paths.any(test)) return paths;
        }
      }

      // Wait until the socket delivers instead of guessing how long it takes
      // to connect: touch a doc until its change arrives.
      final probe = File(p.join(dir.path, 'docs', 'probe.md'));
      for (var attempt = 0; ; attempt++) {
        probe.writeAsStringSync('$attempt');
        final arrived = await Future.any([
          pending.then((_) => true),
          Future<bool>.delayed(const Duration(milliseconds: 200), () => false),
        ]);
        if (arrived) break;
        expect(attempt, lessThan(50), reason: 'no change event within 10 s');
      }
      pending = events.moveNext();

      final created = await api.createItem(const NewItemRequest(title: 'Live'));
      expect(await nextWith((path) => path == created.item.path), contains(created.item.path));

      final backlog = await Backlog.open(dir.path);
      await backlog.claims.claim(created.item.id, 'agent-7', force: true);
      expect(await nextWith((path) => path.startsWith('.locks/')), anyElement(startsWith('.locks/')));
      expect((await api.item(created.item.id)).item.claim!.agent, 'agent-7');
    });

    test('picks up an edited workflow', () async {
      final config = File(p.join(dir.path, 'backlog.yaml'));
      config.writeAsStringSync(config.readAsStringSync().replaceFirst('milestones: []', 'milestones: [launch]'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await api.workflow()).milestones.map((m) => m.id), ['launch']);
    });
  });

  test('the dispatcher re-plans on changes and hands work to the launcher', () async {
    final dir = await Directory.systemTemp.createTemp('backlog_dispatch_');
    addTearDown(() => dir.delete(recursive: true));
    await Backlog.init(dir.path, idPrefix: 'D');
    final config = File(p.join(dir.path, 'backlog.yaml'));
    config.writeAsStringSync(
      '${config.readAsStringSync()}\ndispatcher:\n  mode: auto\n  worktrees: [repo-2]\n  command: agent {id}\n',
    );
    final launched = StreamController<DispatchAssignment>();
    final logs = <String>[];
    final server = await BacklogServer.start(
      root: dir.path,
      addresses: [InternetAddress.loopbackIPv4],
      port: 0,
      debounce: const Duration(milliseconds: 50),
      dispatchDebounce: const Duration(milliseconds: 20),
      launcher: (_, _, _) => _StreamLauncher(launched),
      log: logs.add,
    );
    addTearDown(server.close);

    final dispatchEvent = server.projects.defaultProject!.events.firstWhere((event) => event.isDispatch);
    final backlog = await Backlog.open(dir.path);
    final item = await backlog.items.create(const NewItem(title: 'Work', status: 'todo'));
    final assignment = await launched.stream.first.timeout(const Duration(seconds: 10));
    expect((await dispatchEvent.timeout(const Duration(seconds: 10))).toJson(), {'type': 'dispatch', 'paths': []});
    expect(assignment.id, item.id);
    expect(assignment.agent, 'repo-2');
    expect(assignment.command, ['agent', '${item.id}']);
    expect(assignment.path, p.join(p.dirname(server.projects.defaultProject!.host.root), 'repo-2'));
    expect(logs, contains('Dispatcher (auto): 0/1 running; starts ${item.id} → repo-2.'));
  });
}

final class _StreamLauncher extends AgentLauncher {
  _StreamLauncher(this._sink);

  final StreamController<DispatchAssignment> _sink;

  @override
  Future<void> launch(DispatchAssignment assignment) async => _sink.add(assignment);
}
