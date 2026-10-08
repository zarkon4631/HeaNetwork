import 'package:flutter/material.dart';

/// The two ends of the brand gradient (also used by the app icon).
const brandBlue = Color(0xFF3B82F6);
const brandCyan = Color(0xFF22D3EE);
const brandViolet = Color(0xFF8B5CF6);

/// Colours with a fixed meaning across both themes.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.connected,
    required this.connecting,
    required this.good,
    required this.fair,
    required this.poor,
    required this.glass,
    required this.glassBorder,
    required this.backdrop,
  });

  final Color connected;
  final Color connecting;

  /// Latency grades.
  final Color good;
  final Color fair;
  final Color poor;

  /// Translucent panel fill and its hairline border, drawn over the
  /// animated backdrop.
  final Color glass;
  final Color glassBorder;

  /// The window colour behind everything.
  final Color backdrop;

  static const light = StatusColors(
    connected: Color(0xFF12A150),
    connecting: Color(0xFFD98A0B),
    good: Color(0xFF15803D),
    fair: Color(0xFFB45309),
    poor: Color(0xFFB91C1C),
    glass: Color(0xD9FFFFFF),
    glassBorder: Color(0x1A1E293B),
    backdrop: Color(0xFFEEF2FA),
  );
  static const dark = StatusColors(
    connected: Color(0xFF2EE58F),
    connecting: Color(0xFFFBBF24),
    good: Color(0xFF4ADE80),
    fair: Color(0xFFFBBF24),
    poor: Color(0xFFF87171),
    glass: Color(0xB80E1119),
    glassBorder: Color(0x14FFFFFF),
    backdrop: Color(0xFF05060A),
  );

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>()!;

  @override
  StatusColors copyWith() => this;

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) =>
      t < 0.5 || other is! StatusColors ? this : other;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final status = dark ? StatusColors.dark : StatusColors.light;
  final seeded = ColorScheme.fromSeed(seedColor: brandBlue, brightness: brightness);
  final scheme = dark
      ? seeded.copyWith(
          primary: const Color(0xFF6EA8FF),
          onPrimary: const Color(0xFF04122B),
          primaryContainer: const Color(0xFF16305C),
          onPrimaryContainer: const Color(0xFFD6E4FF),
          secondaryContainer: const Color(0xFF1B2333),
          onSecondaryContainer: const Color(0xFFD5DCEB),
          tertiary: brandCyan,
          surface: const Color(0xFF090B11),
          surfaceContainerLowest: const Color(0xFF05060A),
          surfaceContainerLow: const Color(0xFF0C0F16),
          surfaceContainer: const Color(0xFF10131C),
          surfaceContainerHigh: const Color(0xFF151925),
          surfaceContainerHighest: const Color(0xFF1B2030),
          onSurface: const Color(0xFFE8ECF5),
          onSurfaceVariant: const Color(0xFF98A2B8),
          outline: const Color(0xFF5B6478),
          outlineVariant: const Color(0xFF232838),
        )
      : seeded.copyWith(
          primary: const Color(0xFF2563EB),
          tertiary: const Color(0xFF0891B2),
          surface: const Color(0xFFF7F9FD),
        );

  // Text styles below are derived from the base theme so that they keep the
  // platform's font family instead of falling back to the engine default.
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
  );
  final text = base.textTheme;

  return base.copyWith(
    // Pages opened on top of the shell are opaque; the shell itself is
    // transparent and paints the animated backdrop.
    scaffoldBackgroundColor: status.backdrop,
    canvasColor: scheme.surfaceContainer,
    extensions: [status],
    // A clearly visible ring for remote-control and keyboard navigation.
    focusColor: scheme.primary.withValues(alpha: dark ? 0.28 : 0.18),
    hoverColor: scheme.onSurface.withValues(alpha: 0.05),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: status.glass,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: status.glassBorder),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      toolbarHeight: 52,
      // The base text theme carries family and colour only; sizes are added
      // when the theme is localised, so spell them out here.
      titleTextStyle:
          text.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xE6080A10) : const Color(0xF2FFFFFF),
      height: 62,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 14),
      dense: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF1B2030) : null,
      contentTextStyle: dark ? TextStyle(color: scheme.onSurface) : null,
    ),
    dividerTheme: DividerThemeData(
      color: status.glassBorder,
      space: 1,
      thickness: 1,
    ),
  );
}
