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
///
/// **Audio safety:** every controller managed by this service is guaranteed
/// to be muted *before* `play()` is ever invoked. This prevents the audible
/// "flash" that occurs on iOS/Android when a preview video starts playing
/// for a handful of milliseconds at full volume during initialization.
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

  // ── Diagnostics (read-only snapshot for perf logging) ───────────
  //
  // Lets callers (e.g. search_screen's perf logger) capture a cheap
  // snapshot of internal state at the moment a page load completes,
  // without exposing the mutable maps themselves.
  //
  // - activeControllers: controllers currently instantiated (memory-live),
  //   regardless of whether they've finished initializing.
  // - initializedControllers: subset of the above that finished
  //   `.initialize()` and are actually attached/playable.
  // - pendingControllers: instantiated but NOT yet initialized — this is
  //   the number worth watching during scroll, since a controller stuck
  //   here for a while is a controller the user scrolled past without it
  //   ever rendering a frame ("video not showing").
  // - cachedThumbnails: thumbnails successfully decoded and cached.
  // - pendingThumbnailFetches: thumbnail futures in flight (requested but
  //   not yet resolved) — a large number here during fast scroll indicates
  //   thumbnail generation is the bottleneck, not the grid itself.
  Map<String, int> diagnosticsSnapshot() {
    final pendingControllers = _controllersInitialized.values
        .where((initialized) => initialized == false)
        .length;
    final pendingThumbnailFetches = _thumbnailFutures.keys
        .where((url) => !_thumbnailCache.containsKey(url))
        .length;
    return {
      'activeControllers': _controllers.length,
      'initializedControllers':
          _controllersInitialized.values.where((v) => v == true).length,
      'pendingControllers': pendingControllers,
      'cachedThumbnails': _thumbnailCache.length,
      'pendingThumbnailFetches': pendingThumbnailFetches,
    };
  }

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
  ///
  /// The controller is guaranteed to be muted BEFORE `play()` is ever called,
  /// so no audible frame can escape during initialization. A defensive
  /// listener also re-asserts volume=0 if the platform ever reports a
  /// non-zero volume mid-stream (this happens on some Android builds when
  /// the player is re-created after being backgrounded).
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

      // Defensive listener: the moment the platform reports the controller
      // is initialized, force volume to 0. This closes the tiny window
      // between initialize() resolving and our explicit setVolume call
      // below, which on iOS/Android can emit a few ms of audio.
      controller.addListener(() {
        if (controller.value.isInitialized && controller.value.volume > 0.0) {
          controller.setVolume(0.0);
        }
      });

      await controller.initialize();
      if (!_controllers.containsKey(videoUrl)) {
        // Disposed while we were awaiting — bail without touching state.
        return;
      }

      // Mute BEFORE any play() call. This ordering is the actual fix:
      // previously _configureLoop() (which calls play()) ran first, so
      // the first ~1 frame played at volume 1.0.
      await controller.setVolume(0.0);

      _controllersInitialized[videoUrl] = true;
      _configureLoop(controller);

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

    // Belt-and-braces: the caller has already set volume to 0.0, but we
    // re-assert here in case a future refactor reorders the calls. A
    // no-op setVolume on an already-muted controller costs nothing.
    controller.setVolume(0.0);
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

  /// Disposes any controller/thumbnail-future whose url is not in
  /// [keepUrls]. Call this periodically (throttled) as the user scrolls,
  /// passing the set of post urls currently near the viewport.
  ///
  /// This is what keeps activeControllers/pendingControllers bounded as
  /// the grid grows — without it, every controller ever created lives
  /// until the screen is disposed, which is what caused the scroll lag
  /// (controllers stuck mid-initialize() piling up and contending for
  /// network/decoder resources with whatever's actually on screen).
  void pruneOutsideWindow(Set<String> keepUrls) {
    final controllersToRemove =
        _controllers.keys.where((u) => !keepUrls.contains(u)).toList();
    for (final url in controllersToRemove) {
      _controllers.remove(url)?.dispose();
      _controllersInitialized.remove(url);
    }

    // Thumbnails are cheap (just bytes), so we don't need to be as
    // aggressive — but still cap them so long scroll sessions don't
    // accumulate hundreds of decoded images.
    if (_thumbnailCache.length > 150) {
      final thumbsToRemove =
          _thumbnailCache.keys.where((u) => !keepUrls.contains(u)).toList();
      for (final url in thumbsToRemove) {
        _thumbnailCache.remove(url);
        _thumbnailFutures.remove(url);
      }
    }
  }

  /// Pauses every looping controller. Mutes first so that if a controller
  /// was somehow left at a non-zero volume, the pause cannot coincide with
  /// an audible frame.
  void pauseAll() {
    for (final c in _controllers.values) {
      if (c.value.volume > 0.0) c.setVolume(0.0);
      if (c.value.isPlaying) c.pause();
    }
  }

  /// Resumes every looping controller that was previously playing.
  /// Re-asserts mute before each play() so a resume can never produce
  /// an audible frame — these are previews, they should always be silent.
  void resumeAll() {
    for (final c in _controllers.values) {
      if (!c.value.isInitialized || c.value.isPlaying) continue;
      c.setVolume(0.0);
      c.play();
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
