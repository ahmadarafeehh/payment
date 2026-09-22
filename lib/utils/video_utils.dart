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
///
/// **Freeze fix (2026-09):** `search_perf_logs` showed sessions where the
/// UI dropped to ~1 frame/second and never recovered — `totalPostsLoaded`
/// frozen, `pendingControllers` stuck at 1 for 70+ seconds. Root cause:
/// `controller.initialize()` has no built-in timeout, so a single
/// unreachable/corrupt video file would hang that await forever, while the
/// native player kept retrying in the background and stealing UI-thread
/// time roughly once a second. Because the freeze also stops scroll events,
/// the existing `pruneOutsideWindow` (only triggered from scroll) never got
/// a chance to clean up the stuck controller — a self-reinforcing hang.
///
/// Three defenses were added to close this off:
///  1. `initialize()` is now wrapped in a hard timeout (see
///     [_initTimeout]) so a stalled load always fails fast into the
///     existing catch/cleanup path instead of hanging indefinitely.
///  2. A periodic watchdog (see [_watchdogInterval]) independently reaps
///     any controller that has been pending past [_watchdogStaleAfter],
///     so cleanup doesn't depend on scroll events still firing.
///  3. A concurrency cap (see [_maxConcurrentInits]) limits how many
///     controllers can be mid-`initialize()` at once, so a handful of
///     slow/stuck videos landing in the same prune window can't each spin
///     up a competing native decoder instance simultaneously.
class VideoMediaService {
  // ── Thumbnail cache ─────────────────────────────────────────────
  final Map<String, Uint8List?> _thumbnailCache = {};
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};

  // ── Looping video controllers ───────────────────────────────────
  final Map<String, VideoPlayerController> _controllers = {};
  final Map<String, bool> _controllersInitialized = {};
  Timer? _initDebounce;

  // ── Freeze-fix state ─────────────────────────────────────────────

  /// How long we allow a single `controller.initialize()` call to run
  /// before we give up on it and treat it as failed. This is the primary
  /// fix: without this, a stalled network read or a bad video file hangs
  /// this await forever.
  static const Duration _initTimeout = Duration(seconds: 5);

  /// How often the watchdog checks for stuck controllers. Independent of
  /// scroll — this is what guarantees cleanup even if the UI thread has
  /// already stalled and scroll events have stopped firing.
  static const Duration _watchdogInterval = Duration(seconds: 3);

  /// A controller pending longer than this is considered stuck and force
  /// -disposed by the watchdog, even if its own timeout hasn't fired yet
  /// (belt-and-braces in case a future edit changes _initTimeout without
  /// updating this).
  static const Duration _watchdogStaleAfter = Duration(seconds: 8);

  /// Maximum number of controllers allowed to be mid-`initialize()` at the
  /// same time. Keeps a burst of slow/stuck videos from each spinning up
  /// a competing native decoder instance simultaneously.
  static const int _maxConcurrentInits = 2;

  /// When a controller's `initialize()` call started, keyed by url. Used
  /// by the watchdog to find stale entries. An entry is removed as soon
  /// as its initialize() call resolves (success, timeout, or error).
  final Map<String, DateTime> _initStartTimes = {};

  /// URLs whose `initializeController` call is currently running (i.e.
  /// between the call starting and `initialize()` resolving/throwing).
  /// Used to enforce [_maxConcurrentInits] and to de-duplicate concurrent
  /// calls for the same url.
  final Set<String> _initInFlight = {};

  /// Urls that were requested while already at the concurrency cap. They
  /// are drained (in request order) as in-flight slots free up.
  final List<String> _initQueue = [];

  Timer? _watchdogTimer;

  VideoMediaService() {
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _runWatchdog());
  }

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
  // - watchdogReaped: running total of controllers force-disposed by the
  //   watchdog for exceeding _watchdogStaleAfter. Should normally be 0;
  //   a nonzero/climbing value means videos are actually failing to load
  //   (bad files, dead URLs, flaky network) and is worth alerting on even
  //   though the freeze itself is now prevented.
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
      'watchdogReaped': _watchdogReapedCount,
    };
  }

  int _watchdogReapedCount = 0;

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
  ///
  /// **Timeout + concurrency cap (freeze fix):** if [videoUrl] fails to
  /// finish loading within [_initTimeout], this call fails fast and cleans
  /// up instead of hanging forever. If [_maxConcurrentInits] controllers
  /// are already loading, this call is queued rather than started
  /// immediately, so a burst of slow videos can't all contend for
  /// resources at once.
  Future<void> initializeController(String videoUrl) async {
    if (_controllers.containsKey(videoUrl) &&
        _controllersInitialized[videoUrl] == true) {
      return;
    }
    // Already loading (or queued to load) — don't start a duplicate.
    if (_initInFlight.contains(videoUrl) || _initQueue.contains(videoUrl)) {
      return;
    }

    if (_initInFlight.length >= _maxConcurrentInits) {
      _initQueue.add(videoUrl);
      return;
    }

    await _startInitialize(videoUrl);
  }

  Future<void> _startInitialize(String videoUrl) async {
    _initInFlight.add(videoUrl);
    _initStartTimes[videoUrl] = DateTime.now();

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

      // THE FIX: bound how long we'll wait for initialize() to resolve.
      // Previously this await had no timeout, so a stalled/corrupt video
      // would hang here forever — which is what caused the observed
      // freeze (pendingControllers stuck at 1, UI dropping to ~1fps).
      await controller.initialize().timeout(
        _initTimeout,
        onTimeout: () {
          throw TimeoutException(
            'VideoMediaService: initialize() timed out after '
            '${_initTimeout.inSeconds}s for $videoUrl',
          );
        },
      );

      if (!_controllers.containsKey(videoUrl)) {
        // Disposed while we were awaiting (e.g. pruned or watchdog-reaped
        // mid-load) — bail without touching state.
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
    } finally {
      _initStartTimes.remove(videoUrl);
      _initInFlight.remove(videoUrl);
      _drainInitQueue();
    }
  }

  /// Starts the next queued controller (if any and if a slot is free).
  /// Called whenever an in-flight initialize finishes, so queued videos
  /// get picked up without needing a separate poller.
  void _drainInitQueue() {
    while (_initQueue.isNotEmpty &&
        _initInFlight.length < _maxConcurrentInits) {
      final next = _initQueue.removeAt(0);
      // Guard against a url that was queued but has since been pruned
      // or already completed via another path.
      if (_controllersInitialized[next] == true) continue;
      unawaited(_startInitialize(next));
    }
  }

  /// Independent safety net: periodically checks for controllers that
  /// have been mid-initialize() for longer than [_watchdogStaleAfter] and
  /// force-disposes them.
  ///
  /// This exists because the primary timeout above only protects a single
  /// `initializeController` call — if some future code path awaits it
  /// differently, or if the timeout itself somehow doesn't fire, this
  /// catches it. It also matters because during an actual freeze, scroll
  /// events (which normally drive cleanup via pruneOutsideWindow) stop
  /// firing — this watchdog runs on its own timer, independent of scroll
  /// or any other UI activity, so cleanup always eventually happens.
  void _runWatchdog() {
    final now = DateTime.now();
    final stale = _initStartTimes.entries
        .where((e) => now.difference(e.value) > _watchdogStaleAfter)
        .map((e) => e.key)
        .toList();

    for (final url in stale) {
      _controllers.remove(url)?.dispose();
      _controllersInitialized.remove(url);
      _initStartTimes.remove(url);
      _initInFlight.remove(url);
      _watchdogReapedCount++;
    }

    if (stale.isNotEmpty) {
      _drainInitQueue();
      onRebuild?.call();
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
  ///
  /// Note this is now a secondary defense against stuck controllers — the
  /// watchdog (see [_runWatchdog]) is the primary one, since this method
  /// only runs when scroll events are firing, which stops being true
  /// during an actual freeze.
  void pruneOutsideWindow(Set<String> keepUrls) {
    final controllersToRemove =
        _controllers.keys.where((u) => !keepUrls.contains(u)).toList();
    for (final url in controllersToRemove) {
      _controllers.remove(url)?.dispose();
      _controllersInitialized.remove(url);
      _initStartTimes.remove(url);
      _initInFlight.remove(url);
    }
    _initQueue.removeWhere((u) => !keepUrls.contains(u));

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

  /// Disposes all resources. Call from the screen's `dispose()`.
  void dispose() {
    _initDebounce?.cancel();
    _watchdogTimer?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _controllersInitialized.clear();
    _initStartTimes.clear();
    _initInFlight.clear();
    _initQueue.clear();
    _thumbnailCache.clear();
    _thumbnailFutures.clear();
  }
}
