import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/game_ui_tokens.dart';

const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────

enum ShareCardFormat { feed, story }

enum ShareCardTheme { dark, light }

/// A single stat row for the share card, mirroring the summary card layout.
class ShareStat {
  final IconData? icon;
  final String? emoji;
  final String label;
  final String value;
  final bool hero;
  const ShareStat(this.icon, this.label, this.value, {this.hero = false})
      : emoji = null;
  const ShareStat.emoji(this.emoji, this.label, this.value,
      {this.hero = false})
      : icon = null;
}

/// Data needed to render the session share card.
class SessionShareData {
  final bool riding;
  final String title;
  final String subtitle;
  final int tilesCaptured;
  final String distanceText;
  final String timeText;
  final int takeovers;
  final String? trailName;
  final double? trailPercent;
  final int? leaderboardRank;
  final int? totalPlayers;
  final String? playerName;
  final int? hexStreak;
  final List<Offset>? trailWaypoints;
  final List<ShareStat> stats;
  final DateTime sessionDate;

  const SessionShareData({
    required this.riding,
    required this.title,
    required this.subtitle,
    required this.tilesCaptured,
    required this.distanceText,
    required this.timeText,
    required this.sessionDate,
    this.takeovers = 0,
    this.trailName,
    this.trailPercent,
    this.leaderboardRank,
    this.totalPlayers,
    this.playerName,
    this.hexStreak,
    this.trailWaypoints,
    this.stats = const [],
  });
}

/// Shows a format/theme picker, renders the card offscreen, and shares.
Future<void> shareSessionCard(
  BuildContext context,
  SessionShareData data,
) async {
  // Capture overlay ref before any async gap.
  final overlayState = Overlay.of(context);

  // Quick bottom-sheet picker for format + theme.
  final result = await showModalBottomSheet<(ShareCardFormat, ShareCardTheme)>(
    context: context,
    backgroundColor: GameUiTokens.bg1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _ShareFormatPicker(riding: data.riding),
  );
  if (result == null) return; // user dismissed
  final (format, theme) = result;

  final key = GlobalKey();

  final overlay = OverlayEntry(
    builder: (_) => Positioned(
      left: -9999,
      top: -9999,
      child: RepaintBoundary(
        key: key,
        child: _SessionShareCardContent(
          data: data,
          format: format,
          theme: theme,
        ),
      ),
    ),
  );

  overlayState.insert(overlay);
  await Future<void>.delayed(const Duration(milliseconds: 150));

  try {
    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;

    final image = await boundary.toImage(pixelRatio: 3.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return;

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/hextrail_session.png');
    await file.writeAsBytes(byteData.buffer.asUint8List());

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'image/png')],
      text: '⬡ HexTrail — ${data.riding ? "Ride" : "Session"} Complete\n'
          'Claim your territory. hextrail.app',
    );
  } finally {
    overlay.remove();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Format/theme picker bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _ShareFormatPicker extends StatefulWidget {
  final bool riding;
  const _ShareFormatPicker({required this.riding});

  @override
  State<_ShareFormatPicker> createState() => _ShareFormatPickerState();
}

class _ShareFormatPickerState extends State<_ShareFormatPicker> {
  ShareCardFormat _format = ShareCardFormat.feed;
  ShareCardTheme _theme = ShareCardTheme.dark;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: GameUiTokens.textLow,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Share as',
              style: GameUiText.body(
                color: GameUiTokens.textHi,
                size: 16,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _chipButton(
                  label: '📸 Feed (4:5)',
                  selected: _format == ShareCardFormat.feed,
                  onTap: () => setState(() => _format = ShareCardFormat.feed),
                ),
                const SizedBox(width: 8),
                _chipButton(
                  label: '📱 Story (9:16)',
                  selected: _format == ShareCardFormat.story,
                  onTap: () => setState(() => _format = ShareCardFormat.story),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _chipButton(
                  label: '🌙 Dark',
                  selected: _theme == ShareCardTheme.dark,
                  onTap: () => setState(() => _theme = ShareCardTheme.dark),
                ),
                const SizedBox(width: 8),
                _chipButton(
                  label: '☀️ Light',
                  selected: _theme == ShareCardTheme.light,
                  onTap: () => setState(() => _theme = ShareCardTheme.light),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: GameUiTokens.accentPrimary,
                  foregroundColor: GameUiTokens.bg0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => Navigator.pop(context, (_format, _theme)),
                child: Text(
                  'Share',
                  style: GameUiText.body(
                    color: GameUiTokens.bg0,
                    size: 15,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? GameUiTokens.accentPrimary.withValues(alpha: 0.18)
              : GameUiTokens.bg2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? GameUiTokens.accentPrimary
                : GameUiTokens.panelBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: GameUiText.meta(
            color: selected ? GameUiTokens.accentPrimary : GameUiTokens.textMid,
            size: 13,
            weight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Resolved color palette per theme
// ─────────────────────────────────────────────────────────────────────────────

class _CardColors {
  final Color bg;
  final Color bgLighter;
  final Color textHi;
  final Color textMid;
  final Color textLow;
  final Color accent;
  final Color accentSecondary;
  final Color border;
  final Color divider;
  final Color heroGlow;
  final Color hexWatermark;
  final Color trailDim;

  const _CardColors._({
    required this.bg,
    required this.bgLighter,
    required this.textHi,
    required this.textMid,
    required this.textLow,
    required this.accent,
    required this.accentSecondary,
    required this.border,
    required this.divider,
    required this.heroGlow,
    required this.hexWatermark,
    required this.trailDim,
  });

  static _CardColors of(ShareCardTheme theme) => switch (theme) {
        ShareCardTheme.dark => const _CardColors._(
            bg: Color(0xFF080E18),
            bgLighter: Color(0xFF101828),
            textHi: Color(0xFFEAF3FF),
            textMid: Color(0xFFA9BCD4),
            textLow: Color(0xFF6F829B),
            accent: Color(0xFF49D6FF),
            accentSecondary: Color(0xFF7CFFB2),
            border: Color(0x4D49D6FF),
            divider: Color(0x802A3A52),
            heroGlow: Color(0x337CFFB2),
            hexWatermark: Color(0x08FFFFFF),
            trailDim: Color(0x30FFFFFF),
          ),
        ShareCardTheme.light => const _CardColors._(
            bg: Color(0xFFF5F7FA),
            bgLighter: Color(0xFFFFFFFF),
            textHi: Color(0xFF111827),
            textMid: Color(0xFF4B5563),
            textLow: Color(0xFF9CA3AF),
            accent: Color(0xFF0891B2),
            accentSecondary: Color(0xFF059669),
            border: Color(0x330891B2),
            divider: Color(0x30D1D5DB),
            heroGlow: Color(0x22059669),
            hexWatermark: Color(0x08000000),
            trailDim: Color(0x30000000),
          ),
      };
}

class _SessionShareCardContent extends StatelessWidget {
  final SessionShareData data;
  final ShareCardFormat format;
  final ShareCardTheme theme;

  const _SessionShareCardContent({
    required this.data,
    this.format = ShareCardFormat.feed,
    this.theme = ShareCardTheme.dark,
  });

  @override
  Widget build(BuildContext context) {
    final c = _CardColors.of(theme);
    final riding = data.riding;
    final stats = data.stats;
    final heroStats = stats.where((s) => s.hero).toList();
    final regularStats = stats.where((s) => !s.hero).toList();

    // Dimensions by format.
    final double cardWidth;
    final double cardHeight;
    switch (format) {
      case ShareCardFormat.feed:
        cardWidth = 400;
        cardHeight = 500;
      case ShareCardFormat.story:
        cardWidth = 400;
        cardHeight = 710; // ≈ 9:16 at 400 wide
    }
    final isStory = format == ShareCardFormat.story;

    // Date stamp.
    final d = data.sessionDate;
    final dateFmt = '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';
    final dateStamp =
        data.trailName != null ? '$dateFmt · ${data.trailName}' : dateFmt;

    // Rank text — percentile when enough players, otherwise raw.
    final String? rankText;
    if (data.leaderboardRank != null &&
        data.totalPlayers != null &&
        data.totalPlayers! >= 3) {
      final pct =
          (data.leaderboardRank! / data.totalPlayers! * 100).round();
      rankText = 'Top $pct% on the leaderboard';
    } else if (data.leaderboardRank != null) {
      rankText = 'Rank #${data.leaderboardRank} on the leaderboard';
    } else {
      rankText = null;
    }

    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        width: cardWidth,
        height: cardHeight,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.border),
            gradient: RadialGradient(
              center: const Alignment(0, -0.3),
              radius: 1.1,
              colors: [c.bgLighter, c.bg],
            ),
          ),
          child: Stack(
            children: [
              // ── Hex grid watermark ──
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: CustomPaint(
                    painter: _HexWatermarkPainter(color: c.hexWatermark),
                  ),
                ),
              ),
              // ── Content ──
              Padding(
                padding: EdgeInsets.fromLTRB(
                    28, isStory ? 40 : 24, 28, isStory ? 32 : 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──
                    Center(
                      child: Column(
                        children: [
                          Icon(
                            riding
                                ? Icons.pedal_bike
                                : Icons.directions_walk,
                            color: c.accent,
                            size: isStory ? 32 : 26,
                          ),
                          SizedBox(height: isStory ? 10 : 6),
                          Text(
                            data.title,
                            style: GameUiText.command(
                              color: c.accent,
                              size: isStory ? 20 : 16,
                              letterSpacing: 1.5,
                            ),
                          ),
                          if (data.playerName != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              data.playerName!,
                              style: GameUiText.meta(
                                color: c.textLow,
                                size: isStory ? 12 : 10,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            data.subtitle,
                            style: GameUiText.meta(
                              color: c.textMid,
                              size: isStory ? 15 : 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            dateStamp,
                            style: GameUiText.meta(
                              color: c.textLow,
                              size: isStory ? 12 : 11,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (data.hexStreak != null &&
                              data.hexStreak! > 1) ...[
                            const SizedBox(height: 3),
                            Text(
                              '🔥 ${data.hexStreak}-hex streak',
                              style: GameUiText.meta(
                                color: c.accentSecondary,
                                size: isStory ? 13 : 11,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(height: isStory ? 20 : 14),

                    // ── Divider + hero stat with glow ──
                    Container(height: 1, color: c.divider),
                    SizedBox(height: isStory ? 18 : 12),
                    ...heroStats.map(
                      (s) => Center(
                        child: Padding(
                          padding: EdgeInsets.only(
                              bottom: isStory ? 14 : 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: RadialGradient(
                                radius: 1.2,
                                colors: [c.heroGlow, Colors.transparent],
                              ),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  s.value,
                                  style: GameUiText.command(
                                    color: c.accentSecondary,
                                    size: isStory ? 48 : 38,
                                    weight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  s.label.toUpperCase(),
                                  style: GameUiText.meta(
                                    color: c.textMid,
                                    size: isStory ? 15 : 13,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── Regular stat rows ──
                    ...regularStats.map(
                      (s) => Padding(
                        padding: EdgeInsets.symmetric(
                            vertical: isStory ? 6 : 4),
                        child: Row(
                          children: [
                            if (s.emoji != null)
                              Text(s.emoji!,
                                  style: TextStyle(
                                      fontSize: isStory ? 16 : 14))
                            else if (s.icon != null)
                              Icon(s.icon,
                                  size: isStory ? 18 : 16,
                                  color: c.textMid),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                s.label,
                                style: GameUiText.meta(
                                  color: c.textMid,
                                  size: isStory ? 16 : 14,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Text(
                              s.value,
                              style: GameUiText.body(
                                color: c.textHi,
                                size: isStory ? 18 : 16,
                                weight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // ── Mini trail map + progress ──
                    if (data.trailName != null) ...[
                      SizedBox(height: isStory ? 16 : 10),
                      if (data.trailWaypoints != null &&
                          data.trailWaypoints!.length >= 2)
                        SizedBox(
                          height: isStory ? 48 : 32,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: _TrailMapPainter(
                              waypoints: data.trailWaypoints!,
                              fillPercent:
                                  (data.trailPercent ?? 0) / 100.0,
                              dimColor: c.trailDim,
                              brightColor: c.accentSecondary,
                            ),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              data.trailName!,
                              style: GameUiText.meta(
                                color: c.textMid,
                                size: isStory ? 14 : 13,
                                weight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${data.trailPercent?.toStringAsFixed(0) ?? '0'}% controlled',
                            style: GameUiText.body(
                              color: c.accentSecondary,
                              size: isStory ? 16 : 14,
                              weight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],

                    // ── Rank ──
                    if (rankText != null) ...[
                      SizedBox(height: isStory ? 12 : 8),
                      Row(
                        children: [
                          const Text('🏆',
                              style: TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Text(
                            rankText,
                            style: GameUiText.body(
                              color: c.accent,
                              size: isStory ? 16 : 14,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ],

                    const Spacer(),

                    // ── Footer ──
                    Container(height: 1, color: c.divider),
                    const SizedBox(height: 12),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '⬡',
                              style: TextStyle(
                                fontSize: isStory ? 18 : 16,
                                height: 1.0,
                                color: c.accent,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Claim your trail.',
                            style: GameUiText.meta(
                              color: c.textMid,
                              size: isStory ? 13 : 12,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'hextrail.app',
                            style: GameUiText.meta(
                              color: c.textLow,
                              size: isStory ? 13 : 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom painters
// ─────────────────────────────────────────────────────────────────────────────

/// Faint flat-top hexagonal grid drawn behind the card content.
class _HexWatermarkPainter extends CustomPainter {
  final Color color;
  _HexWatermarkPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    const hexR = 22.0;
    final hSpace = hexR * 1.5;
    final vSpace = hexR * math.sqrt(3);

    for (double x = -hexR; x < size.width + hexR; x += hSpace) {
      final col = (x / hSpace).floor();
      for (double y = -hexR; y < size.height + hexR; y += vSpace) {
        final yOff = col.isOdd ? vSpace / 2 : 0.0;
        _drawHex(canvas, Offset(x, y + yOff), hexR, paint);
      }
    }
  }

  void _drawHex(Canvas canvas, Offset c, double r, Paint paint) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (60 * i - 30) * math.pi / 180;
      final pt =
          Offset(c.dx + r * math.cos(angle), c.dy + r * math.sin(angle));
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Miniature trail silhouette with a filled-percentage highlight.
class _TrailMapPainter extends CustomPainter {
  final List<Offset> waypoints;
  final double fillPercent;
  final Color dimColor;
  final Color brightColor;

  _TrailMapPainter({
    required this.waypoints,
    required this.fillPercent,
    required this.dimColor,
    required this.brightColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (waypoints.length < 2) return;

    double minX = double.infinity, maxX = -double.infinity;
    double minY = double.infinity, maxY = -double.infinity;
    for (final p in waypoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    final rangeX = maxX - minX;
    final rangeY = maxY - minY;
    if (rangeX == 0 && rangeY == 0) return;

    const pad = 4.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final scale = math.min(
      rangeX > 0 ? availW / rangeX : double.infinity,
      rangeY > 0 ? availH / rangeY : double.infinity,
    );
    final offX = pad + (availW - rangeX * scale) / 2;
    final offY = pad + (availH - rangeY * scale) / 2;

    Offset project(Offset p) => Offset(
          offX + (p.dx - minX) * scale,
          offY + (maxY - p.dy) * scale, // flip Y — north is up
        );

    // Full trail (dim).
    final dimPaint = Paint()
      ..color = dimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fullPath = Path();
    final first = project(waypoints.first);
    fullPath.moveTo(first.dx, first.dy);
    for (int i = 1; i < waypoints.length; i++) {
      final p = project(waypoints[i]);
      fullPath.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(fullPath, dimPaint);

    // Filled portion (bright).
    if (fillPercent > 0) {
      final fillCount =
          (waypoints.length * fillPercent).round().clamp(2, waypoints.length);
      final brightPaint = Paint()
        ..color = brightColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final filledPath = Path();
      final f = project(waypoints.first);
      filledPath.moveTo(f.dx, f.dy);
      for (int i = 1; i < fillCount; i++) {
        final p = project(waypoints[i]);
        filledPath.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(filledPath, brightPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
