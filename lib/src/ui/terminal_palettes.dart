import 'package:flutter/material.dart';
import 'package:xterm3/xterm.dart';

class TerminalPalettePreset {
  const TerminalPalettePreset({
    required this.id,
    required this.name,
    required this.theme,
  });

  final String id;
  final String name;
  final TerminalTheme theme;
}

class NexusTerminalPalettes {
  static const List<TerminalPalettePreset> all = [
    TerminalPalettePreset(
      id: 'termius_dark',
      name: 'Termius Midnight',
      theme: TerminalTheme(
        cursor: Color(0xFF2AD882),
        selection: Color(0x4D4CC2FF),
        foreground: Color(0xFFE6ECF5),
        background: Color(0xFF141821),
        black: Color(0xFF1D222E),
        red: Color(0xFFFF6B81),
        green: Color(0xFF2AD882),
        yellow: Color(0xFFFECA57),
        blue: Color(0xFF54A0FF),
        magenta: Color(0xFFB388FF),
        cyan: Color(0xFF48DBFB),
        white: Color(0xFFCBD5E1),
        brightBlack: Color(0xFF576574),
        brightRed: Color(0xFFFF8A9B),
        brightGreen: Color(0xFF5CE6A0),
        brightYellow: Color(0xFFFFDF7E),
        brightBlue: Color(0xFF74B9FF),
        brightMagenta: Color(0xFFD1B3FF),
        brightCyan: Color(0xFF7BED9F),
        brightWhite: Color(0xFFF8FAFC),
        searchHitBackground: Color(0x66FECA57),
        searchHitBackgroundCurrent: Color(0xAAFECA57),
        searchHitForeground: Color(0xFF141821),
      ),
    ),
    TerminalPalettePreset(
      id: 'tokyo_night',
      name: 'Tokyo Night',
      theme: TerminalTheme(
        cursor: Color(0xFF7DCFFF),
        selection: Color(0x5538BDF8),
        foreground: Color(0xFFC0CAF5),
        background: Color(0xFF10131B),
        black: Color(0xFF15161E),
        red: Color(0xFFF7768E),
        green: Color(0xFF9ECE6A),
        yellow: Color(0xFFE0AF68),
        blue: Color(0xFF7AA2F7),
        magenta: Color(0xFFBB9AF7),
        cyan: Color(0xFF7DCFFF),
        white: Color(0xFFA9B1D6),
        brightBlack: Color(0xFF414868),
        brightRed: Color(0xFFF7768E),
        brightGreen: Color(0xFF9ECE6A),
        brightYellow: Color(0xFFE0AF68),
        brightBlue: Color(0xFF7AA2F7),
        brightMagenta: Color(0xFFBB9AF7),
        brightCyan: Color(0xFF7DCFFF),
        brightWhite: Color(0xFFE2E8F0),
        searchHitBackground: Color(0x66F59E0B),
        searchHitBackgroundCurrent: Color(0xAAF59E0B),
        searchHitForeground: Color(0xFF10131B),
      ),
    ),
    TerminalPalettePreset(
      id: 'catppuccin_mocha',
      name: 'Catppuccin Mocha',
      theme: TerminalTheme(
        cursor: Color(0xFFF5E0DC),
        selection: Color(0x55585B70),
        foreground: Color(0xFFCDD6F4),
        background: Color(0xFF181825),
        black: Color(0xFF45475A),
        red: Color(0xFFF38BA8),
        green: Color(0xFFA6E3A1),
        yellow: Color(0xFFF9E2AF),
        blue: Color(0xFF89B4FA),
        magenta: Color(0xFFF5C2E7),
        cyan: Color(0xFF94E2D5),
        white: Color(0xFFBAC2DE),
        brightBlack: Color(0xFF585B70),
        brightRed: Color(0xFFF38BA8),
        brightGreen: Color(0xFFA6E3A1),
        brightYellow: Color(0xFFF9E2AF),
        brightBlue: Color(0xFF89B4FA),
        brightMagenta: Color(0xFFF5C2E7),
        brightCyan: Color(0xFF94E2D5),
        brightWhite: Color(0xFFA6ADC8),
        searchHitBackground: Color(0x66F9E2AF),
        searchHitBackgroundCurrent: Color(0xAAF9E2AF),
        searchHitForeground: Color(0xFF181825),
      ),
    ),
    TerminalPalettePreset(
      id: 'paper_light',
      name: 'Clean Light',
      theme: TerminalTheme(
        cursor: Color(0xFF10B981),
        selection: Color(0x380EA5E9),
        foreground: Color(0xFF1E293B),
        background: Color(0xFFF8FAFC),
        black: Color(0xFF0F172A),
        red: Color(0xFFDC2626),
        green: Color(0xFF059669),
        yellow: Color(0xFFD97706),
        blue: Color(0xFF2563EB),
        magenta: Color(0xFF7C3AED),
        cyan: Color(0xFF0891B2),
        white: Color(0xFF475569),
        brightBlack: Color(0xFF64748B),
        brightRed: Color(0xFFEF4444),
        brightGreen: Color(0xFF10B981),
        brightYellow: Color(0xFFF59E0B),
        brightBlue: Color(0xFF3B82F6),
        brightMagenta: Color(0xFF8B5CF6),
        brightCyan: Color(0xFF06B6D4),
        brightWhite: Color(0xFF0F172A),
        searchHitBackground: Color(0x55F59E0B),
        searchHitBackgroundCurrent: Color(0x99F59E0B),
        searchHitForeground: Color(0xFF0F172A),
      ),
    ),
  ];

  static TerminalPalettePreset byId(String id) {
    return all.firstWhere((p) => p.id == id, orElse: () => all.first);
  }
}
