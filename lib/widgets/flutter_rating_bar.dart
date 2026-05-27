import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

// =============================================================================
// EMOJI THUMB SHAPE – continuous scaling from rating 1 (smallest) to 10 (largest)
// =============================================================================

class _EmojiThumbShape extends SliderComponentShape {
  final String emoji;
  final double baseSize;
  final double arrowBounce;
  final double arrowOpacity;
  final bool showArrow;

  const _EmojiThumbShape({
    required this.emoji,
    this.baseSize = 30.0,
    this.arrowBounce = 0.0,
    this.arrowOpacity = 0.0,
    this.showArrow = false,
  });

  // value is normalized rating 1..10 mapped to 0..1 (0=rating1, 1=rating10)
  static double _scaleForValue(double value) {
    // Continuous scale: at value 0.0 -> scale 0.7, at value 1.0 -> scale 1.5
    return 0.7 + 0.8 * value.clamp(0.0, 1.0);
  }

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    // Reserve enough space for the largest size (1.5 * baseSize)
    return Size(baseSize * 1.5, baseSize * 1.5);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final scale = _scaleForValue(value);
    final double emojiSize = baseSize * scale;

    // Move the arrow up when the emoji grows
    final double arrowOffsetY = (scale - 1.0) * 12;

    if (showArrow && arrowOpacity > 0) {
      const arrowSize = 48.0;
      const arrowScaleY = 2.2;
      final arrowH = arrowSize * arrowScaleY;
      final arrowTop =
          center.dy - baseSize / 2 - arrowH - 8 - arrowBounce - arrowOffsetY;
      final arrowCenter = Offset(center.dx, arrowTop + arrowH / 2);

      final arrowPainter = TextPainter(
        text: TextSpan(
          text: '↓',
          style: TextStyle(
            fontSize: arrowSize,
            height: 1.0,
            color: Colors.white.withOpacity(arrowOpacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      canvas.save();
      canvas.translate(arrowCenter.dx, arrowCenter.dy);
      canvas.scale(1.0, arrowScaleY);
      canvas.translate(-arrowCenter.dx, -arrowCenter.dy);
      arrowPainter.paint(
        canvas,
        Offset(arrowCenter.dx - arrowPainter.width / 2,
            arrowCenter.dy - arrowPainter.height / 2),
      );
      canvas.restore();
    }

    // Draw the emoji with dynamic size
    final tp = TextPainter(
      text: TextSpan(
          text: emoji, style: TextStyle(fontSize: emojiSize, height: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }
}

// =============================================================================
// TOOLTIP PAINTER (unchanged)
// =============================================================================

class _TooltipPainter extends CustomPainter {
  final double arrowCenterX;
  final String text;

  _TooltipPainter({required this.arrowCenterX, required this.text});

  @override
  void paint(Canvas canvas, Size size) {
    final double tooltipWidth = size.width;
    final double tooltipHeight = size.height;
    const double arrowSize = 8;

    final paint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.fill;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, tooltipWidth, tooltipHeight),
      const Radius.circular(8),
    );
    canvas.drawRRect(rrect, paint);

    final Path arrowPath = Path();
    arrowPath.moveTo(arrowCenterX - arrowSize, tooltipHeight);
    arrowPath.lineTo(arrowCenterX, tooltipHeight + arrowSize);
    arrowPath.lineTo(arrowCenterX + arrowSize, tooltipHeight);
    arrowPath.close();
    canvas.drawPath(arrowPath, paint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final textX = (tooltipWidth - textPainter.width) / 2;
    final textY = (tooltipHeight - textPainter.height) / 2;
    textPainter.paint(canvas, Offset(textX, textY));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// =============================================================================
// RATING BAR – avatar sits directly on the bar track, same as the emoji thumb
// =============================================================================

class RatingBar extends StatefulWidget {
  final double averageRating;
  final String reactionEmoji;
  final double initialThumbPosition;
  final ValueChanged<double>? onRatingUpdate;
  final ValueChanged<double> onRatingEnd;
  final bool? showGuidance;
  final bool hasUserRated;
  final double? userRating;
  final String? userProfilePhoto;

  const RatingBar({
    Key? key,
    required this.averageRating,
    required this.reactionEmoji,
    this.initialThumbPosition = 5.0,
    this.onRatingUpdate,
    required this.onRatingEnd,
    this.showGuidance,
    this.hasUserRated = false,
    this.userRating,
    this.userProfilePhoto,
  }) : super(key: key);

  @override
  State<RatingBar> createState() => _RatingBarState();
}

class _RatingBarState extends State<RatingBar> with TickerProviderStateMixin {
  bool _guidanceLoaded = false;
  bool _resolvedGuidance = false;
  bool _isTestGroup = false;
  bool get _effectiveShowGuidance => widget.showGuidance ?? _resolvedGuidance;

  double _currentRating = 5.0;
  bool _isDragging = false;

  bool _showTooltip = false;
  Timer? _tooltipTimer;

  late AnimationController _sliderEntranceController;
  late Animation<double> _sliderSlide;
  late Animation<double> _sliderFade;
  late AnimationController _pulseController;
  late Animation<double> _pulseScale;
  late AnimationController _nudgeController;
  late Animation<double> _nudgeRating;
  late Animation<double> _nudgeThumbPos;
  late AnimationController _arrowBounceController;
  late Animation<double> _arrowBounce;
  late AnimationController _nudgeGlowController;
  late Animation<double> _nudgeGlow;
  late AnimationController _iconWiggleController;
  late Animation<double> _iconWiggle;
  bool _isNudging = false;

  Color? _cachedSliderActiveColor;
  Color? _cachedSliderInactiveColor;
  ThemeProvider? _lastThemeProvider;

  static const double _nudgeStart = 5.0;
  static const double _nudgePeak = 8.5;
  bool get _shouldNudge =>
      !_isDragging && !_guidanceLoaded && _effectiveShowGuidance;

  void _showTooltipWithTimer() {
    if (!mounted) return;
    final bool shouldShow = widget.hasUserRated &&
        !_isDragging &&
        !_isNudging &&
        widget.averageRating >= 1.0;

    if (shouldShow) {
      setState(() => _showTooltip = true);
      _tooltipTimer?.cancel();
      _tooltipTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showTooltip = false);
      });
    } else {
      setState(() => _showTooltip = false);
      _tooltipTimer?.cancel();
    }
  }

  @override
  void initState() {
    super.initState();

    _currentRating = widget.hasUserRated
        ? widget.averageRating.clamp(1.0, 10.0)
        : widget.initialThumbPosition.clamp(1.0, 10.0);

    _sliderEntranceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _sliderSlide = Tween<double>(begin: 12.0, end: 0.0).animate(CurvedAnimation(
        parent: _sliderEntranceController, curve: Curves.easeOut));
    _sliderFade = CurvedAnimation(
        parent: _sliderEntranceController, curve: Curves.easeIn);

    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 120));
    _pulseScale = Tween<double>(begin: 1.0, end: 1.18).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));

    _nudgeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _nudgeRating = TweenSequence<double>([
      TweenSequenceItem(
          tween: ConstantTween<double>(_nudgeStart), weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(begin: _nudgeStart, end: _nudgePeak)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(begin: _nudgePeak, end: _nudgeStart)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: ConstantTween<double>(_nudgeStart), weight: 38.9),
    ]).animate(_nudgeController);
    _nudgeThumbPos = TweenSequence<double>([
      TweenSequenceItem(
          tween: ConstantTween<double>(_ratingToNorm(_nudgeStart)),
          weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(
                  begin: _ratingToNorm(_nudgeStart),
                  end: _ratingToNorm(_nudgePeak))
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(
                  begin: _ratingToNorm(_nudgePeak),
                  end: _ratingToNorm(_nudgeStart))
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: ConstantTween<double>(_ratingToNorm(_nudgeStart)),
          weight: 38.9),
    ]).animate(_nudgeController);
    _nudgeController.addListener(() {
      if (_isNudging && mounted && !_isDragging)
        setState(() => _currentRating = _nudgeRating.value);
    });

    _arrowBounceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500))
      ..repeat(reverse: true);
    _arrowBounce = Tween<double>(begin: 0.0, end: 10.0).animate(CurvedAnimation(
        parent: _arrowBounceController, curve: Curves.easeInOut));

    _nudgeGlowController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _nudgeGlow = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _nudgeGlowController, curve: Curves.easeInOut));

    _iconWiggleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _iconWiggle = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 16.7),
      TweenSequenceItem(
          tween: Tween<double>(begin: 0.0, end: 5.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(
          tween: Tween<double>(begin: 5.0, end: 0.0)
              .chain(CurveTween(curve: Curves.easeInOut)),
          weight: 22.2),
      TweenSequenceItem(tween: ConstantTween<double>(0.0), weight: 38.9),
    ]).animate(_iconWiggleController);

    _sliderEntranceController.forward().then((_) {
      if (mounted) _loadGuidanceFlag();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showTooltipWithTimer();
    });
  }

  Future<void> _loadGuidanceFlag() async {
    if (widget.showGuidance != null) {
      setState(() => _guidanceLoaded = true);
      if (!_isDragging && _effectiveShowGuidance) _startNudge();
      return;
    }
    try {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      if (user == null) return;
      final supabase = Supabase.instance.client;
      final userRow = await supabase
          .from('users')
          .select('test')
          .eq('uid', user.uid)
          .maybeSingle();
      final bool isTestGroup = userRow?['test'] ?? true;
      final int threshold = isTestGroup ? 3 : 1;
      final ratingsRes = await supabase
          .from('post_rating')
          .select('userid')
          .eq('userid', user.uid);
      final int ratingCount = (ratingsRes as List).length;
      if (!mounted) return;
      final bool shouldShow = ratingCount < threshold;
      setState(() {
        _isTestGroup = isTestGroup;
        _resolvedGuidance = shouldShow;
        _guidanceLoaded = true;
      });
      if (!_isDragging && _effectiveShowGuidance) _startNudge();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isTestGroup = true;
          _resolvedGuidance = true;
          _guidanceLoaded = true;
        });
        if (!_isDragging && _effectiveShowGuidance) _startNudge();
      }
    }
  }

  double _ratingToNorm(double rating) => (rating - 1) / 9.0;

  void _startNudge() {
    if (_isDragging || !mounted || !_effectiveShowGuidance) return;
    setState(() {
      _isNudging = true;
      _currentRating = _nudgeStart;
    });
    _nudgeGlowController.repeat(reverse: true);
    _nudgeController.repeat();
    _iconWiggleController.repeat();
  }

  void _stopNudge() {
    _nudgeController.stop();
    _nudgeGlowController.stop();
    _iconWiggleController.stop();
    _nudgeGlowController.animateTo(0.0,
        duration: const Duration(milliseconds: 150));
    if (mounted) setState(() => _isNudging = false);
  }

  @override
  void didUpdateWidget(covariant RatingBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.averageRating != oldWidget.averageRating && !_isDragging) {
      if (widget.hasUserRated) {
        setState(() => _currentRating = widget.averageRating.clamp(1.0, 10.0));
      }
      _showTooltipWithTimer();
    }

    if (widget.hasUserRated != oldWidget.hasUserRated) {
      if (widget.hasUserRated) {
        setState(() => _currentRating = widget.averageRating.clamp(1.0, 10.0));
      } else {
        setState(() => _currentRating = 5.0);
      }
      _showTooltipWithTimer();
    }
  }

  void _onRatingChanged(double newRating) {
    if (_isNudging) _stopNudge();
    if (_currentRating != newRating) {
      setState(() {
        _currentRating = newRating;
        _isDragging = true;
      });
    } else if (!_isDragging) {
      setState(() => _isDragging = true);
    }
    widget.onRatingUpdate?.call(newRating);
    _pulseController.forward(from: 0.0).then((_) => _pulseController.reverse());
  }

  void _onRatingEnd(double rating) {
    setState(() => _isDragging = false);
    widget.onRatingEnd(rating);
  }

  void _updateCachedColors(ThemeProvider themeProvider) {
    if (_lastThemeProvider != themeProvider) {
      _lastThemeProvider = themeProvider;
      final isDark = themeProvider.themeMode == ThemeMode.dark;
      _cachedSliderActiveColor =
          isDark ? const Color(0xFFd9d9d9) : Colors.black;
      _cachedSliderInactiveColor =
          isDark ? const Color(0xFF333333) : Colors.grey[400]!;
    }
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    _sliderEntranceController.dispose();
    _pulseController.dispose();
    _nudgeController.dispose();
    _arrowBounceController.dispose();
    _nudgeGlowController.dispose();
    _iconWiggleController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Avatar helper – positioned relative to the Slider widget (48 dp tall).
  // Track centre is at 24 dp. Avatar is 32 dp → top = 24 - 16 = 8 dp.
  // This is the exact same vertical centre the emoji thumb is painted at.
  // ---------------------------------------------------------------------------
  Widget _buildUserReactionAvatar({
    required BoxConstraints constraints,
    required double thumbHalfWidth,
    required double trackWidth,
    required double userRating,
    required String photoUrl,
  }) {
    final double userT = (userRating - 1) / 9.0;
    final double userCenterX = thumbHalfWidth + userT * trackWidth;
    const double avatarSize = 32.0;

    // Slider height = kMinInteractiveDimension = 48 dp.
    // Track runs through vertical centre at 24 dp.
    // Centre a 32 dp circle on the track: top = 24 - 32/2 = 8.
    const double top = 8.0;

    double leftPos = (userCenterX - avatarSize / 2)
        .clamp(0.0, constraints.maxWidth - avatarSize);

    return Positioned(
      left: leftPos,
      top: top,
      child: IgnorePointer(
        // Let slider gestures pass through the avatar
        child: Container(
          width: avatarSize,
          height: avatarSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ClipOval(
            child: CachedNetworkImage(
              imageUrl: photoUrl,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) =>
                  const Icon(Icons.person, size: 32, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    _updateCachedColors(themeProvider);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sliderEntranceController,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _sliderSlide.value),
            child: Opacity(
                opacity: _sliderFade.value.clamp(0.0, 1.0), child: child),
          );
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double t = (_currentRating - 1) / 9.0;

            // thumbHalfWidth must match _EmojiThumbShape.getPreferredSize
            // = baseSize * maxScale / 2 = 30 * 1.5 / 2 = 22.5
            const double thumbHalfWidth = 30.0 * 1.5 / 2;
            final double trackWidth = constraints.maxWidth - 2 * thumbHalfWidth;
            final double thumbCenterX = thumbHalfWidth + t * trackWidth;

            final bool effectiveShowTooltip = _showTooltip &&
                !_isDragging &&
                !_isNudging &&
                widget.hasUserRated &&
                widget.averageRating >= 1.0;

            const double tooltipWidth = 110;
            const double tooltipHeight = 32;
            final double left = (thumbCenterX - tooltipWidth / 2)
                .clamp(8.0, constraints.maxWidth - tooltipWidth - 8.0);
            final double arrowCenterX =
                (thumbCenterX - left).clamp(12.0, tooltipWidth - 12.0);

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── "Slide to rate" nudge label ──────────────────────
                      AnimatedOpacity(
                        opacity: _isNudging ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Padding(
                          padding:
                              const EdgeInsets.only(left: 4.0, bottom: 6.0),
                          child: AnimatedBuilder(
                            animation: _nudgeGlow,
                            builder: (context, _) {
                              final glow = _nudgeGlow.value;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.white
                                      .withOpacity(0.9 + 0.1 * glow),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                        color: Colors.white
                                            .withOpacity(0.35 * glow),
                                        blurRadius: 10,
                                        spreadRadius: 1)
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      margin:
                                          const EdgeInsets.only(right: 7),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black
                                            .withOpacity(0.5 + 0.5 * glow),
                                        boxShadow: [
                                          BoxShadow(
                                              color: Colors.black
                                                  .withOpacity(0.2 * glow),
                                              blurRadius: 4,
                                              spreadRadius: 1)
                                        ],
                                      ),
                                    ),
                                    Text(
                                      'Slide to react',
                                      style: TextStyle(
                                        color: Colors.black
                                            .withOpacity(0.75 + 0.25 * glow),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        fontFamily: 'Inter',
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),

                      // ── Slider + avatar in their own Stack ───────────────
                      // The avatar Stack is scoped to just the Slider widget
                      // (48 dp tall) so top=8 always lands on the track line.
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              thumbShape: _EmojiThumbShape(
                                emoji: widget.reactionEmoji,
                                baseSize: 30.0,
                                showArrow:
                                    _isNudging && _effectiveShowGuidance,
                                arrowBounce: _arrowBounce.value,
                                arrowOpacity: (_isNudging &&
                                        _effectiveShowGuidance)
                                    ? 0.6 + 0.4 * _nudgeGlow.value
                                    : 0.0,
                              ),
                              overlayShape:
                                  SliderComponentShape.noOverlay,
                              trackHeight: 3.0,
                              activeTrackColor: _isNudging
                                  ? (_cachedSliderActiveColor ??
                                          Colors.white)
                                      .withOpacity(0.85)
                                  : _cachedSliderActiveColor,
                              inactiveTrackColor:
                                  _cachedSliderInactiveColor,
                            ),
                            child: Container(
                              decoration: _isNudging
                                  ? BoxDecoration(
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                            color: Colors.white.withOpacity(
                                                0.07 * _nudgeGlow.value),
                                            blurRadius: 12,
                                            spreadRadius: 2)
                                      ],
                                    )
                                  : const BoxDecoration(),
                              child: Slider(
                                value: _isNudging
                                    ? _nudgeRating.value.clamp(1.0, 10.0)
                                    : _currentRating,
                                min: 1,
                                max: 10,
                                divisions: 100,
                                activeColor: _isNudging
                                    ? (_cachedSliderActiveColor ??
                                            Colors.white)
                                        .withOpacity(0.85)
                                    : _cachedSliderActiveColor,
                                inactiveColor: _cachedSliderInactiveColor,
                                onChanged: _onRatingChanged,
                                onChangeEnd: _onRatingEnd,
                              ),
                            ),
                          ),

                          // Avatar rendered inside the Slider's Stack so its
                          // coordinate space is always the 48 dp slider height.
                          if (widget.userRating != null &&
                              widget.userProfilePhoto != null &&
                              widget.userProfilePhoto!.isNotEmpty)
                            _buildUserReactionAvatar(
                              constraints: constraints,
                              thumbHalfWidth: thumbHalfWidth,
                              trackWidth: trackWidth,
                              userRating: widget.userRating!,
                              photoUrl: widget.userProfilePhoto!,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Tooltip stays in the outer Stack so it floats above the bar
                if (effectiveShowTooltip)
                  Positioned(
                    left: left,
                    bottom: 65,
                    child: AnimatedOpacity(
                      opacity: _showTooltip ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: SizedBox(
                        width: tooltipWidth,
                        height: tooltipHeight,
                        child: CustomPaint(
                          painter: _TooltipPainter(
                            arrowCenterX: arrowCenterX,
                            text: 'Average Reaction',
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
