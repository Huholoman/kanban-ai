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
        builder: (context, child) => _LargeScreenText(child: child!),
        home: const BoardPage(),
      ),
    ),
  );
}

/// Scales text up on very wide screens (27" 4K and similar), where 13 px
/// would read small from the usual distance; the user's own scaling applies
/// on top.
class _LargeScreenText extends StatelessWidget {
  const _LargeScreenText({required this.child});

  /// From this logical width text is [factor] times larger.
  static const wideWidth = 2000.0;
  static const factor = 1.15;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width < wideWidth) return child;
    return MediaQuery(
      data: media.copyWith(textScaler: _Scaled(media.textScaler)),
      child: child,
    );
  }
}

class _Scaled extends TextScaler {
  const _Scaled(this.inner);

  final TextScaler inner;

  @override
  double scale(double fontSize) => inner.scale(fontSize) * _LargeScreenText.factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => inner.textScaleFactor * _LargeScreenText.factor;
}
