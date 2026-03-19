import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GameUiTokens {
  static const bg0 = Color(0xFF070B12);
  static const bg1 = Color(0xFF0C1320);
  static const bg2 = Color(0xFF121C2D);

  static const textHi = Color(0xFFEAF3FF);
  static const textMid = Color(0xFFA9BCD4);
  static const textLow = Color(0xFF6F829B);

  static const accentPrimary = Color(0xFF49D6FF);
  static const accentSecondary = Color(0xFF7CFFB2);
  static const warning = Color(0xFFFFC24D);
  static const danger = Color(0xFFFF5E6A);

  static const panelBorder = Color(0xFF2A3A52);
  static const panelGlow = Color(0x3349D6FF);

  static const rSm = 10.0;
  static const rMd = 14.0;
  static const rLg = 20.0;

  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 20.0;
  static const s6 = 24.0;
}

class GameUiText {
  static TextStyle body({
    Color color = GameUiTokens.textHi,
    double size = 13,
    FontWeight weight = FontWeight.w600,
  }) {
    return GoogleFonts.rajdhani(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.15,
      height: 1.15,
    );
  }

  static TextStyle meta({
    Color color = GameUiTokens.textMid,
    double size = 11,
    FontWeight weight = FontWeight.w600,
  }) {
    return GoogleFonts.rajdhani(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: 0.2,
      height: 1.12,
    );
  }

  // Orbitron is intentionally limited to major labels and mode badges.
  static TextStyle command({
    Color color = GameUiTokens.textHi,
    double size = 14,
    FontWeight weight = FontWeight.w700,
    double letterSpacing = 0.75,
  }) {
    return GoogleFonts.orbitron(
      color: color,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: 1.1,
    );
  }

  static TextStyle objectiveTitle({
    required BuildContext context,
    Color color = GameUiTokens.textHi,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    final size = width < 370 ? 15.0 : 16.0;
    return GoogleFonts.orbitron(
      color: color,
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.45,
      height: 1.1,
    );
  }
}
