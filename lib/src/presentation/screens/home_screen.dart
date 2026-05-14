import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/constants/seattle_trail_sections.dart';
import '../../../core/theme/game_ui_tokens.dart';
import '../../../models/trail_section.dart';
import '../../data/services/display_name_service.dart';
import '../../data/services/trail_leaderboard_service.dart';
import '../widgets/frosted_overlay_card.dart';
import '../widgets/player_stats_sheet.dart';
import '../widgets/territory_pressure_card.dart';
import '../widgets/trail_leaderboard_sheet.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String _logoAsset = 'assets/images/hextrail_logo.png';
  late final AnimationController _pulseController;
  int _capturedTileCount = 0;
  Set<String> _capturedHexes = const {};
  String? _displayName;
  TrailLeaderboardSnapshot? _leaderboardSnapshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _loadCapturedCount();
    _loadDisplayName();
    _loadLeaderboardSnapshot();
  }

  Future<void> _loadLeaderboardSnapshot() async {
    try {
      final snapshot = await TrailLeaderboardService(
        supabaseClient: Supabase.instance.client,
      ).fetchBurkeGilman();
      if (mounted) setState(() => _leaderboardSnapshot = snapshot);
    } catch (_) {
      // Fail silent — pressure card collapses to SizedBox.shrink.
    }
  }

  Future<void> _loadDisplayName() async {
    try {
      final name = await DisplayNameService().getMine();
      if (mounted) setState(() => _displayName = name);
    } catch (_) {}
  }

  Future<void> _showDisplayNameDialog() async {
    final service = DisplayNameService();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => _DisplayNameDialog(initial: _displayName ?? ''),
    );
    if (result == null) return;

    final error = await service.setMine(result);
    if (!mounted) return;
    if (error == null) {
      setState(() => _displayName = result);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error == null ? 'Display name saved.' : 'Could not save: $error',
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadCapturedCount();
      _loadLeaderboardSnapshot();
    }
  }

  Future<void> _loadCapturedCount() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('captured_h3_cells_res9_v1');
    if (raw == null || raw.trim().isEmpty) {
      // No local cache yet (e.g. captures still pending Supabase sync on a
      // fresh launch). Keep current count (0 on first run) rather than
      // overwriting a previously-loaded value.
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      if (mounted) {
        setState(() {
          _capturedTileCount = list.length;
          _capturedHexes = list.map((e) => e.toString().toLowerCase()).toSet();
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _enterBattle() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const MapScreen()));
    // Returning from the map: captures may have synced from Supabase or
    // landed locally. Refresh the objective count so the home card stays
    // in sync with on-device state.
    if (mounted) {
      await _loadCapturedCount();
    }
  }

  void _enterBattleWithLeaderboard() {
    final service = TrailLeaderboardService(
      supabaseClient: Supabase.instance.client,
    );
    showTrailLeaderboardSheet(context, service: service);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [GameUiTokens.bg0, GameUiTokens.bg1],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _DisplayNamePill(
                      name: _displayName,
                      onTap: _showDisplayNameDialog,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        children: [
                          _LiveBattleCard(
                            pulse: _pulseController,
                            logoAsset: _logoAsset,
                          ),
                          const SizedBox(height: 12),
                          _LeaderboardTeaser(
                            onTap: _enterBattleWithLeaderboard,
                          ),
                          const SizedBox(height: 12),
                          _StatsTeaser(
                            onTap: () => showPlayerStatsSheet(context),
                          ),
                          if (_leaderboardSnapshot != null) ...[
                            const SizedBox(height: 12),
                            TerritoryPressureCard(
                              leaderboard: _leaderboardSnapshot,
                              onTap: _enterBattleWithLeaderboard,
                            ),
                          ],
                          const SizedBox(height: 12),
                          _ObjectiveCard(
                            capturedCount: _capturedTileCount,
                            capturedHexes: _capturedHexes,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _EnterBattleButton(
                    pulse: _pulseController,
                    logoAsset: _logoAsset,
                    onPressed: _enterBattle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveBattleCard extends StatelessWidget {
  final Animation<double> pulse;
  final String logoAsset;

  const _LiveBattleCard({required this.pulse, required this.logoAsset});

  @override
  Widget build(BuildContext context) {
    return FrostedOverlayCard(
      emphasized: true,
      borderRadius: const BorderRadius.all(Radius.circular(20)),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: GameUiTokens.accentPrimary.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: GameUiTokens.accentPrimary.withOpacity(0.75),
                  ),
                ),
                child: Text(
                  '⚔️ BATTLEFIELD',
                  style: GameUiText.command(
                    color: GameUiTokens.accentPrimary,
                    size: 11,
                    weight: FontWeight.w800,
                    letterSpacing: 0.55,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _BrandLogo(assetPath: logoAsset, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'HexTrail',
                      style: GameUiText.meta(
                        color: GameUiTokens.textMid,
                        size: 11,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Burke-Gilman Trail',
            style: GameUiText.command(
              color: GameUiTokens.textHi,
              size: 23,
              weight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: const [
              _HeroStatChip(
                icon: '⬡',
                label: 'Hexes',
                value: 'Claimable',
                color: GameUiTokens.accentSecondary,
              ),
              SizedBox(width: 8),
              _HeroStatChip(
                icon: '⚔️',
                label: 'Status',
                value: 'Contested',
                color: GameUiTokens.warning,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Claim hexes by walking or riding the trail',
            style: GameUiText.meta(
              color: GameUiTokens.accentPrimary,
              size: 12,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          _MiniHexBattlefield(pulse: pulse),
          const SizedBox(height: 9),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.20),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚡ Real territory · Real competition',
                  style: GameUiText.body(
                    color: GameUiTokens.accentPrimary,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Claim hexes — rankings update with every walk',
                  style: GameUiText.meta(
                    color: GameUiTokens.textMid,
                    size: 12,
                    weight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniHexBattlefield extends StatelessWidget {
  final Animation<double> pulse;

  const _MiniHexBattlefield({required this.pulse});

  static const List<_HexNode> _nodes = [
    _HexNode(left: 22, top: 106, owner: _HexOwner.neutral),
    _HexNode(left: 54, top: 86, owner: _HexOwner.you),
    _HexNode(left: 86, top: 66, owner: _HexOwner.you),
    _HexNode(left: 122, top: 54, owner: _HexOwner.contested),
    _HexNode(left: 156, top: 66, owner: _HexOwner.rival),
    _HexNode(left: 188, top: 86, owner: _HexOwner.rival),
    _HexNode(left: 220, top: 106, owner: _HexOwner.rival),
    _HexNode(left: 156, top: 106, owner: _HexOwner.rival),
    _HexNode(left: 90, top: 106, owner: _HexOwner.neutral),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = pulse.value;
        final rivalAura = 0.55 + 0.45 * (math.sin(t * math.pi * 2) + 1) / 2;
        return Container(
          height: 186,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF101D31),
                GameUiTokens.bg1.withOpacity(0.92),
              ],
            ),
            border: Border.all(
              color: GameUiTokens.panelBorder.withOpacity(0.85),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.26),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned(
                right: 22,
                top: 40,
                child: Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: GameUiTokens.danger.withOpacity(0.08 * rivalAura),
                    boxShadow: [
                      BoxShadow(
                        color: GameUiTokens.danger.withOpacity(
                          0.22 * rivalAura,
                        ),
                        blurRadius: 28,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(painter: _BattleLanePainter()),
              ),
              Positioned.fill(
                child: CustomPaint(painter: _RivalClusterPainter()),
              ),
              for (final node in _nodes)
                Positioned(
                  left: node.left,
                  top: node.top,
                  child: _HexTile(node: node, pulseValue: t),
                ),
              _ActivityDot(left: 132, top: 26, pulseValue: t, phase: 0.0),
              _ActivityDot(left: 176, top: 48, pulseValue: t, phase: 0.33),
              _ActivityDot(left: 208, top: 74, pulseValue: t, phase: 0.66),
            ],
          ),
        );
      },
    );
  }
}

class _ObjectiveCard extends StatelessWidget {
  final int capturedCount;
  final Set<String> capturedHexes;

  const _ObjectiveCard({
    required this.capturedCount,
    required this.capturedHexes,
  });

  @override
  Widget build(BuildContext context) {
    const firstTarget = 3;
    final firstDone = capturedCount >= firstTarget;

    if (!firstDone) {
      return _buildCard(
        tag: '🎯 FIRST OBJECTIVE',
        tagColor: GameUiTokens.accentPrimary,
        title: 'Capture 3 hexes',
        subtitle: 'Unlock your first streak',
        subtitle2: 'Start earning territory',
        progress: capturedCount.clamp(0, firstTarget),
        target: firstTarget,
      );
    }

    // Tier 2: Control a section of Burke-Gilman.
    final bgSections = SeattleTrailSectionDefinitions.sections
        .where((s) => s.trailId == 'burke_gilman')
        .toList();

    // Find the section closest to completion (highest %).
    TrailSectionDefinition? bestSection;
    int bestOwned = 0;
    for (final section in bgSections) {
      final owned = section.orderedH3Indexes
          .where((h) => capturedHexes.contains(h.toLowerCase()))
          .length;
      if (bestSection == null ||
          owned * bestSection.totalTiles > bestOwned * section.totalTiles) {
        bestSection = section;
        bestOwned = owned;
      }
    }

    if (bestSection != null && bestOwned >= bestSection.totalTiles) {
      // Section fully controlled — show completed state.
      return _buildCard(
        tag: '✅ SECTION CONTROLLED',
        tagColor: GameUiTokens.accentSecondary,
        title: bestSection.name,
        subtitle: 'You own every hex in this section',
        progress: bestOwned,
        target: bestSection.totalTiles,
      );
    }

    if (bestSection != null) {
      final total = bestSection.totalTiles;
      return _buildCard(
        tag: '🗺️ NEXT OBJECTIVE',
        tagColor: GameUiTokens.accentPrimary,
        title: 'Control ${bestSection.name}',
        subtitle: 'Capture every hex in this section',
        progress: bestOwned,
        target: total,
      );
    }

    // Fallback (should not happen with Burke-Gilman sections defined).
    return _buildCard(
      tag: '✅ OBJECTIVE COMPLETE',
      tagColor: GameUiTokens.accentSecondary,
      title: 'Capture 3 hexes',
      subtitle: 'Streak unlocked — keep conquering',
      progress: firstTarget,
      target: firstTarget,
    );
  }

  Widget _buildCard({
    required String tag,
    required Color tagColor,
    required String title,
    required String subtitle,
    String? subtitle2,
    required int progress,
    required int target,
  }) {
    return FrostedOverlayCard(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tag,
            style: GameUiText.command(
              color: tagColor,
              size: 12,
              weight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 18,
              weight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
          ),
          if (subtitle2 != null)
            Text(
              subtitle2,
              style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: target > 0 ? progress / target : 0,
                    minHeight: 7,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      GameUiTokens.accentSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$progress / $target',
                style: GameUiText.body(
                  color: GameUiTokens.textHi,
                  size: 13,
                  weight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact leaderboard teaser — acknowledges competition without showing
/// fake numbers.  Tapping navigates to the map where the leaderboard pill
/// is visible in the pre-session Guided HUD.
class _LeaderboardTeaser extends StatelessWidget {
  final VoidCallback onTap;

  const _LeaderboardTeaser({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FrostedOverlayCard(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            const Text('🏆', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Trail Rankings',
                    style: GameUiText.body(
                      color: GameUiTokens.accentPrimary,
                      size: 13,
                      weight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'See who controls the most territory',
                    style: GameUiText.meta(
                      color: GameUiTokens.textMid,
                      size: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: GameUiTokens.textMid),
          ],
        ),
      ),
    );
  }
}

class _StatsTeaser extends StatelessWidget {
  final VoidCallback onTap;

  const _StatsTeaser({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: FrostedOverlayCard(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
            const Text('📊', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your Stats',
                    style: GameUiText.body(
                      color: GameUiTokens.accentPrimary,
                      size: 13,
                      weight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Hexes, streaks, and personal bests',
                    style: GameUiText.meta(
                      color: GameUiTokens.textMid,
                      size: 11,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: GameUiTokens.textMid),
          ],
        ),
      ),
    );
  }
}

class _EnterBattleButton extends StatefulWidget {
  final Animation<double> pulse;
  final String logoAsset;
  final VoidCallback onPressed;

  const _EnterBattleButton({
    required this.pulse,
    required this.logoAsset,
    required this.onPressed,
  });

  @override
  State<_EnterBattleButton> createState() => _EnterBattleButtonState();
}

class _EnterBattleButtonState extends State<_EnterBattleButton> {
  bool _pressed = false;

  Future<void> _onPressed() async {
    if (_pressed) return;
    setState(() {
      _pressed = true;
    });
    await HapticFeedback.selectionClick();
    await Future<void>.delayed(const Duration(milliseconds: 85));
    if (!mounted) return;
    setState(() {
      _pressed = false;
    });
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.pulse,
      builder: (context, child) {
        final glow = 8 + (math.sin(widget.pulse.value * math.pi * 2) + 1) * 4;
        final pressScale = _pressed ? 0.985 : 1.0;
        return Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                GameUiTokens.bg2.withOpacity(0.70),
                GameUiTokens.bg1.withOpacity(0.16),
              ],
            ),
            border: Border.all(
              color: GameUiTokens.panelBorder.withOpacity(0.48),
            ),
          ),
          child: Column(
            children: [
              AnimatedScale(
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOutCubic,
                scale: pressScale,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: GameUiTokens.accentSecondary.withOpacity(0.35),
                        blurRadius: glow,
                        spreadRadius: 0.4,
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _onPressed,
                      style: FilledButton.styleFrom(
                        backgroundColor: GameUiTokens.accentSecondary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: _BrandLogo(assetPath: widget.logoAsset, size: 16),
                      label: Text(
                        '⚡ ENTER THE BATTLE',
                        style: GameUiText.command(
                          color: Colors.black,
                          size: 14,
                          weight: FontWeight.w900,
                          letterSpacing: 0.55,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                'No sign-up required • Start instantly',
                style: GameUiText.meta(color: GameUiTokens.textLow, size: 11),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HeroStatChip extends StatelessWidget {
  final String icon;
  final String label;
  final String value;
  final Color color;

  const _HeroStatChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.65)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(icon, style: GameUiText.meta(color: color, size: 11)),
            const SizedBox(width: 6),
            Text(
              '$label: $value',
              style: GameUiText.body(
                color: GameUiTokens.textHi,
                size: 12,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HexTile extends StatelessWidget {
  final _HexNode node;
  final double pulseValue;

  const _HexTile({required this.node, required this.pulseValue});

  @override
  Widget build(BuildContext context) {
    final isContested = node.owner == _HexOwner.contested;
    final isRival = node.owner == _HexOwner.rival;
    final rivalBreath =
        0.55 + 0.45 * (math.sin(pulseValue * math.pi * 2) + 1) / 2;
    final contestedBreath =
        0.65 + 0.35 * (math.sin(pulseValue * math.pi * 2 + 1.2) + 1) / 2;

    Color fill;
    Color border;
    Color glow;

    switch (node.owner) {
      case _HexOwner.you:
        fill = GameUiTokens.accentSecondary.withOpacity(0.30);
        border = GameUiTokens.accentSecondary.withOpacity(0.90);
        glow = GameUiTokens.accentSecondary.withOpacity(0.22);
      case _HexOwner.rival:
        fill = GameUiTokens.danger.withOpacity(0.32);
        border = GameUiTokens.danger.withOpacity(0.88);
        glow = GameUiTokens.danger.withOpacity(0.26 * rivalBreath);
      case _HexOwner.neutral:
        fill = Colors.white.withOpacity(0.10);
        border = Colors.white38;
        glow = Colors.transparent;
      case _HexOwner.contested:
        fill = GameUiTokens.warning.withOpacity(0.38);
        border = GameUiTokens.accentPrimary.withOpacity(0.95);
        glow = GameUiTokens.warning.withOpacity(0.32 * contestedBreath);
    }

    final scale = isContested ? (0.98 + 0.08 * contestedBreath) : 1.0;

    final targetRingOpacity = 0.38 + (0.42 * contestedBreath);

    return Transform.scale(
      scale: scale,
      child: SizedBox(
        width: 34,
        height: 32,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (isContested)
              Transform.scale(
                scale: 1.45 + (0.10 * contestedBreath),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: GameUiTokens.accentPrimary.withOpacity(
                        targetRingOpacity,
                      ),
                      width: 2.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: GameUiTokens.accentPrimary.withOpacity(
                          0.30 * contestedBreath,
                        ),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
            Container(
              width: 34,
              height: 32,
              decoration: BoxDecoration(
                boxShadow: [
                  if (isRival || isContested)
                    BoxShadow(color: glow, blurRadius: isContested ? 12 : 9),
                ],
              ),
              child: ClipPath(
                clipper: _HexClipper(),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [fill.withOpacity(0.85), fill],
                    ),
                    border: Border.all(
                      color: border,
                      width: isContested ? 1.8 : 1.2,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityDot extends StatelessWidget {
  final double left;
  final double top;
  final double pulseValue;
  final double phase;

  const _ActivityDot({
    required this.left,
    required this.top,
    required this.pulseValue,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    final wave = (math.sin((pulseValue + phase) * math.pi * 2) + 1) / 2;
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: GameUiTokens.accentPrimary.withOpacity(0.55 + 0.35 * wave),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: GameUiTokens.accentPrimary.withOpacity(0.20 + 0.25 * wave),
              blurRadius: 6 + 4 * wave,
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandLogo extends StatelessWidget {
  final String assetPath;
  final double size;

  const _BrandLogo({required this.assetPath, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: size,
            height: size,
            color: GameUiTokens.bg2,
            alignment: Alignment.center,
            child: Icon(
              Icons.hexagon_rounded,
              size: size * 0.76,
              color: GameUiTokens.accentPrimary,
            ),
          );
        },
      ),
    );
  }
}

enum _HexOwner { you, rival, neutral, contested }

class _HexNode {
  final double left;
  final double top;
  final _HexOwner owner;

  const _HexNode({required this.left, required this.top, required this.owner});
}

class _HexClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;
    path.moveTo(w * 0.25, 0);
    path.lineTo(w * 0.75, 0);
    path.lineTo(w, h * 0.5);
    path.lineTo(w * 0.75, h);
    path.lineTo(w * 0.25, h);
    path.lineTo(0, h * 0.5);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _BattleLanePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final lane = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = GameUiTokens.accentPrimary.withOpacity(0.18);

    final path = Path()
      ..moveTo(size.width * 0.08, size.height * 0.80)
      ..quadraticBezierTo(
        size.width * 0.35,
        size.height * 0.62,
        size.width * 0.50,
        size.height * 0.44,
      )
      ..quadraticBezierTo(
        size.width * 0.66,
        size.height * 0.30,
        size.width * 0.92,
        size.height * 0.20,
      );

    canvas.drawPath(path, lane);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RivalClusterPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final link = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = GameUiTokens.danger.withOpacity(0.20);

    final p1 = Offset(173, 82);
    final p2 = Offset(205, 102);
    final p3 = Offset(237, 122);
    final p4 = Offset(173, 122);

    canvas.drawLine(p1, p2, link);
    canvas.drawLine(p2, p3, link);
    canvas.drawLine(p1, p4, link);
    canvas.drawLine(p4, p3, link);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DisplayNamePill extends StatelessWidget {
  final String? name;
  final VoidCallback onTap;

  const _DisplayNamePill({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hasName = name != null && name!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.22),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasName ? Icons.person : Icons.person_outline,
              size: 14,
              color: GameUiTokens.textMid,
            ),
            const SizedBox(width: 6),
            Text(
              hasName ? name! : 'Set display name',
              style: GameUiText.meta(
                color: hasName ? GameUiTokens.textHi : GameUiTokens.textMid,
                size: 12,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DisplayNameDialog extends StatefulWidget {
  final String initial;
  const _DisplayNameDialog({required this.initial});

  @override
  State<_DisplayNameDialog> createState() => _DisplayNameDialogState();
}

class _DisplayNameDialogState extends State<_DisplayNameDialog> {
  late final TextEditingController _controller;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onSave() {
    final err = DisplayNameService.validate(_controller.text);
    if (err != null) {
      setState(() => _inlineError = err);
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Display name'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Shown on the trail leaderboard. 3\u201320 characters; '
            'letters, digits, _ and - only.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 20,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. trail_runner_42',
              errorText: _inlineError,
            ),
            onChanged: (_) {
              if (_inlineError != null) {
                setState(() => _inlineError = null);
              }
            },
            onSubmitted: (_) => _onSave(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _onSave,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
