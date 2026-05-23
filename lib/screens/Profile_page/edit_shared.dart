// lib/screens/Profile_page/edit_shared.dart
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

// =============================================================================
// CONSTANTS
// =============================================================================

const double kTrashZoneH = 80.0;

// =============================================================================
// FILTERS
// =============================================================================

class FilterDef {
  final String name;
  final List<double> matrix;
  const FilterDef({required this.name, required this.matrix});
}

const List<double> _identity = [
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

const List<FilterDef> kFilters = [
  FilterDef(name: 'Normal', matrix: _identity),
  FilterDef(name: 'Vivid', matrix: [
    1.4,
    0,
    0,
    0,
    -20,
    0,
    1.4,
    0,
    0,
    -20,
    0,
    0,
    1.4,
    0,
    -20,
    0,
    0,
    0,
    1,
    0,
  ]),
  FilterDef(name: 'Matte', matrix: [
    0.9,
    0,
    0,
    0,
    18,
    0,
    0.9,
    0,
    0,
    18,
    0,
    0,
    0.9,
    0,
    18,
    0,
    0,
    0,
    1,
    0,
  ]),
  FilterDef(name: 'B&W', matrix: [
    0.33,
    0.59,
    0.11,
    0,
    0,
    0.33,
    0.59,
    0.11,
    0,
    0,
    0.33,
    0.59,
    0.11,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  FilterDef(name: 'Cool', matrix: [
    0.9,
    0,
    0,
    0,
    0,
    0,
    0.95,
    0,
    0,
    0,
    0,
    0,
    1.2,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  FilterDef(name: 'Warm', matrix: [
    1.2,
    0,
    0,
    0,
    0,
    0,
    1.0,
    0,
    0,
    0,
    0,
    0,
    0.8,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]),
  FilterDef(name: 'Fade', matrix: [
    0.8,
    0,
    0,
    0,
    30,
    0,
    0.8,
    0,
    0,
    30,
    0,
    0,
    0.8,
    0,
    30,
    0,
    0,
    0,
    1,
    0,
  ]),
];

// =============================================================================
// ADJUSTMENTS
// =============================================================================

class EditAdjustments {
  final double brightness; // -1.0 … 1.0
  final double contrast; // -1.0 … 1.0
  final double saturation; // -1.0 … 1.0
  final double warmth; // -1.0 … 1.0
  final double fade; //  0.0 … 1.0

  const EditAdjustments({
    this.brightness = 0.0,
    this.contrast = 0.0,
    this.saturation = 0.0,
    this.warmth = 0.0,
    this.fade = 0.0,
  });

  EditAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? warmth,
    double? fade,
  }) =>
      EditAdjustments(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        fade: fade ?? this.fade,
      );

  List<double> combinedMatrix(List<double> filterMatrix) {
    List<double> m = List<double>.from(filterMatrix);

    if (brightness != 0.0) {
      final double b = brightness * 100;
      m = _multiplyMatrices(m, [
        1,
        0,
        0,
        0,
        b,
        0,
        1,
        0,
        0,
        b,
        0,
        0,
        1,
        0,
        b,
        0,
        0,
        0,
        1,
        0,
      ]);
    }

    if (contrast != 0.0) {
      final double c = contrast + 1.0;
      final double t = 128 * (1 - c);
      m = _multiplyMatrices(m, [
        c,
        0,
        0,
        0,
        t,
        0,
        c,
        0,
        0,
        t,
        0,
        0,
        c,
        0,
        t,
        0,
        0,
        0,
        1,
        0,
      ]);
    }

    if (saturation != 0.0) {
      final double s = saturation + 1.0;
      const double wr = 0.299, wg = 0.587, wb = 0.114;
      m = _multiplyMatrices(m, [
        wr + (1 - wr) * s,
        wg * (s - 1),
        wb * (s - 1),
        0,
        0,
        wr * (s - 1),
        wg + (1 - wg) * s,
        wb * (s - 1),
        0,
        0,
        wr * (s - 1),
        wg * (s - 1),
        wb + (1 - wb) * s,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]);
    }

    if (warmth != 0.0) {
      final double w = warmth * 30;
      m = _multiplyMatrices(m, [
        1,
        0,
        0,
        0,
        w,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        -w,
        0,
        0,
        0,
        1,
        0,
      ]);
    }

    if (fade != 0.0) {
      final double f = 1.0 - fade * 0.4;
      final double offset = fade * 40;
      m = _multiplyMatrices(m, [
        f,
        0,
        0,
        0,
        offset,
        0,
        f,
        0,
        0,
        offset,
        0,
        0,
        f,
        0,
        offset,
        0,
        0,
        0,
        1,
        0,
      ]);
    }

    return m;
  }

  static List<double> _multiplyMatrices(List<double> a, List<double> b) {
    final List<double> r = List<double>.filled(20, 0);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        double v = 0;
        for (int k = 0; k < 4; k++) {
          v += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) v += a[row * 5 + 4];
        r[row * 5 + col] = v;
      }
    }
    return r;
  }

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'warmth': warmth,
        'fade': fade,
      };

  factory EditAdjustments.fromJson(Map<String, dynamic> json) =>
      EditAdjustments(
        brightness: (json['brightness'] as num? ?? 0).toDouble(),
        contrast: (json['contrast'] as num? ?? 0).toDouble(),
        saturation: (json['saturation'] as num? ?? 0).toDouble(),
        warmth: (json['warmth'] as num? ?? 0).toDouble(),
        fade: (json['fade'] as num? ?? 0).toDouble(),
      );
}

// =============================================================================
// CROP ASPECT
// =============================================================================

enum CropAspect { free, square, fourFive, nineSixteen, sixteenNine, threeTwo }

extension CropAspectExt on CropAspect {
  String get label {
    switch (this) {
      case CropAspect.free:
        return 'Free';
      case CropAspect.square:
        return '1:1';
      case CropAspect.fourFive:
        return '4:5';
      case CropAspect.nineSixteen:
        return '9:16';
      case CropAspect.sixteenNine:
        return '16:9';
      case CropAspect.threeTwo:
        return '3:2';
    }
  }

  /// Returns the target width/height ratio, or null for free.
  double? get ratio {
    switch (this) {
      case CropAspect.free:
        return null;
      case CropAspect.square:
        return 1.0;
      case CropAspect.fourFive:
        return 4 / 5;
      case CropAspect.nineSixteen:
        return 9 / 16;
      case CropAspect.sixteenNine:
        return 16 / 9;
      case CropAspect.threeTwo:
        return 3 / 2;
    }
  }
}

// =============================================================================
// INTERACTIVE CROP OVERLAY
// =============================================================================

enum _CropHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  topEdge,
  bottomEdge,
  leftEdge,
  rightEdge,
  interior,
  none,
}

class InteractiveCropOverlay extends StatefulWidget {
  final Rect cropRect;
  final ValueChanged<Rect> onChanged;

  const InteractiveCropOverlay({
    Key? key,
    required this.cropRect,
    required this.onChanged,
  }) : super(key: key);

  @override
  State<InteractiveCropOverlay> createState() => _InteractiveCropOverlayState();
}

class _InteractiveCropOverlayState extends State<InteractiveCropOverlay> {
  static const double _cornerHitR = 28.0;
  static const double _edgeHitW = 22.0;
  static const double _minNorm = 0.05;

  _CropHandle _active = _CropHandle.none;
  Offset? _lastPos;

  _CropHandle _hitTest(Offset local, Size sz) {
    final r = widget.cropRect;
    final left = r.left * sz.width;
    final right = r.right * sz.width;
    final top = r.top * sz.height;
    final bottom = r.bottom * sz.height;

    final tl = Offset(left, top);
    final tr = Offset(right, top);
    final bl = Offset(left, bottom);
    final br = Offset(right, bottom);

    if ((local - tl).distance < _cornerHitR) return _CropHandle.topLeft;
    if ((local - tr).distance < _cornerHitR) return _CropHandle.topRight;
    if ((local - bl).distance < _cornerHitR) return _CropHandle.bottomLeft;
    if ((local - br).distance < _cornerHitR) return _CropHandle.bottomRight;

    if ((local.dy - top).abs() < _edgeHitW &&
        local.dx > left &&
        local.dx < right) return _CropHandle.topEdge;
    if ((local.dy - bottom).abs() < _edgeHitW &&
        local.dx > left &&
        local.dx < right) return _CropHandle.bottomEdge;
    if ((local.dx - left).abs() < _edgeHitW &&
        local.dy > top &&
        local.dy < bottom) return _CropHandle.leftEdge;
    if ((local.dx - right).abs() < _edgeHitW &&
        local.dy > top &&
        local.dy < bottom) return _CropHandle.rightEdge;

    if (Rect.fromLTRB(left, top, right, bottom).contains(local))
      return _CropHandle.interior;
    return _CropHandle.none;
  }

  void _onPanStart(DragStartDetails d, Size sz) {
    _active = _hitTest(d.localPosition, sz);
    _lastPos = d.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails d, Size sz) {
    if (_active == _CropHandle.none || _lastPos == null) return;
    final raw = d.localPosition - _lastPos!;
    _lastPos = d.localPosition;
    final dx = raw.dx / sz.width;
    final dy = raw.dy / sz.height;
    final r = widget.cropRect;

    Rect next;
    switch (_active) {
      case _CropHandle.topLeft:
        next = Rect.fromLTRB((r.left + dx).clamp(0.0, r.right - _minNorm),
            (r.top + dy).clamp(0.0, r.bottom - _minNorm), r.right, r.bottom);
        break;
      case _CropHandle.topRight:
        next = Rect.fromLTRB(
            r.left,
            (r.top + dy).clamp(0.0, r.bottom - _minNorm),
            (r.right + dx).clamp(r.left + _minNorm, 1.0),
            r.bottom);
        break;
      case _CropHandle.bottomLeft:
        next = Rect.fromLTRB((r.left + dx).clamp(0.0, r.right - _minNorm),
            r.top, r.right, (r.bottom + dy).clamp(r.top + _minNorm, 1.0));
        break;
      case _CropHandle.bottomRight:
        next = Rect.fromLTRB(
            r.left,
            r.top,
            (r.right + dx).clamp(r.left + _minNorm, 1.0),
            (r.bottom + dy).clamp(r.top + _minNorm, 1.0));
        break;
      case _CropHandle.topEdge:
        next = Rect.fromLTRB(r.left,
            (r.top + dy).clamp(0.0, r.bottom - _minNorm), r.right, r.bottom);
        break;
      case _CropHandle.bottomEdge:
        next = Rect.fromLTRB(r.left, r.top, r.right,
            (r.bottom + dy).clamp(r.top + _minNorm, 1.0));
        break;
      case _CropHandle.leftEdge:
        next = Rect.fromLTRB((r.left + dx).clamp(0.0, r.right - _minNorm),
            r.top, r.right, r.bottom);
        break;
      case _CropHandle.rightEdge:
        next = Rect.fromLTRB(r.left, r.top,
            (r.right + dx).clamp(r.left + _minNorm, 1.0), r.bottom);
        break;
      case _CropHandle.interior:
        final nl = (r.left + dx).clamp(0.0, 1.0 - r.width);
        final nt = (r.top + dy).clamp(0.0, 1.0 - r.height);
        next = Rect.fromLTWH(nl, nt, r.width, r.height);
        break;
      default:
        return;
    }
    widget.onChanged(next);
  }

  void _onPanEnd(DragEndDetails _) {
    _active = _CropHandle.none;
    _lastPos = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final sz = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _onPanStart(d, sz),
        onPanUpdate: (d) => _onPanUpdate(d, sz),
        onPanEnd: _onPanEnd,
        child: CustomPaint(
          size: sz,
          painter: _InteractiveCropPainter(cropRect: widget.cropRect),
        ),
      );
    });
  }
}

class _InteractiveCropPainter extends CustomPainter {
  final Rect cropRect;
  const _InteractiveCropPainter({required this.cropRect});

  @override
  void paint(Canvas canvas, Size size) {
    final left = cropRect.left * size.width;
    final top = cropRect.top * size.height;
    final right = cropRect.right * size.width;
    final bottom = cropRect.bottom * size.height;
    final pxRect = Rect.fromLTRB(left, top, right, bottom);

    // Dim outside
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRect(pxRect),
      ),
      Paint()..color = Colors.black.withOpacity(0.52),
    );

    // Border
    canvas.drawRect(
      pxRect,
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );

    // Rule-of-thirds grid
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.28)
      ..strokeWidth = 0.6;
    for (int i = 1; i < 3; i++) {
      final x = left + (pxRect.width / 3) * i;
      final y = top + (pxRect.height / 3) * i;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), gridPaint);
      canvas.drawLine(Offset(left, y), Offset(right, y), gridPaint);
    }

    // Corner handles
    const hl = 20.0;
    final hp = Paint()
      ..color = Colors.white
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(left, top + hl), Offset(left, top), hp);
    canvas.drawLine(Offset(left, top), Offset(left + hl, top), hp);
    canvas.drawLine(Offset(right - hl, top), Offset(right, top), hp);
    canvas.drawLine(Offset(right, top), Offset(right, top + hl), hp);
    canvas.drawLine(Offset(left, bottom - hl), Offset(left, bottom), hp);
    canvas.drawLine(Offset(left, bottom), Offset(left + hl, bottom), hp);
    canvas.drawLine(Offset(right - hl, bottom), Offset(right, bottom), hp);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - hl), hp);

    // Edge midpoint circles
    final edgeFill = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final edgeBorder = Paint()
      ..color = Colors.black.withOpacity(0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final pt in [
      Offset((left + right) / 2, top),
      Offset((left + right) / 2, bottom),
      Offset(left, (top + bottom) / 2),
      Offset(right, (top + bottom) / 2),
    ]) {
      canvas.drawCircle(pt, 4.0, edgeFill);
      canvas.drawCircle(pt, 4.0, edgeBorder);
    }
  }

  @override
  bool shouldRepaint(_InteractiveCropPainter old) => old.cropRect != cropRect;
}

// =============================================================================
// SNAP CROP PANEL
// =============================================================================

class SnapCropPanel extends StatelessWidget {
  final CropAspect selected;
  final ValueChanged<CropAspect> onSnapToAspect;

  const SnapCropPanel({
    Key? key,
    required this.selected,
    required this.onSnapToAspect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 100,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          children: CropAspect.values.map((a) {
            final isSel = selected == a;
            return GestureDetector(
              onTap: () => onSnapToAspect(a),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: isSel ? Colors.white : Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color:
                        isSel ? Colors.white : Colors.white.withOpacity(0.25),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  a.label,
                  style: TextStyle(
                    color: isSel ? Colors.black : Colors.white,
                    fontSize: 13,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
}

// =============================================================================
// BLUR
// =============================================================================

enum BlurType { none, portrait, tiltShift, radial, background }

extension BlurTypeExt on BlurType {
  String get label {
    switch (this) {
      case BlurType.none:
        return 'None';
      case BlurType.portrait:
        return 'Portrait';
      case BlurType.tiltShift:
        return 'Tilt-Shift';
      case BlurType.radial:
        return 'Radial';
      case BlurType.background:
        return 'Background';
    }
  }

  IconData get icon {
    switch (this) {
      case BlurType.none:
        return Icons.blur_off_rounded;
      case BlurType.portrait:
        return Icons.portrait_rounded;
      case BlurType.tiltShift:
        return Icons.swap_vert_rounded;
      case BlurType.radial:
        return Icons.radio_button_unchecked;
      case BlurType.background:
        return Icons.filter_tilt_shift_rounded;
    }
  }
}

// =============================================================================
// BLUR OVERLAY WIDGET
// =============================================================================

class BlurOverlay extends StatelessWidget {
  final Uint8List imageBytes;
  final BlurType blurType;
  final double blurIntensity;

  const BlurOverlay({
    Key? key,
    required this.imageBytes,
    required this.blurType,
    required this.blurIntensity,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (blurType == BlurType.none) return const SizedBox.shrink();

    final sigma = blurIntensity;
    final blurredFull = ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: Image.memory(imageBytes,
          fit: BoxFit.contain, width: double.infinity, height: double.infinity),
    );

    switch (blurType) {
      case BlurType.portrait:
      case BlurType.background:
        return LayoutBuilder(builder: (ctx, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(fit: StackFit.expand, children: [
            blurredFull,
            ClipPath(
              clipper: _OvalKeepClipper(w, h, 0.5, 0.75),
              child: Image.memory(imageBytes,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity),
            ),
          ]);
        });

      case BlurType.tiltShift:
        return LayoutBuilder(builder: (ctx, constraints) {
          final h = constraints.maxHeight;
          return Stack(fit: StackFit.expand, children: [
            blurredFull,
            ClipRect(
              clipper: _HorizontalBandClipper(h * 0.3, h * 0.7),
              child: Image.memory(imageBytes,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity),
            ),
          ]);
        });

      case BlurType.radial:
        return LayoutBuilder(builder: (ctx, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          return Stack(fit: StackFit.expand, children: [
            blurredFull,
            ClipPath(
              clipper: _CircleKeepClipper(w / 2, h / 2, (w < h ? w : h) * 0.3),
              child: Image.memory(imageBytes,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity),
            ),
          ]);
        });

      default:
        return const SizedBox.shrink();
    }
  }
}

class _OvalKeepClipper extends CustomClipper<Path> {
  final double w, h, rx, ry;
  _OvalKeepClipper(this.w, this.h, this.rx, this.ry);
  @override
  Path getClip(Size size) => Path()
    ..addOval(Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: size.width * rx,
        height: size.height * ry));
  @override
  bool shouldReclip(_) => false;
}

class _HorizontalBandClipper extends CustomClipper<Rect> {
  final double top, bottom;
  _HorizontalBandClipper(this.top, this.bottom);
  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, bottom);
  @override
  bool shouldReclip(_) => false;
}

class _CircleKeepClipper extends CustomClipper<Path> {
  final double cx, cy, radius;
  _CircleKeepClipper(this.cx, this.cy, this.radius);
  @override
  Path getClip(Size size) =>
      Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: radius));
  @override
  bool shouldReclip(_) => false;
}

// =============================================================================
// BLUR PANEL
// =============================================================================

class BlurPanel extends StatelessWidget {
  final BlurType selected;
  final double intensity;
  final ValueChanged<BlurType> onSelectType;
  final ValueChanged<double> onIntensityChanged;

  const BlurPanel({
    Key? key,
    required this.selected,
    required this.intensity,
    required this.onSelectType,
    required this.onIntensityChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 100,
        child: Column(children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: BlurType.values.map((t) {
                final isSel = selected == t;
                return GestureDetector(
                  onTap: () => onSelectType(t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color:
                          isSel ? Colors.white : Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: isSel
                              ? Colors.white
                              : Colors.white.withOpacity(0.2),
                          width: 1.5),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(t.icon,
                          size: 14,
                          color: isSel
                              ? Colors.black
                              : Colors.white.withOpacity(0.8)),
                      const SizedBox(width: 5),
                      Text(t.label,
                          style: TextStyle(
                            color: isSel ? Colors.black : Colors.white,
                            fontSize: 12,
                            fontWeight:
                                isSel ? FontWeight.w700 : FontWeight.w500,
                          )),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ),
          if (selected != BlurType.none)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 10),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white.withOpacity(0.25),
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withOpacity(0.15),
                ),
                child: Slider(
                  value: intensity,
                  min: 1,
                  max: 25,
                  onChanged: onIntensityChanged,
                ),
              ),
            ),
        ]),
      );
}

// =============================================================================
// DRAW
// =============================================================================

enum DrawTool { brush, eraser, arrow, line }

extension DrawToolLabel on DrawTool {
  String get label {
    switch (this) {
      case DrawTool.brush:
        return 'Brush';
      case DrawTool.eraser:
        return 'Eraser';
      case DrawTool.arrow:
        return 'Arrow';
      case DrawTool.line:
        return 'Line';
    }
  }
}

class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final DrawTool tool;

  const DrawStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    required this.tool,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => {'dx': p.dx, 'dy': p.dy}).toList(),
        'color': color.value,
        'strokeWidth': strokeWidth,
        'tool': tool.index,
      };

  factory DrawStroke.fromJson(Map<String, dynamic> json) => DrawStroke(
        points: (json['points'] as List)
            .map((p) => Offset(
                  (p['dx'] as num).toDouble(),
                  (p['dy'] as num).toDouble(),
                ))
            .toList(),
        color: Color(json['color'] as int),
        strokeWidth: (json['strokeWidth'] as num).toDouble(),
        tool: DrawTool.values[json['tool'] as int],
      );
}

// =============================================================================
// TEXT OVERLAY
// =============================================================================

const List<String> kOverlayFonts = [
  'Helvetica',
  'Georgia',
  'Courier',
  'Impact',
  'Arial',
];

class TextOverlay {
  final String text;
  final Offset position; // fractional [0,1] × [0,1]
  final Color color;
  final double fontSize;
  final bool isBold;
  final int fontIndex;

  const TextOverlay({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
    required this.isBold,
    required this.fontIndex,
  });

  TextOverlay copyWith({
    String? text,
    Offset? position,
    Color? color,
    double? fontSize,
    bool? isBold,
    int? fontIndex,
  }) =>
      TextOverlay(
        text: text ?? this.text,
        position: position ?? this.position,
        color: color ?? this.color,
        fontSize: fontSize ?? this.fontSize,
        isBold: isBold ?? this.isBold,
        fontIndex: fontIndex ?? this.fontIndex,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'dx': position.dx,
        'dy': position.dy,
        'color': color.value,
        'fontSize': fontSize,
        'isBold': isBold,
        'fontIndex': fontIndex,
      };

  factory TextOverlay.fromJson(Map<String, dynamic> json) => TextOverlay(
        text: json['text'] as String,
        position: Offset(
          (json['dx'] as num).toDouble(),
          (json['dy'] as num).toDouble(),
        ),
        color: Color(json['color'] as int),
        fontSize: (json['fontSize'] as num).toDouble(),
        isBold: json['isBold'] as bool,
        fontIndex: json['fontIndex'] as int,
      );
}

// =============================================================================
// TEXT STYLE HELPERS
// =============================================================================

TextStyle overlayTextStyle(TextOverlay o) => TextStyle(
      fontFamily: kOverlayFonts[o.fontIndex.clamp(0, kOverlayFonts.length - 1)],
      fontSize: o.fontSize,
      color: o.color,
      fontWeight: o.isBold ? FontWeight.bold : FontWeight.normal,
      height: 1.2,
    );

TextStyle overlayShadowStyle(TextOverlay o) => overlayTextStyle(o).copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.black.withOpacity(0.55),
    );

// =============================================================================
// DRAWING PAINTER
// =============================================================================

class DrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final DrawStroke? currentStroke;

  const DrawingPainter({required this.strokes, required this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in [
      ...strokes,
      if (currentStroke != null) currentStroke!,
    ]) {
      if (stroke.points.isEmpty) continue;

      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.strokeWidth
        ..style = PaintingStyle.stroke;

      if (stroke.tool == DrawTool.eraser) {
        paint
          ..color = Colors.black
          ..blendMode = BlendMode.clear;
      } else {
        paint.color = stroke.color;
      }

      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.strokeWidth / 2, paint);
        continue;
      }

      if (stroke.tool == DrawTool.line || stroke.tool == DrawTool.arrow) {
        canvas.drawLine(stroke.points.first, stroke.points.last, paint);
        if (stroke.tool == DrawTool.arrow) {
          _drawArrowHead(
              canvas, stroke.points.first, stroke.points.last, paint);
        }
        continue;
      }

      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (int i = 1; i < stroke.points.length - 1; i++) {
        final mid = Offset(
          (stroke.points[i].dx + stroke.points[i + 1].dx) / 2,
          (stroke.points[i].dy + stroke.points[i + 1].dy) / 2,
        );
        path.quadraticBezierTo(
            stroke.points[i].dx, stroke.points[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(stroke.points.last.dx, stroke.points.last.dy);
      canvas.drawPath(path, paint);
    }
  }

  void _drawArrowHead(Canvas c, Offset from, Offset to, Paint paint) {
    const double size = 16.0;
    final double angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - size * math.cos(angle - 0.4),
          to.dy - size * math.sin(angle - 0.4))
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - size * math.cos(angle + 0.4),
          to.dy - size * math.sin(angle + 0.4));
    c.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(DrawingPainter old) =>
      old.strokes != strokes || old.currentStroke != currentStroke;
}

// =============================================================================
// TRASH ZONE
// =============================================================================

class TrashZone extends StatelessWidget {
  final bool isOverTrash;
  const TrashZone({Key? key, required this.isOverTrash}) : super(key: key);

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: kTrashZoneH,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withOpacity(isOverTrash ? 0.85 : 0.6),
              Colors.transparent,
            ],
          ),
        ),
        child: Center(
          child: AnimatedScale(
            scale: isOverTrash ? 1.25 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.delete_rounded,
              color: isOverTrash ? Colors.red : Colors.white.withOpacity(0.7),
              size: 32,
            ),
          ),
        ),
      );
}

// =============================================================================
// FILTER STRIP
// =============================================================================

class FilterStrip extends StatelessWidget {
  final int selectedIndex;
  final Uint8List? previewImage;
  final ValueChanged<int> onSelect;

  const FilterStrip({
    Key? key,
    required this.selectedIndex,
    required this.previewImage,
    required this.onSelect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: kFilters.length,
      itemBuilder: (_, i) {
        final filter = kFilters[i];
        final selected = i == selectedIndex;
        return GestureDetector(
          onTap: () => onSelect(i),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? Colors.white
                          : Colors.white.withOpacity(0.18),
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: previewImage != null
                        ? ColorFiltered(
                            colorFilter: ColorFilter.matrix(filter.matrix),
                            child:
                                Image.memory(previewImage!, fit: BoxFit.cover),
                          )
                        : ColorFiltered(
                            colorFilter: ColorFilter.matrix(filter.matrix),
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(colors: [
                                  Color(0xFF888888),
                                  Color(0xFF444444),
                                ]),
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  filter.name,
                  style: TextStyle(
                    color: selected
                        ? Colors.white
                        : Colors.white.withOpacity(0.48),
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// ADJUST PANEL
// =============================================================================

class AdjustPanel extends StatelessWidget {
  final EditAdjustments adjustments;
  final ValueChanged<EditAdjustments> onChanged;

  const AdjustPanel({
    Key? key,
    required this.adjustments,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      children: [
        _Slider(
            label: 'Brightness',
            value: adjustments.brightness,
            onChanged: (v) => onChanged(adjustments.copyWith(brightness: v))),
        _Slider(
            label: 'Contrast',
            value: adjustments.contrast,
            onChanged: (v) => onChanged(adjustments.copyWith(contrast: v))),
        _Slider(
            label: 'Saturation',
            value: adjustments.saturation,
            onChanged: (v) => onChanged(adjustments.copyWith(saturation: v))),
        _Slider(
            label: 'Warmth',
            value: adjustments.warmth,
            onChanged: (v) => onChanged(adjustments.copyWith(warmth: v))),
        _Slider(
            label: 'Fade',
            value: adjustments.fade,
            min: 0.0,
            onChanged: (v) => onChanged(adjustments.copyWith(fade: v))),
      ],
    );
  }
}

class _Slider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final ValueChanged<double> onChanged;

  const _Slider({
    required this.label,
    required this.value,
    this.min = -1.0,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.7), fontSize: 12)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                  value: value, min: min, max: 1.0, onChanged: onChanged),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(value.toStringAsFixed(2),
                style: TextStyle(
                    color: Colors.white.withOpacity(0.45), fontSize: 10),
                textAlign: TextAlign.right),
          ),
        ]),
      );
}

// =============================================================================
// DRAW PANEL
// =============================================================================

class DrawPanel extends StatelessWidget {
  final DrawTool tool;
  final Color color;
  final double strokeWidth;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final ValueChanged<DrawTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onSizeChanged;

  const DrawPanel({
    Key? key,
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.onUndo,
    required this.onClear,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onSizeChanged,
  }) : super(key: key);

  static const List<Color> _palette = [
    Colors.white,
    Colors.black,
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.purple,
    Colors.pink,
  ];

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            ...DrawTool.values.map((t) {
              final active = t == tool;
              return GestureDetector(
                onTap: () => onToolChanged(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white.withOpacity(0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: active
                            ? Colors.white
                            : Colors.white.withOpacity(0.22)),
                  ),
                  child: Text(t.label,
                      style: TextStyle(
                        color: active
                            ? Colors.white
                            : Colors.white.withOpacity(0.5),
                        fontSize: 11,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.normal,
                      )),
                ),
              );
            }),
            const Spacer(),
            GestureDetector(
              onTap: onUndo,
              child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.undo_rounded,
                      color: Colors.white.withOpacity(0.7), size: 20)),
            ),
            GestureDetector(
              onTap: onClear,
              child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.delete_outline_rounded,
                      color: Colors.white.withOpacity(0.7), size: 20)),
            ),
          ]),
        ),
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: _palette.map((c) {
              final sel = c.value == color.value;
              return GestureDetector(
                onTap: () => onColorChanged(c),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: sel ? 32 : 28,
                  height: sel ? 32 : 28,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c,
                    border: Border.all(
                        color:
                            sel ? Colors.white : Colors.white.withOpacity(0.3),
                        width: sel ? 2.5 : 1),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Row(children: [
            Icon(Icons.brush_rounded,
                color: Colors.white.withOpacity(0.45), size: 14),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                    value: strokeWidth,
                    min: 2.0,
                    max: 30.0,
                    onChanged: onSizeChanged),
              ),
            ),
            Icon(Icons.brush_rounded,
                color: Colors.white.withOpacity(0.45), size: 22),
          ]),
        ),
      ]);
}

// =============================================================================
// TEXT ENTRY OVERLAY
// =============================================================================

class TextEntryOverlay extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Color textColor;
  final double fontSize;
  final bool isBold;
  final int fontIndex;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onSizeChanged;
  final VoidCallback onBoldToggle;
  final ValueChanged<int> onFontChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final double topPadding;

  const TextEntryOverlay({
    Key? key,
    required this.controller,
    required this.focusNode,
    required this.textColor,
    required this.fontSize,
    required this.isBold,
    required this.fontIndex,
    required this.onColorChanged,
    required this.onSizeChanged,
    required this.onBoldToggle,
    required this.onFontChanged,
    required this.onConfirm,
    required this.onCancel,
    required this.topPadding,
  }) : super(key: key);

  static const List<Color> _palette = [
    Colors.white,
    Colors.black,
    Colors.red,
    Colors.yellow,
    Colors.green,
    Colors.cyan,
    Colors.blue,
    Colors.pink,
    Colors.orange,
    Colors.purple,
  ];

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onCancel,
      child: Container(
        color: Colors.black.withOpacity(0.7),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                GestureDetector(
                  onTap: onCancel,
                  child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Cancel',
                          style: TextStyle(color: Colors.white, fontSize: 15))),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onConfirm,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20)),
                    child: const Text('Done',
                        style: TextStyle(
                            color: Colors.black,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                GestureDetector(
                  onTap: onBoldToggle,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isBold
                          ? Colors.white.withOpacity(0.2)
                          : Colors.transparent,
                      border: Border.all(
                          color: Colors.white.withOpacity(0.4), width: 1),
                    ),
                    child: const Center(
                        child: Text('B',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold))),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: kOverlayFonts.length,
                      itemBuilder: (_, i) {
                        final sel = i == fontIndex;
                        return GestureDetector(
                          onTap: () => onFontChanged(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: sel
                                  ? Colors.white.withOpacity(0.2)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                  color: Colors.white
                                      .withOpacity(sel ? 0.7 : 0.25)),
                            ),
                            child: Text(kOverlayFonts[i],
                                style: TextStyle(
                                  fontFamily: kOverlayFonts[i],
                                  color: sel
                                      ? Colors.white
                                      : Colors.white.withOpacity(0.5),
                                  fontSize: 12,
                                )),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 90,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                        value: fontSize,
                        min: 14.0,
                        max: 64.0,
                        onChanged: onSizeChanged),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () {},
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      style: TextStyle(
                        fontFamily: kOverlayFonts[fontIndex],
                        color: textColor,
                        fontSize: fontSize,
                        fontWeight:
                            isBold ? FontWeight.bold : FontWeight.normal,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Type something…',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                      maxLines: 4,
                      textAlign: TextAlign.center,
                      autofocus: true,
                      onSubmitted: (_) => onConfirm(),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 50,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: _palette.map((c) {
                  final sel = c.value == textColor.value;
                  return GestureDetector(
                    onTap: () => onColorChanged(c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: sel ? 32 : 28,
                      height: sel ? 32 : 28,
                      margin: EdgeInsets.symmetric(
                          horizontal: 4, vertical: sel ? 9 : 11),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: c,
                        border: Border.all(
                            color: sel
                                ? Colors.white
                                : Colors.white.withOpacity(0.3),
                            width: sel ? 2.5 : 1),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }
}
