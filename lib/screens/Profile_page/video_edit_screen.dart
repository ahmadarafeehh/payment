// lib/screens/Profile_page/video_edit_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_trimmer/video_trimmer.dart';
import 'package:Ratedly/screens/Profile_page/add_post_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';

enum _Tool { trim, filters, adjust, draw, text, rotate }

// =============================================================================
// VIDEO EDIT RESULT
// =============================================================================

class VideoEditResult {
  final File videoFile;
  final int filterIndex;
  final EditAdjustments adjustments;
  final List<DrawStroke> strokes;
  final List<TextOverlay> overlays;
  final int rotationQuarters;

  const VideoEditResult({
    required this.videoFile,
    required this.filterIndex,
    required this.adjustments,
    required this.strokes,
    required this.overlays,
    required this.rotationQuarters,
  });

  // ── Serialization ──────────────────────────────────────────────────────────
  /// Converts every edit parameter to a plain JSON-safe map.
  /// The [videoFile] path is NOT included — callers store the uploaded URL
  /// separately. Use [fromJson] + a locally cached file to reconstruct.
  Map<String, dynamic> toJson() => {
        'filterIndex': filterIndex,
        'rotationQuarters': rotationQuarters,
        'adjustments': adjustments.toJson(),
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'overlays': overlays.map((o) => o.toJson()).toList(),
      };

  /// Reconstructs a [VideoEditResult] from the JSON previously produced by
  /// [toJson]. Pass the locally cached [videoFile] separately.
  factory VideoEditResult.fromJson(
    Map<String, dynamic> json,
    File videoFile,
  ) =>
      VideoEditResult(
        videoFile: videoFile,
        filterIndex: json['filterIndex'] as int? ?? 0,
        rotationQuarters: json['rotationQuarters'] as int? ?? 0,
        adjustments: EditAdjustments.fromJson(
          (json['adjustments'] as Map<String, dynamic>?) ?? {},
        ),
        strokes: ((json['strokes'] as List?) ?? [])
            .map((s) => DrawStroke.fromJson(s as Map<String, dynamic>))
            .toList(),
        overlays: ((json['overlays'] as List?) ?? [])
            .map((o) => TextOverlay.fromJson(o as Map<String, dynamic>))
            .toList(),
      );
}

// =============================================================================
// SCREEN
// =============================================================================

class VideoEditScreen extends StatefulWidget {
  final File videoFile;
  final VoidCallback? onPostUploaded;

  /// If provided, called with the [VideoEditResult] instead of pushing
  /// [AddPostScreen]. Used by the profile-video editing flow.
  final ValueChanged<VideoEditResult>? onResult;

  const VideoEditScreen({
    Key? key,
    required this.videoFile,
    this.onPostUploaded,
    this.onResult,
  }) : super(key: key);

  @override
  State<VideoEditScreen> createState() => _VideoEditScreenState();
}

class _VideoEditScreenState extends State<VideoEditScreen> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isPlaying = false;

  late File _activeVideoFile;

  final Trimmer _trimmer = Trimmer();
  double _startValue = 0.0;
  double _endValue = 0.0;
  bool _isTrimPlaying = false;
  bool _isSavingTrimInline = false;
  // Always start dirty so the Save button is enabled immediately.
  bool _trimDirty = true;
  bool _trimApplied = false;

  bool _isProcessing = false;

  _Tool _activeTool = _Tool.trim;

  int _selectedFilterIndex = 0;
  EditAdjustments _adj = const EditAdjustments();

  final GlobalKey _overlayKey = GlobalKey();
  final List<DrawStroke> _strokes = [];
  DrawStroke? _currentStroke;
  DrawTool _drawTool = DrawTool.brush;
  Color _drawColor = Colors.white;
  double _drawSize = 8.0;
  bool _isDrawing = false;

  bool _isTyping = false;
  final List<TextOverlay> _overlays = [];
  int? _selectedOverlayIndex;
  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  Color _tColor = Colors.white;
  double _tSize = 32.0;
  bool _tBold = true;
  int _tFont = 0;

  int _rotationQuarters = 0;

  bool _isDragging = false;
  int? _dragIndex;
  bool _isOverTrash = false;

  static const double _topBarH = 56.0;
  static const double _panelH = 212.0;

  // ── Per-flow trim cap ─────────────────────────────────────────────────────
  bool get _isProfileFlow => widget.onResult != null;
  double get _maxTrimMs => _isProfileFlow ? 5000.0 : 15000.0;
  Duration get _maxTrimDuration => Duration(milliseconds: _maxTrimMs.toInt());

  // ── Selected-duration label ───────────────────────────────────────────────
  String get _selectedDurationLabel {
    final ms = (_endValue - _startValue).clamp(0.0, _maxTrimMs);
    final secs = ms / 1000.0;
    return 'Selected: ${secs.toStringAsFixed(1)}s';
  }

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _activeVideoFile = widget.videoFile;
    WidgetsBinding.instance.addPostFrameCallback((_) => _logBoot());
    _initPreviewPlayer();
    _trimmer.loadVideo(videoFile: widget.videoFile);
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _trimmer.dispose();
    _textCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _logBoot() async {
    try {
      final sz = MediaQuery.of(context).size;
      final tp = MediaQuery.of(context).padding.top;
      final bp = MediaQuery.of(context).padding.bottom;
      final videoH = sz.height - tp - _topBarH - _panelH - bp;
      final fileExists = widget.videoFile.existsSync();
      await Supabase.instance.client.from('posts_errors').insert({
        'operation_type': 'video_edit/boot',
        'additional_data': {
          'screenW': sz.width,
          'screenH': sz.height,
          'topPad': tp,
          'botPad': bp,
          'computedVideoH': videoH,
          'videoHNegative': videoH <= 0,
          'filePath': widget.videoFile.path,
          'fileExists': fileExists,
          'fileSizeBytes': fileExists ? widget.videoFile.lengthSync() : 0,
          'isProfileFlow': _isProfileFlow,
          'maxTrimSeconds': _maxTrimDuration.inSeconds,
        },
      });
    } catch (_) {}
  }

  Future<void> _initPreviewPlayer() async {
    try {
      final c = VideoPlayerController.file(
        widget.videoFile,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await c.initialize();
      await c.setLooping(true);
      if (mounted) {
        setState(() {
          _videoController = c;
          _isVideoInitialized = true;
          _isPlaying = false;
        });
      }
    } catch (e, st) {
      await _log(
        operation: 'video_edit/player_init_error',
        errorMessage: e.toString(),
        stackTrace: st.toString(),
        data: {'filePath': widget.videoFile.path},
      );
    }
  }

  // ===========================================================================
  // TOOL SELECTION
  // ===========================================================================

  void _reloadTrimmer() {
    _trimmer.loadVideo(videoFile: _activeVideoFile);
    if (mounted) setState(() => _isTrimPlaying = false);
  }

  Future<void> _onToolTap(_Tool tool) async {
    if (tool == _Tool.text) {
      _enterTextMode();
      return;
    }
    if (tool == _Tool.rotate) {
      setState(() => _rotationQuarters = (_rotationQuarters + 1) % 4);
      return;
    }

    final wasTrim = _activeTool == _Tool.trim;
    final goingTrim = tool == _Tool.trim;

    if (goingTrim && !wasTrim) {
      await _videoController?.pause();
      if (mounted) setState(() => _isPlaying = false);
      _reloadTrimmer();
    }

    if (!goingTrim && wasTrim) {
      if (_isTrimPlaying) {
        try {
          await _trimmer.videoPlaybackControl(
              startValue: _startValue, endValue: _endValue);
        } catch (_) {}
        if (mounted) setState(() => _isTrimPlaying = false);
      }
      await _videoController?.play();
      if (mounted) {
        setState(() => _isPlaying = _videoController?.value.isPlaying ?? false);
      }
    }

    setState(() {
      _activeTool =
          (tool == _activeTool && tool != _Tool.trim) ? _Tool.trim : tool;
      _isDrawing = false;
    });
  }

  // ===========================================================================
  // PLAY / PAUSE
  // ===========================================================================

  Future<void> _togglePlayPause() async {
    if (_videoController == null || !_isVideoInitialized) return;
    if (_isPlaying) {
      await _videoController!.pause();
    } else {
      await _videoController!.play();
    }
    if (mounted) setState(() => _isPlaying = _videoController!.value.isPlaying);
  }

  Future<void> _silenceAndStop() async {
    await _videoController?.pause();
    if (mounted) setState(() => _isPlaying = false);
  }

  // ===========================================================================
  // SAVE TRIM
  // ===========================================================================

  Future<void> _saveTrim() async {
    if (!_trimDirty) return;
    if (mounted) setState(() => _isSavingTrimInline = true);

    await _log(operation: 'trim/save_start', data: {
      'startValue': _startValue,
      'endValue': _endValue,
      'activeFilePath': _activeVideoFile.path,
      'maxTrimMs': _maxTrimMs,
    });

    File? trimmedFile;
    try {
      final completer = Completer<String?>();
      await _trimmer.saveTrimmedVideo(
        startValue: _startValue,
        endValue: _endValue,
        onSave: (String? path) {
          if (!completer.isCompleted) completer.complete(path);
        },
      );
      final savedPath = await completer.future
          .timeout(const Duration(seconds: 30), onTimeout: () => null);

      if (savedPath != null) {
        final f = File(savedPath);
        final exists = f.existsSync();
        final bytes = exists ? f.lengthSync() : 0;
        await _log(operation: 'trim/saved_inline', data: {
          'savedPath': savedPath,
          'exists': exists,
          'sizeBytes': bytes,
        });
        if (exists && bytes > 0) trimmedFile = f;
      }
    } catch (e, st) {
      await _log(
          operation: 'trim/save_inline_error',
          errorMessage: e.toString(),
          stackTrace: st.toString());
    }

    if (!mounted) return;

    if (trimmedFile != null) {
      setState(() => _activeVideoFile = trimmedFile!);
      final old = _videoController;
      setState(() {
        _isVideoInitialized = false;
        _isPlaying = false;
      });
      old?.dispose();

      try {
        final c = VideoPlayerController.file(
          trimmedFile,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
        await c.initialize();
        await c.setLooping(true);
        if (mounted) {
          setState(() {
            _videoController = c;
            _isVideoInitialized = true;
            _isPlaying = false;
            _trimDirty = false;
            _trimApplied = true;
            _startValue = 0.0;
            _endValue = 0.0;
            _activeTool = _Tool.filters;
          });
          _trimmer.loadVideo(videoFile: trimmedFile);
          c.play();
          if (mounted) setState(() => _isPlaying = true);
        }
      } catch (e, st) {
        await _log(
            operation: 'trim/reinit_error',
            errorMessage: e.toString(),
            stackTrace: st.toString());
      }
    }

    if (mounted) setState(() => _isSavingTrimInline = false);
  }

  // ===========================================================================
  // DRAW
  // ===========================================================================

  void _onDrawStart(DragStartDetails d) {
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

  // ===========================================================================
  // TEXT
  // ===========================================================================

  void _enterTextMode() {
    _textCtrl.clear();
    setState(() {
      _isTyping = true;
      _tColor = Colors.white;
      _tSize = 32.0;
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

  // ===========================================================================
  // DRAG-TO-TRASH
  // ===========================================================================

  bool _overTrash(Offset pos, double h) => pos.dy * h >= h - kTrashZoneH;

  void _onTextDragStart(int i) => setState(() {
        _isDragging = true;
        _dragIndex = i;
        _selectedOverlayIndex = i;
        _isOverTrash = false;
      });

  void _onTextDragUpdate(int i, DragUpdateDetails d, double w, double h) {
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

  void _onTextDragEnd(int i, double h) {
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

  // ===========================================================================
  // LOGGING
  // ===========================================================================

  Future<void> _log({
    required String operation,
    String? errorMessage,
    String? stackTrace,
    Map<String, dynamic>? data,
  }) async {
    try {
      await Supabase.instance.client.from('posts_errors').insert({
        'operation_type': operation,
        'error_message': errorMessage,
        'stack_trace': stackTrace,
        'additional_data': data,
      });
    } catch (_) {}
  }

  // ===========================================================================
  // NEXT — builds VideoEditResult and navigates
  // ===========================================================================

  Future<void> _onNext() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    // Flush any unsaved trim first so _activeVideoFile is up to date.
    if (_trimDirty) {
      await _saveTrim();
      if (!mounted) return;
    }

    await _silenceAndStop();
    if (!mounted) return;

    try {
      // Build the complete, serialisable result. Every edit parameter is
      // captured here; toJson() round-trips it for Supabase storage so that
      // other clients can reconstruct the same visual output on playback.
      final result = VideoEditResult(
        videoFile: _activeVideoFile,
        filterIndex: _selectedFilterIndex,
        adjustments: _adj,
        strokes: List.unmodifiable(_strokes),
        overlays: List.unmodifiable(_overlays),
        rotationQuarters: _rotationQuarters,
      );

      if (widget.onResult != null) {
        // Profile flow — hand result back to caller.
        widget.onResult!(result);
        if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
      } else {
        // Post flow — forward to AddPostScreen which will upload the file
        // AND the serialised edit metadata together.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddPostScreen(
              initialVideoFile: result.videoFile,
              editResult: result,
              onPostUploaded: widget.onPostUploaded,
            ),
          ),
        );
      }
    } catch (e, st) {
      await _log(
          operation: 'next/error',
          errorMessage: e.toString(),
          stackTrace: st.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Failed to process video. Please try again.')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  List<double> get _currentMatrix =>
      _adj.combinedMatrix(kFilters[_selectedFilterIndex].matrix);

  @override
  Widget build(BuildContext context) {
    try {
      return _buildBody(context);
    } catch (e, st) {
      unawaited(_log(
        operation: 'video_edit/build_exception',
        errorMessage: e.toString(),
        stackTrace: st.toString(),
      ));
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'Something went wrong.\n${e.toString()}',
            style: const TextStyle(color: Colors.white, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
  }

  Widget _buildBody(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    final videoH = (screenSize.height - topPad - _topBarH - _panelH - botPad)
        .clamp(120.0, double.infinity);

    final isTrim = _activeTool == _Tool.trim;
    final isDrawActive = _activeTool == _Tool.draw;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: Stack(children: [
        Column(children: [
          SizedBox(height: topPad),
          _buildTopBar(),
          SizedBox(
            height: videoH,
            child: Stack(children: [
              Positioned.fill(
                child: IndexedStack(
                  index: isTrim ? 0 : 1,
                  children: [
                    // ── Trim viewer ────────────────────────────────────
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        try {
                          final p = await _trimmer.videoPlaybackControl(
                              startValue: _startValue, endValue: _endValue);
                          if (mounted) setState(() => _isTrimPlaying = p);
                        } catch (_) {}
                      },
                      child: Container(
                        color: Colors.black,
                        child: Stack(children: [
                          VideoViewer(trimmer: _trimmer),
                          if (!_isTrimPlaying)
                            const Center(
                              child: Icon(Icons.play_circle_outline,
                                  color: Colors.white54, size: 64),
                            ),
                        ]),
                      ),
                    ),

                    // ── Preview with colour filter + rotation ──────────
                    SizedBox.expand(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: isDrawActive
                            ? null
                            : () {
                                setState(() => _selectedOverlayIndex = null);
                                _togglePlayPause();
                              },
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix(_currentMatrix),
                          child: Transform.rotate(
                            angle: _rotationQuarters * 3.14159265 / 2,
                            child: _isVideoInitialized &&
                                    _videoController != null
                                ? Center(
                                    child: AspectRatio(
                                      aspectRatio:
                                          _videoController!.value.aspectRatio,
                                      child: VideoPlayer(_videoController!),
                                    ),
                                  )
                                : const Center(
                                    child: CircularProgressIndicator(
                                        color: Colors.white)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Overlay layer (strokes + text) ───────────────────────
              if (!isTrim)
                Positioned.fill(
                  child: RepaintBoundary(
                    key: _overlayKey,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: DrawingPainter(
                                strokes: _strokes,
                                currentStroke: _currentStroke,
                              ),
                            ),
                          ),
                        ),
                        ..._buildTextOverlays(screenSize.width, videoH),
                      ],
                    ),
                  ),
                ),

              // ── Draw capture layer ───────────────────────────────────
              if (!isTrim && isDrawActive)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _onDrawStart,
                    onPanUpdate: _onDrawUpdate,
                    onPanEnd: _onDrawEnd,
                    child: const SizedBox.expand(),
                  ),
                ),

              // ── Play icon when paused ────────────────────────────────
              if (!isTrim && !isDrawActive && !_isPlaying)
                const Center(
                    child: Icon(Icons.play_circle_outline,
                        color: Colors.white54, size: 64)),

              // ── Draw tool indicator ──────────────────────────────────
              if (isDrawActive)
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
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: _drawSize.clamp(6, 24),
                          height: _drawSize.clamp(6, 24),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _drawColor,
                            border: Border.all(
                                color: Colors.white.withOpacity(0.5), width: 1),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _drawTool.label,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 12),
                        ),
                      ]),
                    ),
                  ),
                ),

              // ── Trash zone during drag ───────────────────────────────
              if (_isDragging)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: TrashZone(isOverTrash: _isOverTrash),
                ),
            ]),
          ),

          // ── Tool panel ───────────────────────────────────────────────
          Container(
            height: _panelH,
            color: Colors.black,
            child: _buildPanel(),
          ),
          SizedBox(height: botPad),
        ]),

        // ── Text entry full-screen overlay ───────────────────────────────
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
            ),
          ),
      ]),
    );
  }

  // ===========================================================================
  // TOP BAR
  // ===========================================================================

  Widget _buildTopBar() => SizedBox(
        height: _topBarH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () async {
                  await _silenceAndStop();
                  if (mounted) Navigator.pop(context);
                },
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.arrow_back_ios_new,
                      color: Colors.white, size: 20),
                ),
              ),
              Text(
                _isProfileFlow ? 'Edit Profile Video' : 'Edit Video',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
              GestureDetector(
                onTap: _isProcessing ? null : _onNext,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: _isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2),
                        )
                      : Text(
                          _isProfileFlow ? 'Done' : 'Next',
                          style: const TextStyle(
                              color: Colors.black,
                              fontSize: 14,
                              fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ),
      );

  // ===========================================================================
  // PANEL
  // ===========================================================================

  Widget _buildPanel() {
    return Column(children: [
      SizedBox(
        height: 86,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          children: _Tool.values
              .where((t) => !(t == _Tool.trim && _trimApplied))
              .map((tool) {
            final isActive = _activeTool == tool;
            final showBadge = tool == _Tool.trim && _trimApplied && !isActive;

            return GestureDetector(
              onTap: () => _onToolTap(tool),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 7),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Stack(clipBehavior: Clip.none, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isActive
                            ? Colors.white.withOpacity(0.18)
                            : Colors.white.withOpacity(0.07),
                        border: Border.all(
                          color: isActive
                              ? Colors.white
                              : Colors.white.withOpacity(0.16),
                          width: isActive ? 1.5 : 1.0,
                        ),
                      ),
                      child: Icon(
                        _toolIcon(tool),
                        color: isActive
                            ? Colors.white
                            : Colors.white.withOpacity(0.6),
                        size: 22,
                      ),
                    ),
                    if (showBadge)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(
                                color: Colors.black.withOpacity(0.4), width: 1),
                          ),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 5),
                  Text(
                    _toolLabel(tool),
                    style: TextStyle(
                      color: isActive
                          ? Colors.white
                          : Colors.white.withOpacity(0.48),
                      fontSize: 10,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ]),
              ),
            );
          }).toList(),
        ),
      ),
      Divider(color: Colors.white.withOpacity(0.07), height: 1),
      Expanded(child: _buildToolDetail()),
    ]);
  }

  Widget _buildToolDetail() {
    switch (_activeTool) {
      case _Tool.trim:
        return _buildTrimDetail();
      case _Tool.filters:
        return FilterStrip(
          selectedIndex: _selectedFilterIndex,
          previewImage: null,
          onSelect: (i) => setState(() => _selectedFilterIndex = i),
        );
      case _Tool.adjust:
        return AdjustPanel(
          adjustments: _adj,
          onChanged: (a) => setState(() => _adj = a),
        );
      case _Tool.draw:
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
        return Center(
          child: Text(
            'Select a tool above',
            style:
                TextStyle(color: Colors.white.withOpacity(0.22), fontSize: 13),
          ),
        );
    }
  }

  // ===========================================================================
  // TRIM DETAIL
  // ===========================================================================

  Widget _buildTrimDetail() {
    return SingleChildScrollView(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Max clip: ${_maxTrimDuration.inSeconds}s',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.38),
                      fontSize: 11,
                    ),
                  ),
                  if (_trimDirty && _endValue > _startValue) ...[
                    const SizedBox(height: 2),
                    Text(
                      _selectedDurationLabel,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
              GestureDetector(
                onTap: _isSavingTrimInline ? null : _saveTrim,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: _isSavingTrimInline
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 2),
                        )
                      : const Text(
                          'Save',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
          child: TrimViewer(
            trimmer: _trimmer,
            viewerHeight: 70,
            viewerWidth: MediaQuery.of(context).size.width - 16,
            maxVideoLength: _maxTrimDuration,
            editorProperties: TrimEditorProperties(
              circleSize: 12,
              borderWidth: 4,
              scrubberWidth: 2,
              sideTapSize: 24,
              circlePaintColor: Colors.white,
              borderPaintColor: Colors.white,
              scrubberPaintColor: Colors.white,
            ),
            onChangeStart: (v) {
              _startValue = v;
              if (_endValue - _startValue > _maxTrimMs) {
                _endValue = _startValue + _maxTrimMs;
              }
              _trimDirty = true;
            },
            onChangeEnd: (v) {
              _endValue =
                  v > _startValue + _maxTrimMs ? _startValue + _maxTrimMs : v;
              _trimDirty = true;
            },
            onChangePlaybackState: (p) {
              if (mounted) setState(() => _isTrimPlaying = p);
            },
          ),
        ),
      ]),
    );
  }

  // ===========================================================================
  // TEXT OVERLAYS
  // ===========================================================================

  List<Widget> _buildTextOverlays(double w, double h) {
    return _overlays.asMap().entries.map((entry) {
      final index = entry.key;
      final o = entry.value;
      final draggingThis = _dragIndex == index;
      final isDraw = _activeTool == _Tool.draw;
      return Positioned(
        left: (o.position.dx * w).clamp(0.0, w - 10),
        top: (o.position.dy * h).clamp(0.0, h - 10),
        child: GestureDetector(
          onTap: isDraw
              ? null
              : () => setState(() => _selectedOverlayIndex = index),
          onPanStart: isDraw ? null : (_) => _onTextDragStart(index),
          onPanUpdate: isDraw ? null : (d) => _onTextDragUpdate(index, d, w, h),
          onPanEnd: isDraw ? null : (_) => _onTextDragEnd(index, h),
          child: AnimatedOpacity(
            opacity: (draggingThis && _isOverTrash) ? 0.4 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: Stack(clipBehavior: Clip.none, children: [
              Text(o.text, style: overlayShadowStyle(o)),
              Text(o.text, style: overlayTextStyle(o)),
            ]),
          ),
        ),
      );
    }).toList();
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  IconData _toolIcon(_Tool t) {
    switch (t) {
      case _Tool.trim:
        return Icons.content_cut_rounded;
      case _Tool.filters:
        return Icons.auto_fix_high_rounded;
      case _Tool.adjust:
        return Icons.tune_rounded;
      case _Tool.draw:
        return Icons.brush_rounded;
      case _Tool.text:
        return Icons.text_fields_rounded;
      case _Tool.rotate:
        return Icons.rotate_90_degrees_cw_rounded;
    }
  }

  String _toolLabel(_Tool t) {
    switch (t) {
      case _Tool.trim:
        return 'Trim';
      case _Tool.filters:
        return 'Filters';
      case _Tool.adjust:
        return 'Adjust';
      case _Tool.draw:
        return 'Draw';
      case _Tool.text:
        return 'Text';
      case _Tool.rotate:
        return 'Rotate';
    }
  }
}
