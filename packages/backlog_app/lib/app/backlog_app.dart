import 'package:backlog_api/backlog_api.dart';
import 'package:flutter/material.dart';

import '../features/board/presentation/board_page.dart';
import 'app_scope.dart';

class BacklogApp extends StatelessWidget {
  const BacklogApp({super.key, required this.api, this.config = const AppConfig()});

  final BacklogApi api;
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3A6EA5), brightness: brightness),
      visualDensity: VisualDensity.standard,
    );
    return AppScope(
      api: api,
      config: config,
      child: MaterialApp(
        title: 'Backlog',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const BoardPage(),
      ),
    );
  }
}
