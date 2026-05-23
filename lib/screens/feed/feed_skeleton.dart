import 'package:flutter/material.dart';

/// Drop-in replacement for every CircularProgressIndicator on the feed.
/// Mimics the exact layout of a real post: full-screen media area,
/// top tab bar, right-side action buttons, bottom user info + caption.
class FeedSkeleton extends StatefulWidget {
  final bool isDark;
  const FeedSkeleton({Key? key, this.isDark = true}) : super(key: key);

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.35, end: 0.80).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5);
    final bone = isDark ? const Color(0xFF2C2C2C) : const Color(0xFFD8D8D8);
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: bg,
      body: AnimatedBuilder(
        animation: _opacity,
        builder: (context, _) {
          final boneOpaque = bone;
          final boneFaded = bone.withOpacity(_opacity.value);
          final boneStrong =
              bone.withOpacity((_opacity.value + 0.2).clamp(0.0, 1.0));

          return Stack(
            children: [
              // ── Full-screen media placeholder ──────────────────────────
              Positioned.fill(
                child: Container(color: boneFaded),
              ),

              // ── Gradient fade at bottom (like real post overlay) ───────
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: MediaQuery.of(context).size.height * 0.45,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        bg.withOpacity(0.65),
                        bg,
                      ],
                      stops: const [0.0, 0.6, 1.0],
                    ),
                  ),
                ),
              ),

              // ── Top: For You / Following tabs + message icon ───────────
              Positioned(
                top: topPad + 8,
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Tabs centered
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Bone(w: 68, h: 14, r: 5, color: boneStrong),
                          const SizedBox(width: 44),
                          _Bone(w: 68, h: 14, r: 5, color: boneStrong),
                        ],
                      ),
                      // Message icon right-aligned
                      Positioned(
                        right: 0,
                        child: _Bone(w: 26, h: 26, r: 13, color: boneStrong),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Right: action buttons (like, comment, share, profile) ──
              Positioned(
                right: 12,
                bottom: bottomPad + 108,
                child: Column(
                  children: [
                    _Bone(w: 46, h: 46, r: 23, color: boneOpaque),
                    const SizedBox(height: 4),
                    _Bone(w: 28, h: 11, r: 4, color: boneOpaque),
                    const SizedBox(height: 20),
                    _Bone(w: 46, h: 46, r: 23, color: boneOpaque),
                    const SizedBox(height: 4),
                    _Bone(w: 28, h: 11, r: 4, color: boneOpaque),
                    const SizedBox(height: 20),
                    _Bone(w: 46, h: 46, r: 23, color: boneOpaque),
                    const SizedBox(height: 4),
                    _Bone(w: 28, h: 11, r: 4, color: boneOpaque),
                    const SizedBox(height: 20),
                    _Bone(w: 46, h: 46, r: 23, color: boneOpaque),
                  ],
                ),
              ),

              // ── Bottom left: avatar + username + caption lines ─────────
              Positioned(
                left: 16,
                right: 76,
                bottom: bottomPad + 56,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Bone(w: 38, h: 38, r: 19, color: boneOpaque),
                        const SizedBox(width: 10),
                        _Bone(w: 115, h: 14, r: 5, color: boneOpaque),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _Bone(w: double.infinity, h: 12, r: 4, color: boneOpaque),
                    const SizedBox(height: 6),
                    _Bone(w: 190, h: 12, r: 4, color: boneOpaque),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Minimal bone (skeleton block) ─────────────────────────────────────────────
class _Bone extends StatelessWidget {
  final double w;
  final double h;
  final double r;
  final Color color;
  const _Bone({
    required this.w,
    required this.h,
    required this.r,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: w == double.infinity ? null : w,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(r),
      ),
    );
  }
}
