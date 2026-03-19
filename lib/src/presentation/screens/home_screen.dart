import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../widgets/frosted_overlay_card.dart';
import 'map_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const String _logoAsset = 'assets/images/hextrail_logo.png';
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _enterBattle() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const MapScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                        const _FirstObjectiveCard(),
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
                  color: GameUiTokens.danger.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: GameUiTokens.danger.withOpacity(0.75),
                  ),
                ),
                child: Text(
                  '🔴 LIVE BATTLE',
                  style: GameUiText.command(
                    color: GameUiTokens.danger,
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
            'Burke-Gilman West',
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
                icon: '🟢',
                label: 'You',
                value: '0',
                color: GameUiTokens.accentSecondary,
              ),
              SizedBox(width: 8),
              _HeroStatChip(
                icon: '🔴',
                label: 'Rival',
                value: '12',
                color: GameUiTokens.danger,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'First move: take the glowing target tile',
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
                  '⚠️ Under pressure • ⚡ 1 move to enter fight',
                  style: GameUiText.body(
                    color: GameUiTokens.warning,
                    size: 13,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '🔥 3 players active',
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

class _FirstObjectiveCard extends StatelessWidget {
  const _FirstObjectiveCard();

  @override
  Widget build(BuildContext context) {
    return FrostedOverlayCard(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🎯 FIRST OBJECTIVE',
            style: GameUiText.command(
              color: GameUiTokens.accentPrimary,
              size: 12,
              weight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Capture 3 tiles',
            style: GameUiText.body(
              color: GameUiTokens.textHi,
              size: 18,
              weight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Unlock your first streak',
            style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
          ),
          Text(
            'Start earning territory',
            style: GameUiText.meta(color: GameUiTokens.textMid, size: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: 0,
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
                '0 / 3',
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
