import 'package:flutter/material.dart';

/// Design tokens of the board (the redesign's neutral palette with one
/// accent), available as `BoardTokens.of(context)`. Light and dark variants;
/// `appearance` in backlog.yaml can replace the accent and the background.
@immutable
class BoardTokens extends ThemeExtension<BoardTokens> {
  const BoardTokens({
    required this.page,
    required this.surface,
    required this.well,
    required this.chip,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.warning,
    required this.success,
    required this.danger,
  });

  static const light = BoardTokens(
    page: Color(0xFFF6F6F4),
    surface: Color(0xFFFFFFFF),
    well: Color(0xFFEEEEEC),
    chip: Color(0xFFF3F4F6),
    border: Color(0xFFE5E7EB),
    borderStrong: Color(0xFFD1D5DB),
    text: Color(0xFF1F2328),
    muted: Color(0xFF6B7280),
    faint: Color(0xFF9CA3AF),
    accent: Color(0xFF3B5BDB),
    accentSoft: Color(0xFFEEF2FF),
    onAccent: Color(0xFFFFFFFF),
    warning: Color(0xFFB45309),
    success: Color(0xFF15803D),
    danger: Color(0xFFB91C1C),
  );

  static const dark = BoardTokens(
    page: Color(0xFF111315),
    surface: Color(0xFF1A1D21),
    well: Color(0xFF15181B),
    chip: Color(0xFF262A30),
    border: Color(0xFF2D3239),
    borderStrong: Color(0xFF3D434B),
    text: Color(0xFFE6E8EB),
    muted: Color(0xFF9AA3AE),
    faint: Color(0xFF6B7380),
    accent: Color(0xFF8DA2FB),
    accentSoft: Color(0xFF222A45),
    onAccent: Color(0xFF0B1020),
    warning: Color(0xFFF59E0B),
    success: Color(0xFF4ADE80),
    danger: Color(0xFFF87171),
  );

  /// Spacing scale and radii shared by all screens.
  static const double gap = 8;
  static const double radius = 8;
  static const double radiusSmall = 6;
  static const double controlHeight = 32;

  /// Page background.
  final Color page;

  /// Panels, cards, header, navigation.
  final Color surface;

  /// The grey well a kanban column sits in.
  final Color well;

  /// Filter chips, label tags.
  final Color chip;
  final Color border;

  /// Inputs and buttons.
  final Color borderStrong;
  final Color text;

  /// Secondary text: ids, counts, meta lines.
  final Color muted;

  /// Disabled or expired things.
  final Color faint;

  /// Selection, primary actions, links.
  final Color accent;

  /// Selected backgrounds (active view, pressed segment).
  final Color accentSoft;
  final Color onAccent;

  /// Blocked, urgent priority, lint warnings.
  final Color warning;

  /// Ready.
  final Color success;
  final Color danger;

  static BoardTokens of(BuildContext context) => Theme.of(context).extension<BoardTokens>() ?? light;

  @override
  BoardTokens copyWith({Color? page, Color? surface, Color? accent, Color? accentSoft, Color? onAccent}) => BoardTokens(
    page: page ?? this.page,
    surface: surface ?? this.surface,
    well: well,
    chip: chip,
    border: border,
    borderStrong: borderStrong,
    text: text,
    muted: muted,
    faint: faint,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccent: onAccent ?? this.onAccent,
    warning: warning,
    success: success,
    danger: danger,
  );

  @override
  BoardTokens lerp(BoardTokens? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return BoardTokens(
      page: mix(page, other.page),
      surface: mix(surface, other.surface),
      well: mix(well, other.well),
      chip: mix(chip, other.chip),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      warning: mix(warning, other.warning),
      success: mix(success, other.success),
      danger: mix(danger, other.danger),
    );
  }

  /// The Material theme built on these tokens: compact, 13 px body text,
  /// flat surfaces with hairline borders.
  ThemeData toTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness).copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondaryContainer: accentSoft,
      onSecondaryContainer: accent,
      surface: surface,
      onSurface: text,
      onSurfaceVariant: muted,
      outline: borderStrong,
      outlineVariant: border,
      surfaceContainerLowest: surface,
      surfaceContainerLow: page,
      surfaceContainer: well,
      surfaceContainerHigh: chip,
      surfaceContainerHighest: chip,
      error: danger,
    );
    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      // Bundled symbols (see pubspec.yaml): the web engine would fetch them.
      fontFamilyFallback: const ['BoardSymbols'],
    );
    final textTheme = base.textTheme
        .apply(bodyColor: text, displayColor: text)
        .copyWith(
          bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13, color: text),
          bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, color: muted),
          labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 11, color: muted),
        );
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(radiusSmall),
      borderSide: BorderSide(color: borderStrong),
    );
    return base.copyWith(
      scaffoldBackgroundColor: page,
      canvasColor: surface,
      dividerColor: border,
      textTheme: textTheme,
      extensions: [this],
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: border)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: surface,
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(borderSide: BorderSide(color: accent, width: 1.5)),
        hintStyle: TextStyle(color: muted),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: borderStrong),
          minimumSize: const Size(0, controlHeight),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          minimumSize: const Size(0, controlHeight),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: chip,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: TextStyle(fontSize: 12, color: text),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      popupMenuTheme: PopupMenuThemeData(color: surface, surfaceTintColor: Colors.transparent),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
    );
  }
}
