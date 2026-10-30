import 'dart:async';

import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../features/board/presentation/board_page.dart';
import 'app_scope.dart';
import 'appearance_controller.dart';

class BacklogApp extends StatefulWidget {
  const BacklogApp({super.key, required this.api, this.config = const AppConfig()});

  final BacklogApi api;
  final AppConfig config;

  @override
  State<BacklogApp> createState() => _BacklogAppState();
}

class _BacklogAppState extends State<BacklogApp> {
  late final _appearance = AppearanceController(widget.api);

  @override
  void initState() {
    super.initState();
    unawaited(_appearance.start());
  }

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    api: widget.api,
    config: widget.config,
    appearance: _appearance,
    child: ListenableBuilder(
      listenable: _appearance,
      builder: (context, _) => MaterialApp(
        title: 'Backlog',
        debugShowCheckedModeBanner: false,
        theme: _appearance.theme(Brightness.light),
        darkTheme: _appearance.theme(Brightness.dark),
        themeMode: _appearance.mode,
        // Theme loads after the first frame; switch at once instead of fading.
        themeAnimationDuration: Duration.zero,
        home: const BoardPage(),
      ),
    ),
  );
}
