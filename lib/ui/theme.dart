import 'package:flutter/material.dart';

const brandSeed = Color(0xFF2F6BFF);

/// The two ends of the app icon's gradient.
const brandBlue = Color(0xFF2F6BFF);
const brandTeal = Color(0xFF22C1C3);

/// Colours with a fixed meaning across both themes.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.connected,
    required this.connecting,
    required this.good,
    required this.fair,
    required this.poor,
  });

  final Color connected;
  final Color connecting;

  /// Latency grades.
  final Color good;
  final Color fair;
  final Color poor;

  static const light = StatusColors(
    connected: Color(0xFF16A35B),
    connecting: Color(0xFFE39A14),
    good: Color(0xFF15803D),
    fair: Color(0xFFB45309),
    poor: Color(0xFFB91C1C),
  );
  static const dark = StatusColors(
    connected: Color(0xFF34D17F),
    connecting: Color(0xFFF5B942),
    good: Color(0xFF4ADE80),
    fair: Color(0xFFFBBF24),
    poor: Color(0xFFF87171),
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
  final scheme = ColorScheme.fromSeed(seedColor: brandSeed, brightness: brightness);
  final dark = brightness == Brightness.dark;
  // Text styles below are derived from the base theme so that they keep the
  // platform's font family instead of falling back to the engine default.
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  final text = base.textTheme;

  return base.copyWith(
    scaffoldBackgroundColor: dark ? scheme.surface : scheme.surfaceContainerLowest,
    extensions: [dark ? StatusColors.dark : StatusColors.light],
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? scheme.surfaceContainer : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.7)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // The base text theme carries family and colour only; sizes are added
      // when the theme is localised, so spell them out here.
      titleTextStyle:
          text.titleLarge?.copyWith(fontSize: 24, fontWeight: FontWeight.w600),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      isDense: true,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w500)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
  );
}
