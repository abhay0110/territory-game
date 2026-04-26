import 'package:flutter/material.dart';

class GameColors {
  static const Color neonGreen = Color(0xFF00FF9C);
  static const Color myTileGreen = Color(0xFF00E676);
  // Enemy-owned, still inside protection window (cannot be taken).
  // Saturated red — communicates "rival territory, locked".
  static const Color rivalRed = Color(0xFFFF4D4D);
  // Enemy-owned, protection expired (capturable target).
  // Distinct orange-red so the actionable hex pops against the protected
  // red — the previous dark crimson sat too close to rivalRed visually.
  static const Color rivalRedDark = Color(0xFFFF6B35);
  // Outline for capturable enemy hexes — slightly deeper amber for contrast.
  static const Color rivalOutlineDark = Color(0xFFB34A1F);
  static const Color neutralGray = Color(0xFF3D8BFF);
  static const Color currentBorder = Color(0xFFFFFFFF);
  static const Color hudBlack = Color(0x99000000);

  static const int neonGreenArgb = 0xFF00FF9C;
  static const int myTileGreenArgb = 0xFF00E676;
  static const int rivalRedArgb = 0xFFFF4D4D;
  static const int rivalRedDarkArgb = 0xFFFF6B35;
  static const int rivalOutlineDarkArgb = 0xFFB34A1F;
  static const int neutralGrayArgb = 0xFF3D8BFF;
  static const int currentBorderArgb = 0xFFFFFFFF;
  static const int outlineDarkArgb = 0xFF000000;

  static const Color statusTracking = Color(0xFF00E676);
  static const Color statusSessionOn = Color(0xFF40C4FF);
}
