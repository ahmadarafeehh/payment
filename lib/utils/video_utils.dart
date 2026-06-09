// lib/utils/video_utils.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:video_player/video_player.dart';

import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';

export 'package:Ratedly/screens/Profile_page/edit_shared.dart';
export 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';

// Add at the end of video_utils.dart:

// ---------------------------------------------------------------------------
// 1. Pure utility functions
// ---------------------------------------------------------------------------

/// Returns `true` if [url] looks like a video file (extension or path hint).
bool isVideoFile(String url) {
  if (url.isEmpty) return false;
  final l = url.toLowerCase();
  return l.endsWith('.mp4') ||
      l.endsWith('.mov') ||
      l.endsWith('.avi') ||
      l.endsWith('.wmv') ||
      l.endsWith('.flv') ||
      l.endsWith('.mkv') ||
      l.endsWith('.webm') ||
      l.endsWith('.m4v') ||
      l.endsWith('.3gp') ||
      l.contains('/video/') ||
      l.contains('video=true');
}

/// Deterministic 20% chance that a video post with the given [postId]
/// should be shown as a looping video player instead of a static thumbnail.
bool shouldShowVideoLoop(String postId) {
  if (postId.isEmpty) return false;
  final hash = postId.hashCode;
  return (hash % 100).abs() < 20;
}

// ---------------------------------------------------------------------------
// 2. Edit overlay / video‑edit helpers (pure functions)
// ---------------------------------------------------------------------------

/// Safely extracts a `Map<String, dynamic>` from a raw value that may
/// come from Supabase JSON fields.
Map<String, dynamic>? extractEditMetadata(dynamic raw) {
  if (raw == null) return null;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

/// Parses the `video_edit_metadata` field of a post into a [VideoEditResult].
VideoEditResult? parseEditResult(Map<String, dynamic> post) {
  final meta = extractEditMetadata(post['video_edit_metadata']);
  if (meta == null) return null;
  try {
    return VideoEditResult.fromJson(meta, File(''));
  } catch (_) {
    return null;
  }
}

/// Builds the 20‑element colour‑matrix for a [VideoEditResult].
/// Returns the identity matrix when `er` is null.
List<double> buildColorMatrix(VideoEditResult? er) {
  if (er == null) {
    return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
  }
  return er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix);
}

/// Builds the edit overlay layer (strokes + text overlays).
/// Requires [screenSize] (obtain via `MediaQuery.of(context).size`) and the
/// [constraints] from a `LayoutBuilder`.
Widget buildEditOverlayLayer({
  required VideoEditResult editResult,
  required BoxConstraints constraints,
  required Size screenSize,
}) {
  if (editResult.strokes.isEmpty && editResult.overlays.isEmpty) {
    return const SizedBox.shrink();
  }

  final double previewW = constraints.maxWidth;
  final double previewH = constraints.maxHeight;
  final double scaleX = previewW / screenSize.width;
  final double scaleY = previewH / screenSize.height;
  final double fontScale = math.min(scaleX, scaleY);

  return Stack(
    clipBehavior: Clip.hardEdge,
    children: [
      if (editResult.strokes.isNotEmpty)
        Positioned.fill(
          child: CustomPaint(
            painter: ScaledDrawingPainter(
              strokes: editResult.strokes,
              scaleX: scaleX,
              scaleY: scaleY,
            ),
          ),
        ),
      ...editResult.overlays.map((o) {
        final scaledOverlay = o.copyWith(fontSize: o.fontSize * fontScale);
        return Positioned(
          left: (o.position.dx * previewW).clamp(0.0, previewW - 10),
          top: (o.position.dy * previewH).clamp(0.0, previewH - 10),
          child: Stack(clipBehavior: Clip.none, children: [
            Text(o.text, style: overlayShadowStyle(scaledOverlay)),
            Text(o.text, style: overlayTextStyle(scaledOverlay)),
          ]),
        );
      }),
    ],
  );
}

// ---------------------------------------------------------------------------
// 3. ScaledDrawingPainter (used by the overlay layer)
// ---------------------------------------------------------------------------

class ScaledDrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final double scaleX;
  final double scaleY;

  const ScaledDrawingPainter({
    required this.strokes,
    required this.scaleX,
    required this.scaleY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scaleX, scaleY);
    DrawingPainter(strokes: strokes, currentStroke: null)
        .paint(canvas, Size(size.width / scaleX, size.height / scaleY));
    canvas.restore();
  }

  @override
  bool shouldRepaint(ScaledDrawingPainter old) =>
      old.strokes != strokes || old.scaleX != scaleX || old.scaleY != scaleY;
}

// ---------------------------------------------------------------------------
// 4. VideoMediaService – thumbnail cache + loop‑controller management
// ---------------------------------------------------------------------------

/// A single service that handles both video‑thumbnail extraction/caching
/// and the management of [VideoPlayerController] instances for the 20%
/// of videos that should loop.
///
/// Usage:
/// ```dart
/// final service = VideoMediaService();
/// service.onRebuild = () { if (mounted) setState(() {}); };
/// service.preloadMedia(posts);
/// ```
class VideoMediaService {
  // ── Thumbnail cache ─────────────────────────────────────────────
  final Map<String, Uint8List?> _thumbnailCache = {};
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  // ── Looping video controllers ───────────────────────────────────
  final Map<String, VideoPlayerController> _controllers = {};
  final Map<String, bool> _controllersInitialized = {};
  Timer? _initDebounce;

  /// Assign a callback that the service calls when a controller
  /// initialisation finishes (via a small debounce). You can wire it
  /// to `setState` in your screen:
  /// `service.onRebuild = () { if (mounted) setState(() {}); };`
  VoidCallback? onRebuild;

  // ── Thumbnail methods ──────────────────────────────────────────

  /// Returns the cached thumbnail for [videoUrl] (or null if fetch failed).
  Future<Uint8List?> getThumbnail(String videoUrl) async {
    if (_thumbnailCache.containsKey(videoUrl)) {
      return _thumbnailCache[videoUrl];
    }
    try {
      final data = await VideoThumbnail.thumbnailData(
        video: videoUrl,
        maxWidth: 200,
        quality: 60,
      );
      _thumbnailCache[videoUrl] = data;
      return data;
    } catch (_) {
      _thumbnailCache[videoUrl] = null;
      return null;
    }
  }

  /// Returns a cached future for the thumbnail, creating one if needed.
  Future<Uint8List?> getThumbnailFuture(String videoUrl) {
    return _thumbnailFutures.putIfAbsent(
        videoUrl, () => getThumbnail(videoUrl));
  }

  // ── Looping controller methods ─────────────────────────────────

  /// Initialises a looping video controller for [videoUrl].
  Future<void> initializeController(String videoUrl) async {
    if (_controllers.containsKey(videoUrl) &&
        _controllersInitialized[videoUrl] == true) {
      return;
    }
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _controllers[videoUrl] = controller;
      _controllersInitialized[videoUrl] = false;

      await controller.initialize();
      if (!_controllers.containsKey(videoUrl))
        return; // disposed in the meantime

      _controllersInitialized[videoUrl] = true;
      _configureLoop(controller);
      await controller.setVolume(0.0);

      _initDebounce?.cancel();
      _initDebounce = Timer(const Duration(milliseconds: 80), () {
        onRebuild?.call();
      });
    } catch (_) {
      _controllers.remove(videoUrl)?.dispose();
      _controllersInitialized.remove(videoUrl);
    }
  }

  void _configureLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) {
          controller.seekTo(Duration.zero);
        }
      }
    });
    controller.play();
  }

  /// Returns the [VideoPlayerController] for a given url.
  VideoPlayerController? getController(String url) => _controllers[url];

  /// Returns `true` if the looping controller for [url] is fully initialised.
  bool isControllerInitialized(String url) =>
      _controllersInitialized[url] == true;

  /// Pre‑loads media for a list of posts.
  /// Loop candidates get a full controller; all others trigger a thumbnail fetch.
  void preloadMedia(List<Map<String, dynamic>> posts) {
    for (final post in posts) {
      final url = post['postUrl']?.toString() ?? '';
      if (!isVideoFile(url)) continue;
      final postId = post['postId']?.toString() ?? '';
      if (shouldShowVideoLoop(postId)) {
        initializeController(url);
      } else {
        getThumbnailFuture(url); // fire-and-forget
      }
    }
  }

  /// Pauses every looping controller.
  void pauseAll() {
    for (final c in _controllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  /// Resumes every looping controller that was previously playing.
  void resumeAll() {
    for (final c in _controllers.values) {
      if (c.value.isInitialized && !c.value.isPlaying) c.play();
    }
  }

  /// Disposes all resources. Call from the screen’s `dispose()`.
  void dispose() {
    _initDebounce?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _controllersInitialized.clear();
    _thumbnailCache.clear();
    _thumbnailFutures.clear();
  }
}
