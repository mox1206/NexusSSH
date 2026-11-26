import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Termius-inspired Midnight Charcoal & Crisp Mint color system.
/// Focused on soft surface hierarchy rather than heavy borders.
class NexusColors {
  // Surfaces (Termius Midnight Charcoal hierarchy)
  static const Color bgSidebar = Color(0xFF10131A);
  static const Color bgCanvas = Color(0xFF141821);
  static const Color bgSurface = Color(0xFF1D222E);
  static const Color bgElevated = Color(0xFF252B3B);
  static const Color bgKeycap = Color(0xFF282F40);

  // Subtle hairlines
  static const Color borderSubtle = Color(0xFF262D3D);
  static const Color borderActive = Color(0xFF364057);

  // Brand & Semantic Accents (Termius Mint Green + Clean Secondary Tones)
  static const Color emerald = Color(0xFF2AD882);
  static const Color cyan = Color(0xFF4CC2FF);
  static const Color violet = Color(0xFFA78BFA);
  static const Color amber = Color(0xFFFBBF24);
  static const Color rose = Color(0xFFFF5C77);

  // Typography
  static const Color textPrimary = Color(0xFFF3F6FA);
  static const Color textSecondary = Color(0xFF949EB2);
  static const Color textMuted = Color(0xFF636D82);

  static const List<String> hostAccents = [
    '#2AD882', // Termius Mint
    '#4CC2FF', // Sky Blue
    '#A78BFA', // Soft Violet
    '#FBBF24', // Warm Amber
    '#FF5C77', // Coral Rose
    '#2DD4BF', // Aqua Teal
  ];
}

class NexusTheme {
  static String get monospaceFontFamily {
    if (kIsWeb) return 'monospace';
    if (Platform.isWindows) return 'Consolas';
    if (Platform.isMacOS || Platform.isIOS) return 'Menlo';
    return 'monospace';
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: NexusColors.bgCanvas,
      colorScheme: const ColorScheme.dark(
        primary: NexusColors.emerald,
        secondary: NexusColors.cyan,
        surface: NexusColors.bgSurface,
        error: NexusColors.rose,
        onPrimary: Color(0xFF062819),
        onSecondary: Color(0xFF062538),
        onSurface: NexusColors.textPrimary,
      ),
      dividerColor: NexusColors.borderSubtle,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        color: NexusColors.bgSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: NexusColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: NexusColors.borderSubtle),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: NexusColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: NexusColors.emerald,
          foregroundColor: const Color(0xFF062819),
          textStyle: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: NexusColors.bgSurface,
        isDense: true,
        hintStyle: const TextStyle(color: NexusColors.textMuted, fontSize: 13.5),
        labelStyle: const TextStyle(
          color: NexusColors.textSecondary,
          fontSize: 13,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: NexusColors.emerald, width: 1.3),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: NexusColors.rose, width: 1.1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: NexusColors.rose, width: 1.3),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: NexusColors.bgElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: NexusColors.borderActive),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: NexusColors.bgElevated,
        contentTextStyle: const TextStyle(
          color: NexusColors.textPrimary,
          fontSize: 13,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
