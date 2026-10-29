import 'dart:convert';

import 'package:backlog_api/backlog_api.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

/// Pushes [BacklogChangeEvent]s as JSON text frames to every connected client.
Handler eventSocketHandler(Stream<BacklogChangeEvent> events) => webSocketHandler((channel, _) {
  final subscription = events.listen((event) => channel.sink.add(jsonEncode(event.toJson())));
  channel.stream.listen(null, onDone: subscription.cancel, onError: (Object _) => subscription.cancel());
}, pingInterval: const Duration(seconds: 30));
