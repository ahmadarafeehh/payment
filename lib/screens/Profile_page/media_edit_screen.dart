// lib/screens/Profile_page/media_edit_screen.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:Ratedly/screens/Profile_page/add_post_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';

enum _Tab { text, filters, adjust, crop, blur, draw, rotate }

class MediaEditScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final VoidCallback? onPostUploaded;

  /// If provided, called with the final rendered bytes instead of pushing
  /// [AddPostScreen]. Used by the profile-picture editing flow.
  final ValueChanged<Uint8List>? onResult;

  const MediaEditScreen({
    Key? key,
    required this.imageBytes,
    this.onPostUploaded,
    this.onResult,
  }) : super(key: key);

  @override
  State<MediaEditScreen> createState() => _MediaEditScreenState();
}

class _MediaEditScreenState extends State<MediaEditScreen> {
  final GlobalKey _previewKey = GlobalKey();

  late Uint8List _editBytes;

  int _filterIndex = 0;
  EditAdjustments _adj = const EditAdjustments();

  Rect _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
  CropAspect _cropAspect = CropAspect.free;
  int _imgW = 1;
  int _imgH = 1;
  bool _cropApplied = false;

  BlurType _blurType = BlurType.none;
  double _blurIntensity = 8.0;

  final List<DrawStroke> _strokes = [];
  DrawStroke? _currentStroke;
  DrawTool _drawTool = DrawTool.brush;
  Color _drawColor = Colors.white;
  double _drawSize = 8.0;
  bool _isDrawing = false;

  final List<TextOverlay> _overlays = [];
  int? _selectedOverlayIndex;
  bool _isTyping = false;
  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  Color _tColor = Colors.white;
  double _tSize = 32.0;
  bool _tBold = true;
  int _tFont = 0;

  bool _isDragging = false;
  int? _dragIndex;
  bool _isOverTrash = false;

  int _rotationQuarters = 0;

  _Tab _activeTab = _Tab.filters;
  bool _isRendering = false;

  static const double _topBarH = 56.0;
  static const double _tabBarH = 48.0;
  static const double _panelH = 108.0;

  @override
  void initState() {
    super.initState();
    _editBytes = widget.imageBytes;
    _loadImageDimensions();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _loadImageDimensions() async {
    try {
      final codec = await ui.instantiateImageCodec(_editBytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _imgW = frame.image.width;
          _imgH = frame.image.height;
        });
        frame.image.dispose();
      }
    } catch (_) {}
  }

  List<double> get _matrix =>
      _adj.combinedMatrix(kFilters[_filterIndex].matrix);

  void _snapCropToAspect(CropAspect aspect) {
    setState(() => _cropAspect = aspect);
    final ratio = aspect.ratio;
    if (ratio == null) {
      setState(() => _cropRect = const Rect.fromLTRB(0, 0, 1, 1));
      return;
    }
    final iw = _imgW.toDouble();
    final ih = _imgH.toDouble();
    final imageRatio = iw / ih;
    double left, top, right, bottom;
    if (imageRatio >= ratio) {
      final cropW = ih * ratio;
      left = ((iw - cropW) / 2) / iw;
      right = 1.0 - left;
      top = 0.0;
      bottom = 1.0;
    } else {
      final cropH = iw / ratio;
      top = ((ih - cropH) / 2) / ih;
      bottom = 1.0 - top;
      left = 0.0;
      right = 1.0;
    }
    setState(() => _cropRect = Rect.fromLTRB(left, top, right, bottom));
  }

  void _rotate() =>
      setState(() => _rotationQuarters = (_rotationQuarters + 1) % 4);

  Uint8List _applyCropEager(Uint8List bytes, Rect cropRect) {
    var decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final iw = decoded.width.toDouble();
    final ih = decoded.height.toDouble();
    final x = (cropRect.left * iw).round().clamp(0, decoded.width - 1);
    final y = (cropRect.top * ih).round().clamp(0, decoded.height - 1);
    final w = (cropRect.width * iw).round().clamp(1, decoded.width - x);
    final h = (cropRect.height * ih).round().clamp(1, decoded.height - y);
    decoded = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
    return Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
  }

  Future<void> _confirmCrop() async {
    final isFull = _cropRect == const Rect.fromLTRB(0, 0, 1, 1);
    if (isFull) {
      setState(() {
        _cropApplied = false;
        _activeTab = _Tab.filters;
      });
      return;
    }
    final cropped = _applyCropEager(_editBytes, _cropRect);
    setState(() {
      _editBytes = cropped;
      _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
      _cropAspect = CropAspect.free;
      _cropApplied = true;
      _activeTab = _Tab.filters;
    });
    await _loadImageDimensions();
  }

  void _resetCrop() {
    setState(() {
      _cropRect = const Rect.fromLTRB(0, 0, 1, 1);
      _cropAspect = CropAspect.free;
      _cropApplied = false;
    });
  }

  void _enterTextMode() {
    _textCtrl.clear();
    setState(() {
      _isTyping = true;
      _tColor = Colors.white;
      _tSize = 32;
      _tBold = true;
      _tFont = 0;
    });
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _confirmText() {
    final text = _textCtrl.text.trim();
    if (text.isNotEmpty) {
      setState(() => _overlays.add(TextOverlay(
            text: text,
            position: const Offset(0.5, 0.45),
            color: _tColor,
            fontSize: _tSize,
            isBold: _tBold,
            fontIndex: _tFont,
          )));
    }
    _textCtrl.clear();
    _textFocus.unfocus();
    setState(() => _isTyping = false);
  }

  void _cancelText() {
    _textCtrl.clear();
    _textFocus.unfocus();
    setState(() => _isTyping = false);
  }

  bool _overTrash(Offset pos, double h) => pos.dy * h >= h - kTrashZoneH;

  void _onDragStart(int i) => setState(() {
        _isDragging = true;
        _dragIndex = i;
        _selectedOverlayIndex = i;
        _isOverTrash = false;
      });

  void _onDragUpdate(int i, DragUpdateDetails d, double w, double h) {
    final o = _overlays[i];
    final p = Offset(
      (o.position.dx + d.delta.dx / w).clamp(0.0, 0.9),
      (o.position.dy + d.delta.dy / h).clamp(0.0, 0.99),
    );
    setState(() {
      _overlays[i] = o.copyWith(position: p);
      _isOverTrash = _overTrash(p, h);
    });
  }

  void _onDragEnd(int i, double h) {
    final del = _overTrash(_overlays[i].position, h);
    setState(() {
      _isDragging = false;
      _dragIndex = null;
      _isOverTrash = false;
      if (del) {
        _overlays.removeAt(i);
        _selectedOverlayIndex = null;
      }
    });
  }

  void _onDrawStart(DragStartDetails d) {
    if (_activeTab != _Tab.draw) return;
    setState(() {
      _isDrawing = true;
      _currentStroke = DrawStroke(
        points: [d.localPosition],
        color: _drawColor,
        strokeWidth: _drawSize,
        tool: _drawTool,
      );
    });
  }

  void _onDrawUpdate(DragUpdateDetails d) {
    if (!_isDrawing || _currentStroke == null) return;
    setState(() {
      _currentStroke = DrawStroke(
        points: [..._currentStroke!.points, d.localPosition],
        color: _currentStroke!.color,
        strokeWidth: _currentStroke!.strokeWidth,
        tool: _currentStroke!.tool,
      );
    });
  }

  void _onDrawEnd(DragEndDetails _) {
    if (_currentStroke != null) {
      setState(() {
        _strokes.add(_currentStroke!);
        _currentStroke = null;
        _isDrawing = false;
      });
    }
  }

  Future<Uint8List> _renderFinalImage() async {
    setState(() {
      _isRendering = true;
      _selectedOverlayIndex = null;
      _isDrawing = false;
    });
    await Future.delayed(const Duration(milliseconds: 120));
    try {
      final boundary = _previewKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final uiImage = await boundary.toImage(
          pixelRatio: MediaQuery.of(context).devicePixelRatio);
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();
      final decoded = img.decodePng(pngBytes);
      return decoded != null
          ? Uint8List.fromList(img.encodeJpg(decoded, quality: 92))
          : pngBytes;
    } finally {
      if (mounted) setState(() => _isRendering = false);
    }
  }

  /// Called when the user taps "Next".
  ///
  /// • Profile flow  (`onResult` is set)  — calls the callback and pops.
  /// • Post flow     (`onResult` is null) — pushes [AddPostScreen].
  Future<void> _onNext() async {
    try {
      final rendered = await _renderFinalImage();
      if (!mounted) return;

      if (widget.onResult != null) {
        // ── Profile flow ──────────────────────────────────────────────
        widget.onResult!(rendered);
        Navigator.pop(context);
      } else {
        // ── Post flow ─────────────────────────────────────────────────
        Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AddPostScreen(
                  initialFile: rendered, onPostUploaded: widget.onPostUploaded),
            ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to process image.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    final imageH =
        screenSize.height - topPad - _topBarH - _tabBarH - _panelH - botPad - 8;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: Stack(children: [
        Column(children: [
          SizedBox(height: topPad),

          // ── Top bar ───────────────────────────────────────────────────
          SizedBox(
            height: _topBarH,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.arrow_back_ios_new,
                              color: Colors.white, size: 20))),
                  const Text('Edit',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                  GestureDetector(
                      onTap: _isRendering ? null : _onNext,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20)),
                          child: _isRendering
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.black, strokeWidth: 2))
                              : Text(
                                  // Show "Done" instead of "Next" in profile flow.
                                  widget.onResult != null ? 'Done' : 'Next',
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700)))),
                ],
              ),
            ),
          ),

          // ── Image area ────────────────────────────────────────────────
          SizedBox(
            height: imageH,
            child: Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: _activeTab != _Tab.draw
                      ? () => setState(() => _selectedOverlayIndex = null)
                      : null,
                  onPanStart: _activeTab == _Tab.draw ? _onDrawStart : null,
                  onPanUpdate: _activeTab == _Tab.draw ? _onDrawUpdate : null,
                  onPanEnd: _activeTab == _Tab.draw ? _onDrawEnd : null,
                  child: RepaintBoundary(
                    key: _previewKey,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Container(color: Colors.black),
                        ),
                        Positioned.fill(
                          child: ColorFiltered(
                            colorFilter: ColorFilter.matrix(_matrix),
                            child: Transform.rotate(
                                angle: _rotationQuarters * 3.14159265 / 2,
                                child: Image.memory(_editBytes,
                                    fit: BoxFit.contain,
                                    width: double.infinity,
                                    height: double.infinity)),
                          ),
                        ),
                        if (_blurType != BlurType.none)
                          Positioned.fill(
                              child: BlurOverlay(
                            imageBytes: _editBytes,
                            blurType: _blurType,
                            blurIntensity: _blurIntensity,
                          )),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: DrawingPainter(
                              strokes: _strokes,
                              currentStroke: _currentStroke,
                            ),
                          ),
                        ),
                        ..._overlays.asMap().entries.map((entry) {
                          final index = entry.key;
                          final o = entry.value;
                          final draggingThis = _dragIndex == index;
                          return Positioned(
                            left: (o.position.dx * screenSize.width)
                                .clamp(0, screenSize.width - 10),
                            top: (o.position.dy * imageH).clamp(0, imageH - 10),
                            child: GestureDetector(
                              onTap: _activeTab != _Tab.draw
                                  ? () => setState(
                                      () => _selectedOverlayIndex = index)
                                  : null,
                              onPanStart: _activeTab != _Tab.draw
                                  ? (_) => _onDragStart(index)
                                  : null,
                              onPanUpdate: _activeTab != _Tab.draw
                                  ? (d) => _onDragUpdate(
                                      index, d, screenSize.width, imageH)
                                  : null,
                              onPanEnd: _activeTab != _Tab.draw
                                  ? (_) => _onDragEnd(index, imageH)
                                  : null,
                              child: AnimatedOpacity(
                                opacity:
                                    (draggingThis && _isOverTrash) ? 0.4 : 1.0,
                                duration: const Duration(milliseconds: 100),
                                child:
                                    Stack(clipBehavior: Clip.none, children: [
                                  Text(o.text, style: overlayShadowStyle(o)),
                                  Text(o.text, style: overlayTextStyle(o)),
                                ]),
                              ),
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),
                ),
              ),
              if (_activeTab == _Tab.crop)
                Positioned.fill(
                  child: InteractiveCropOverlay(
                    cropRect: _cropRect,
                    onChanged: (r) {
                      setState(() {
                        _cropRect = r;
                        _cropAspect = CropAspect.free;
                      });
                    },
                  ),
                ),
              if (_activeTab == _Tab.crop)
                Positioned(
                  bottom: 16,
                  left: 24,
                  right: 24,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: _resetCrop,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.28),
                                width: 1),
                          ),
                          child: const Text('Reset',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500)),
                        ),
                      ),
                      GestureDetector(
                        onTap: _confirmCrop,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: const Text('Done',
                              style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_activeTab == _Tab.draw)
                Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                        child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(16)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                            width: _drawSize.clamp(6, 24),
                            height: _drawSize.clamp(6, 24),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _drawColor,
                                border: Border.all(
                                    color: Colors.white.withOpacity(0.5),
                                    width: 1))),
                        const SizedBox(width: 8),
                        Text(_drawTool.label,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.8),
                                fontSize: 12)),
                      ]),
                    ))),
              if (_isDragging)
                Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: TrashZone(isOverTrash: _isOverTrash)),
            ]),
          ),

          _buildTabBar(),

          Container(height: _panelH, color: Colors.black, child: _buildPanel()),

          SizedBox(height: botPad),
        ]),
        if (_isTyping)
          Positioned.fill(
              child: TextEntryOverlay(
            controller: _textCtrl,
            focusNode: _textFocus,
            textColor: _tColor,
            fontSize: _tSize,
            isBold: _tBold,
            fontIndex: _tFont,
            onColorChanged: (c) => setState(() => _tColor = c),
            onSizeChanged: (v) => setState(() => _tSize = v),
            onBoldToggle: () => setState(() => _tBold = !_tBold),
            onFontChanged: (i) => setState(() => _tFont = i),
            onConfirm: _confirmText,
            onCancel: _cancelText,
            topPadding: topPad,
          )),
      ]),
    );
  }

  Widget _buildTabBar() => Container(
        height: _tabBarH,
        color: const Color(0xFF111111),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _Tab.values.map((tab) {
              final isActive = _activeTab == tab;
              return GestureDetector(
                onTap: () {
                  if (tab == _Tab.text) {
                    _enterTextMode();
                    return;
                  }
                  if (tab == _Tab.rotate) {
                    _rotate();
                    return;
                  }
                  setState(() {
                    _activeTab = tab;
                    _isDrawing = false;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  color: Colors.transparent,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(clipBehavior: Clip.none, children: [
                        Icon(_tabIcon(tab),
                            color: isActive
                                ? Colors.white
                                : Colors.white.withOpacity(0.4),
                            size: 18),
                        if (tab == _Tab.crop && _cropApplied && !isActive)
                          Positioned(
                            top: -2,
                            right: -4,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle, color: Colors.white),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 2),
                      Text(_tabLabel(tab),
                          style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : Colors.white.withOpacity(0.4),
                              fontSize: 9,
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.normal)),
                      if (isActive)
                        Container(
                            margin: const EdgeInsets.only(top: 2),
                            height: 2,
                            width: 14,
                            decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(1))),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      );

  Widget _buildPanel() {
    switch (_activeTab) {
      case _Tab.filters:
        return FilterStrip(
          selectedIndex: _filterIndex,
          previewImage: _editBytes,
          onSelect: (i) => setState(() => _filterIndex = i),
        );
      case _Tab.adjust:
        return AdjustPanel(
          adjustments: _adj,
          onChanged: (a) => setState(() => _adj = a),
        );
      case _Tab.crop:
        return SnapCropPanel(
          selected: _cropAspect,
          onSnapToAspect: _snapCropToAspect,
        );
      case _Tab.blur:
        return BlurPanel(
          selected: _blurType,
          intensity: _blurIntensity,
          onSelectType: (t) => setState(() => _blurType = t),
          onIntensityChanged: (v) => setState(() => _blurIntensity = v),
        );
      case _Tab.draw:
        return DrawPanel(
          tool: _drawTool,
          color: _drawColor,
          strokeWidth: _drawSize,
          onUndo: () => setState(() {
            if (_strokes.isNotEmpty) _strokes.removeLast();
          }),
          onClear: () => setState(() => _strokes.clear()),
          onToolChanged: (t) => setState(() => _drawTool = t),
          onColorChanged: (c) => setState(() => _drawColor = c),
          onSizeChanged: (v) => setState(() => _drawSize = v),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  IconData _tabIcon(_Tab t) {
    switch (t) {
      case _Tab.filters:
        return Icons.auto_fix_high_rounded;
      case _Tab.adjust:
        return Icons.tune_rounded;
      case _Tab.crop:
        return Icons.crop_rounded;
      case _Tab.blur:
        return Icons.blur_on_rounded;
      case _Tab.draw:
        return Icons.brush_rounded;
      case _Tab.text:
        return Icons.text_fields_rounded;
      case _Tab.rotate:
        return Icons.rotate_90_degrees_cw_rounded;
    }
  }

  String _tabLabel(_Tab t) {
    switch (t) {
      case _Tab.filters:
        return 'Filters';
      case _Tab.adjust:
        return 'Adjust';
      case _Tab.crop:
        return 'Crop';
      case _Tab.blur:
        return 'Blur';
      case _Tab.draw:
        return 'Draw';
      case _Tab.text:
        return 'Text';
      case _Tab.rotate:
        return 'Rotate';
    }
  }
}
