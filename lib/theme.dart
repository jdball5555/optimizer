import 'package:flutter/material.dart';

/// Black, white and the near-black blue-gray of your Axis apps, so the
/// colors of calendar events stand out — plus one accent, [Energy], for
/// what's live: focus time and where you are in the app.
class AppColors {
  static const background = Color(0xFF000000);
  static const surface = Color(0xFF0F141E);
  static const surfaceHigh = Color(0xFF171E2A);
  static const primaryText = Color(0xFFFFFFFF);
  static const secondaryText = Color(0xFF94A3B8);
  static const border = Color(0x1FFFFFFF);
  static const faint = Color(0x14FFFFFF);

  /// Only for destructive actions and money going down.
  static const danger = Color(0xFFF87171);
  static const positive = Color(0xFF4ADE80);
}

/// The energy beam: white at the core, through ice blue and electric blue
/// to violet, purple and pink at the edges.
class Energy {
  static const white = Color(0xFFF4F6FF);
  static const ice = Color(0xFFA8C4FF);
  static const blue = Color(0xFF4D6BFF);
  static const violet = Color(0xFF7A5CFF);
  static const purple = Color(0xFFB45CFF);
  static const pink = Color(0xFFFF79D6);

  /// The dark blue haze around the beam.
  static const haze = Color(0xFF1B2266);

  static const gradient = LinearGradient(colors: [blue, violet, purple, pink]);

  /// Around a ring, ending where it starts so there's no seam.
  static const ring = [ice, blue, violet, purple, pink, white, ice];
}

/// The tile every section sits on (same shape as the cards in your apps).
BoxDecoration tileDecoration({double radius = 18, bool raised = false}) => BoxDecoration(
      color: raised ? AppColors.surfaceHigh : AppColors.surface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: AppColors.border),
    );

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.primaryText,
    onPrimary: AppColors.background,
    primaryContainer: AppColors.surfaceHigh,
    onPrimaryContainer: AppColors.primaryText,
    secondary: AppColors.primaryText,
    onSecondary: AppColors.background,
    secondaryContainer: AppColors.surfaceHigh,
    onSecondaryContainer: AppColors.primaryText,
    tertiary: AppColors.primaryText,
    onTertiary: AppColors.background,
    error: AppColors.primaryText,
    onError: AppColors.background,
    surface: AppColors.background,
    onSurface: AppColors.primaryText,
    onSurfaceVariant: AppColors.secondaryText,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: Color(0x40FFFFFF),
    outlineVariant: AppColors.border,
    inverseSurface: AppColors.primaryText,
    onInverseSurface: AppColors.background,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(30));
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    visualDensity: VisualDensity.standard,
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(color: AppColors.primaryText),
      actionTextColor: AppColors.primaryText,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primaryText,
        foregroundColor: AppColors.background,
        disabledBackgroundColor: AppColors.faint,
        disabledForegroundColor: AppColors.secondaryText,
        shape: pill,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primaryText,
        side: const BorderSide(color: Color(0x40FFFFFF)),
        shape: pill,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.primaryText),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: AppColors.surfaceHigh,
      foregroundColor: AppColors.primaryText,
      shape: pill,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(AppColors.primaryText),
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? AppColors.surfaceHigh : Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: AppColors.background,
      indicatorColor: Color(0x404D6BFF),
      selectedIconTheme: IconThemeData(color: AppColors.primaryText),
      unselectedIconTheme: IconThemeData(color: AppColors.secondaryText),
      selectedLabelTextStyle: TextStyle(color: AppColors.primaryText, fontWeight: FontWeight.w600, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: AppColors.secondaryText, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.background,
      indicatorColor: const Color(0x404D6BFF),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? AppColors.primaryText : AppColors.secondaryText)),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.primaryText,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: AppColors.background),
    // Thin, 3–9 px in from the edge: inside the gaps beside tiles, not over
    // them (most lists use CalmScrollbar, which matches this).
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(6),
      crossAxisMargin: 3,
      radius: Radius.circular(3),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primaryText,
      linearTrackColor: AppColors.faint,
    ),
    checkboxTheme: CheckboxThemeData(
      checkColor: const WidgetStatePropertyAll(AppColors.background),
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.primaryText : Colors.transparent),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: AppColors.surface,
      headerBackgroundColor: AppColors.surface,
      headerForegroundColor: AppColors.primaryText,
      todayForegroundColor: const WidgetStatePropertyAll(AppColors.primaryText),
      todayBorder: const BorderSide(color: AppColors.primaryText),
      dayForegroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.background : AppColors.primaryText),
      dayBackgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.primaryText : Colors.transparent),
      yearForegroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.background : AppColors.primaryText),
      yearBackgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? AppColors.primaryText : Colors.transparent),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.primaryText,
      selectionColor: Color(0x40FFFFFF),
      selectionHandleColor: AppColors.primaryText,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: const TextStyle(color: AppColors.secondaryText),
      labelStyle: const TextStyle(color: AppColors.secondaryText),
      floatingLabelStyle: const TextStyle(color: AppColors.primaryText),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0x80FFFFFF)),
      ),
    ),
  );
}
