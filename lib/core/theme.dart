import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── MindFeed Color Palette ───────────────────────────────────────────────────
class MFColors {
  // Zinc scale (dark backgrounds)
  static const bg = Color(0xFF09090B);        // zinc-950
  static const surface = Color(0xFF18181B);   // zinc-900
  static const surfaceAlt = Color(0xFF1C1C1F); // zinc-850
  static const border = Color(0xFF27272A);    // zinc-800
  static const borderLight = Color(0xFF3F3F46); // zinc-700

  // Text
  static const textPrimary = Color(0xFFF4F4F5);   // zinc-100
  static const textSecondary = Color(0xFFA1A1AA);  // zinc-400
  static const textMuted = Color(0xFF71717A);       // zinc-500

  // Accent: Teal
  static const teal = Color(0xFF14B8A6);       // teal-500
  static const tealDark = Color(0xFF0F766E);   // teal-700
  static const tealBg = Color(0xFF042F2E);     // teal-950

  // Status colors
  static const inbox = Color(0xFF6366F1);      // indigo
  static const active = Color(0xFF14B8A6);     // teal
  static const done = Color(0xFF22C55E);       // green
  static const archived = Color(0xFF71717A);   // zinc

  // Pinned
  static const pinned = Color(0xFFEC4899);     // pink-500
}

// ─── App Theme ────────────────────────────────────────────────────────────────
class MFTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: MFColors.bg,
      colorScheme: const ColorScheme.dark(
        surface: MFColors.surface,
        primary: MFColors.teal,
        onPrimary: MFColors.bg,
        secondary: MFColors.teal,
        onSecondary: MFColors.bg,
        outline: MFColors.border,
        onSurface: MFColors.textPrimary,
        surfaceContainerHighest: MFColors.surfaceAlt,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: MFColors.textPrimary,
        displayColor: MFColors.textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: MFColors.bg,
        foregroundColor: MFColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: MFColors.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: MFColors.surface,
        indicatorColor: MFColors.tealBg,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: MFColors.teal);
          }
          return const IconThemeData(color: MFColors.textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final style = GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600);
          if (states.contains(WidgetState.selected)) {
            return style.copyWith(color: MFColors.teal);
          }
          return style.copyWith(color: MFColors.textMuted);
        }),
      ),
      cardTheme: const CardThemeData(
        color: MFColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(
        color: MFColors.border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MFColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MFColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MFColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MFColors.teal, width: 1.5),
        ),
        hintStyle: const TextStyle(color: MFColors.textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: MFColors.teal,
        foregroundColor: MFColors.bg,
        elevation: 2,
        shape: CircleBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: MFColors.tealBg,
        labelStyle: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: MFColors.teal,
        ),
        side: const BorderSide(color: Color(0xFF0F766E), width: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(99)),
      ),
    );
  }
}
