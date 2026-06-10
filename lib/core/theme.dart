import 'package:flutter/material.dart';

/// Central color + theme definitions for SeeOnce. Keeping these in one place
/// (rather than scattered `Color(0x..)` / `Colors.grey` literals across
/// widgets) keeps contrast consistent and WCAG-compliant on the dark surface.
class AppColors {
  AppColors._();

  // Surfaces, darkest → lightest.
  static const background = Color(0xFF0A0A0F);
  static const surface = Color(0xFF12121A);
  static const surfaceContainer = Color(0xFF1B1B26);
  static const surfaceContainerHigh = Color(0xFF232330);

  // Brand accent.
  static const primary = Color(0xFF8C74FF); // brightened for better contrast
  static const primaryMuted = Color(0xFF9B89FF);

  // Text. `textPrimary` ~15:1 and `textMuted` ~6.3:1 against [background],
  // both clearing WCAG AA for their text sizes.
  static const textPrimary = Color(0xFFF1F1F7);
  static const textMuted = Color(0xFFA6A6B8);

  static const outline = Color(0xFF2C2C3A);

  // Status.
  static const online = Color(0xFF34D399); // accessible green (vs Colors.green)
  static const reconnecting = Color(0xFFF59E0B); // amber, ~8:1 on background
  static const offline = Color(0xFF6B6B7B);
  static const error = Color(0xFFEF4444);
}

/// Builds the app's dark theme. Text uses the locally-bundled Inter family
/// (no runtime network fetch) with NotoColorEmoji as a glyph fallback so emoji
/// render everywhere; because Inter covers Latin + digits, the fallback is only
/// consulted for emoji and never corrupts ordinary text.
ThemeData buildAppTheme() {
  const fontFallback = ['NotoColorEmoji'];

  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.surface,
      surfaceContainerHighest: AppColors.surfaceContainerHigh,
      surfaceContainerHigh: AppColors.surfaceContainer,
      primary: AppColors.primary,
      onPrimary: Color(0xFF15032E),
      secondary: AppColors.primaryMuted,
      onSecondary: Color(0xFF15032E),
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textMuted,
      outline: AppColors.outline,
      error: AppColors.error,
      onError: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: AppColors.textPrimary),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.outline, space: 1),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textMuted,
      textColor: AppColors.textPrimary,
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          fontFamily: 'Inter',
          fontFamilyFallback: fontFallback,
          bodyColor: AppColors.textPrimary,
          displayColor: AppColors.textPrimary,
        )
        .copyWith(
          bodySmall: base.textTheme.bodySmall?.copyWith(
            color: AppColors.textMuted,
            fontFamilyFallback: fontFallback,
          ),
        ),
  );
}
