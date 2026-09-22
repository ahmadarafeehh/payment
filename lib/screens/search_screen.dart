// lib/screens/search_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math; // ← ADD THIS LINE
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/search_posts.dart';
import 'package:Ratedly/services/analytics_service.dart';

import 'package:Ratedly/utils/colors.dart'; // shared colours
import 'package:Ratedly/utils/video_utils.dart'; // shared video helpers + service

// ─────────────────────────────────────────────────────────────────────────────
// SearchScreen  (the main search tab)
// ─────────────────────────────────────────────────────────────────────────────

class SearchScreen extends StatefulWidget {
  const SearchScreen({Key? key}) : super(key: key);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController searchController = TextEditingController();
  final _supabase = Supabase.instance.client;
  bool isShowUsers = false;
  bool _isSearchFocused = false;
  String? currentUserId;
  String? _currentUserIdForTracking;

  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  Timer? _debounceTimer;

  List<Map<String, dynamic>> _allPosts = [];
  Set<String> blockedUsersSet = {};
  bool _isLoading = true;
  bool _hasLoadError = false;

  int _offset = 0;
  bool _isLoadingMore = false;
  bool _hasMorePosts = true;
  bool _isFirstLoad = true;

  final int _initialPostsLimit = 12;
  final int _subsequentPostsLimit = 6;

  final ScrollController _scrollController = ScrollController();

  final Map<String, Map<String, dynamic>> _userDataCache = {};

  // ── Grid layout constants (kept in sync with the SliverGrid delegate) ──
  static const int _gridCrossAxisCount = 3;
  static const double _gridSpacing = 8.0;
  static const double _gridPadding = 8.0;
  static const double _gridChildAspectRatio = 0.75;

  /// Track which image URLs we've already asked `precacheImage` for, so the
  /// scroll listener doesn't repeatedly issue the same precache requests.
  final Set<String> _precachedImageUrls = {};

  // ── Media pruning (keeps activeControllers/pendingControllers bounded) ──
  //
  // Without this, every VideoPlayerController ever created for a scrolled-
  // through post lives until the screen is disposed — they just pile up
  // (confirmed via search_perf_logs: activeControllers climbing to 32+ with
  // pendingControllers stuck around 27, well past any reasonable "near the
  // viewport" count). Those stuck-pending controllers are all doing network
  // fetch + decode work simultaneously, which is what was causing the
  // scroll lag. This periodically disposes controllers/thumbnails whose
  // post has scrolled well outside the current viewport window.
  DateTime? _lastPruneAt;
  static const Duration _pruneThrottle = Duration(milliseconds: 400);
  // Rows of buffer above/below the first visible row to keep alive.
  // Wider than the precache lookahead so we don't dispose something the
  // user is likely to scroll straight back onto.
  static const int _pruneWindowRows = 6;

  // ── Perf/diagnostic logging state ───────────────────────────────────
  //
  // TEMPORARY instrumentation added to diagnose scroll-lag reports.
  // Writes to `search_perf_logs` (see migration run 2026-09). Safe to leave
  // enabled (cheap, fire-and-forget, matches DebugLogger's non-throwing
  // pattern) but intended to be stripped once the cause is confirmed.
  //
  // Throttles the pending-media warning log so a long stutter doesn't spam
  // one row per frame/scroll-tick.
  DateTime? _lastMediaWarningLoggedAt;
  static const Duration _mediaWarningThrottle = Duration(seconds: 2);
  static const int _pendingMediaWarningThreshold = 3;

  // ── Frame timing capture (actual jank signal) ───────────────────────
  //
  // Everything else in this file logs proxy signals (controller counts,
  // RPC durations). This is the direct measurement: real build+raster
  // time per frame, straight from the engine via SchedulerBinding. A
  // frame budget is ~16ms (60fps); anything over that is a dropped/janky
  // frame the user actually sees as lag. Flushed periodically as an
  // aggregate so we're not writing one row per frame.
  final List<FrameTiming> _frameTimingsBuffer = [];
  DateTime? _lastFrameLogAt;
  static const Duration _frameLogInterval = Duration(seconds: 2);

  // ── Shared media service (replaces all thumbnail caches & loop controllers) ──
  late final VideoMediaService _mediaService = VideoMediaService()
    ..onRebuild = () {
      if (mounted) setState(() {});
    };

  // ── Avatar video controllers (still separate, for user search results) ──
  //
  // Freeze fix (2026-09): these had the same unbounded-hang bug as the
  // grid's VideoMediaService — `controller.initialize()` with no timeout,
  // so a single stuck avatar video could hang forever and (per
  // search_perf_logs) drag the whole UI thread down with it. They also
  // never got disposed as search results changed, so they accumulated for
  // the life of the screen. Both are fixed below:
  //   - _initializeAvatarVideoController now times out after
  //     _avatarInitTimeout instead of awaiting indefinitely.
  //   - _pruneAvatarControllers disposes any avatar controller whose user
  //     is no longer in the current search results; called from
  //     _performSearch whenever results change.
  final Map<String, VideoPlayerController> _avatarVideoControllers = {};
  final Map<String, bool> _avatarVideoControllersInitialized = {};
  static const Duration _avatarInitTimeout = Duration(seconds: 5);

  // ── Unified colour provider ─────────────────────────────────────────
  AppColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? AppColorSet.dark()
        : AppColorSet.light();
  }

  // ── Error logging ─────────────────────────────────────────────────────
  Future<void> _logSearchError({
    required String operationType,
    String? userId,
    String? postId,
    Map<String, dynamic>? additionalData,
    required dynamic error,
    StackTrace? stackTrace,
  }) async {
    try {
      await _supabase.from('search_errors').insert({
        'user_id': userId ?? currentUserId,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': stackTrace?.toString(),
        'additional_data': {
          if (postId != null) 'postId': postId,
          ...?additionalData,
        },
      });
    } catch (_) {}
  }

  // ── Perf/diagnostic logging (writes to search_perf_logs) ───────────────
  //
  // Fire-and-forget, never throws, never awaited by callers — mirrors the
  // DebugLogger pattern already used elsewhere in the app so logging can
  // never itself cause jank or a crash.
  //
  // `mediaSnapshot` should be a `VideoMediaService.diagnosticsSnapshot()`
  // taken at (as close as possible to) the same moment as the timing, so a
  // slow page load and a pile-up of un-initialized video controllers show
  // up together on one row.
  void _logPerf({
    required String operationType,
    int? durationMs,
    int? enrichDurationMs,
    int? pageOffset,
    int? rowsReturned,
    bool? isFirstLoad,
    Map<String, int>? mediaSnapshot,
    Map<String, dynamic>? additionalData,
  }) {
    Future(() async {
      try {
        await _supabase.from('search_perf_logs').insert({
          'user_id': currentUserId,
          'operation_type': operationType,
          'duration_ms': durationMs,
          'enrich_duration_ms': enrichDurationMs,
          'page_offset': pageOffset,
          'rows_returned': rowsReturned,
          'is_first_load': isFirstLoad,
          'additional_data': {
            ...?mediaSnapshot,
            ...?additionalData,
          },
        });
      } catch (_) {
        // Logging must never crash the app or surface an error of its own.
      }
    });
  }

  // ── Avatar video controller ─────────────────────────────────────────
  Future<void> _initializeAvatarVideoController(String videoUrl) async {
    if (_avatarVideoControllers.containsKey(videoUrl) ||
        _avatarVideoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _avatarVideoControllers[videoUrl] = controller;
      _avatarVideoControllersInitialized[videoUrl] = false;

      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_avatarVideoControllersInitialized[videoUrl]!) {
          _avatarVideoControllersInitialized[videoUrl] = true;
          if (mounted) setState(() {});
        }
      });

      // FIX: bound how long we wait for an avatar video to load. Without
      // this, a stuck avatar (unreachable/corrupt file) hangs here forever
      // — the same bug class confirmed (via search_perf_logs) to freeze
      // the whole UI thread when it happened in the post grid.
      await controller.initialize().timeout(
        _avatarInitTimeout,
        onTimeout: () {
          throw TimeoutException(
            'Avatar video initialize() timed out for $videoUrl',
          );
        },
      );

      if (!_avatarVideoControllers.containsKey(videoUrl)) {
        // Disposed (e.g. pruned) while we were awaiting — bail without
        // touching state.
        return;
      }

      await controller.setVolume(0.0);
      _configureAvatarLoop(controller);
      if (mounted) setState(() {});
    } catch (_) {
      _avatarVideoControllers.remove(videoUrl)?.dispose();
      _avatarVideoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureAvatarLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) controller.seekTo(Duration.zero);
      }
    });
    controller.play();
  }

  /// Disposes avatar controllers for users no longer present in
  /// [keepUrls], so they don't accumulate for the life of the screen.
  /// Called whenever the search results set changes.
  void _pruneAvatarControllers(Set<String> keepUrls) {
    final toRemove = _avatarVideoControllers.keys
        .where((u) => !keepUrls.contains(u))
        .toList();
    for (final url in toRemove) {
      _avatarVideoControllers.remove(url)?.dispose();
      _avatarVideoControllersInitialized.remove(url);
    }
  }

  // ── Pause / resume helpers ──────────────────────────────────────────
  void _pauseAllVideos() {
    _mediaService.pauseAll(); // pauses looping post controllers
    for (final c in _avatarVideoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    AnalyticsService.screenEnter('search');
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  /// Engine callback firing with real per-frame build/raster durations.
  /// Buffers them and flushes an aggregated row every [_frameLogInterval],
  /// tagged with the media-service snapshot at flush time so a jank spike
  /// can be directly correlated with e.g. a burst of pending controllers.
  void _onFrameTimings(List<FrameTiming> timings) {
    _frameTimingsBuffer.addAll(timings);

    final now = DateTime.now();
    if (_lastFrameLogAt != null &&
        now.difference(_lastFrameLogAt!) < _frameLogInterval) {
      return;
    }
    if (_frameTimingsBuffer.isEmpty) return;
    _lastFrameLogAt = now;

    final buffer = List<FrameTiming>.from(_frameTimingsBuffer);
    _frameTimingsBuffer.clear();

    double totalBuildMs = 0;
    double totalRasterMs = 0;
    double worstFrameMs = 0;
    int jankFrames = 0; // frames over the ~16ms (60fps) budget

    for (final t in buffer) {
      final buildMs = t.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = t.rasterDuration.inMicroseconds / 1000.0;
      final totalMs = buildMs + rasterMs;
      totalBuildMs += buildMs;
      totalRasterMs += rasterMs;
      if (totalMs > worstFrameMs) worstFrameMs = totalMs;
      if (totalMs > 16.0) jankFrames++;
    }

    final frameCount = buffer.length;
    _logPerf(
      operationType: 'scroll_frame_timing',
      pageOffset: _offset,
      mediaSnapshot: _mediaService.diagnosticsSnapshot(),
      additionalData: {
        'frameCount': frameCount,
        'avgBuildMs': (totalBuildMs / frameCount).round(),
        'avgRasterMs': (totalRasterMs / frameCount).round(),
        'worstFrameMs': worstFrameMs.round(),
        'jankFrames': jankFrames,
        'totalPostsLoaded': _allPosts.length,
      },
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    // ── Pagination: load more when 70% through current content ──
    final trigger = position.maxScrollExtent * 0.70;
    if (position.pixels >= trigger &&
        !_isLoadingMore &&
        _hasMorePosts &&
        !isShowUsers) {
      _loadMorePosts();
    }

    // ── Precache only the next few items ahead of the viewport ──
    _precacheAhead(position.pixels);

    // ── Prune video controllers/thumbnails outside the viewport window ──
    // This is what keeps activeControllers/pendingControllers bounded as
    // the grid grows instead of climbing forever (see note above _mediaService).
    _maybePruneMedia(position.pixels);

    // ── Diagnostic: catch "video/thumbnail not showing" during scroll ──
    // This checks media state on every scroll tick (cheap: just two map
    // scans on the media service), independent of whether a network call
    // is in flight. If a meaningful number of the currently-visible-ish
    // items still have controllers stuck in the "instantiated but not
    // initialized" state, or thumbnails still pending, that's the direct
    // signature of "user scrolls past it and it never shows" — separate
    // from RPC/enrich latency, which only explains a stalled *load*, not
    // a stalled *render* of already-loaded posts.
    _maybeLogPendingMediaWarning(position.pixels);
  }

  /// Disposes video controllers/thumbnails for posts that have scrolled
  /// well outside the current viewport, throttled so it doesn't run on
  /// every scroll frame. Reuses the same row/index math as
  /// `_precacheAhead`, just with a wider buffer.
  void _maybePruneMedia(double pixelOffset) {
    final now = DateTime.now();
    if (_lastPruneAt != null &&
        now.difference(_lastPruneAt!) < _pruneThrottle) {
      return;
    }
    _lastPruneAt = now;

    if (!mounted || _allPosts.isEmpty) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final cellWidth = (screenWidth -
            _gridPadding * 2 -
            _gridSpacing * (_gridCrossAxisCount - 1)) /
        _gridCrossAxisCount;
    final rowHeight = cellWidth / _gridChildAspectRatio + _gridSpacing;

    final firstRow = (pixelOffset / rowHeight).floor();
    final windowStartRow = math.max(0, firstRow - _pruneWindowRows);
    final windowEndRow = firstRow + _pruneWindowRows;

    final startIndex =
        (windowStartRow * _gridCrossAxisCount).clamp(0, _allPosts.length);
    final endIndex =
        (windowEndRow * _gridCrossAxisCount).clamp(0, _allPosts.length);

    final keepUrls = <String>{};
    for (int i = startIndex; i < endIndex; i++) {
      final url = _allPosts[i]['postUrl']?.toString() ?? '';
      if (url.isNotEmpty) keepUrls.add(url);
    }

    _mediaService.pruneOutsideWindow(keepUrls);
  }

  void _maybeLogPendingMediaWarning(double pixelOffset) {
    final snapshot = _mediaService.diagnosticsSnapshot();
    final pending =
        (snapshot['pendingControllers'] ?? 0) + (snapshot['pendingThumbnailFetches'] ?? 0);
    if (pending < _pendingMediaWarningThreshold) return;

    final now = DateTime.now();
    if (_lastMediaWarningLoggedAt != null &&
        now.difference(_lastMediaWarningLoggedAt!) < _mediaWarningThrottle) {
      return;
    }
    _lastMediaWarningLoggedAt = now;

    _logPerf(
      operationType: 'scroll_media_pending',
      pageOffset: _offset,
      mediaSnapshot: snapshot,
      additionalData: {
        'scrollPixels': pixelOffset.round(),
        'totalPostsLoaded': _allPosts.length,
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && currentUserId == null) {
      currentUserId = userProvider.firebaseUid;
      _currentUserIdForTracking = currentUserId;
      if (!_isLoading) _initData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        currentUserId == null) {
      currentUserId = userProvider.supabaseUid;
      _currentUserIdForTracking = currentUserId;
      if (!_isLoading) _initData();
    }

    if (currentUserId != null && _isLoading) _initData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    }
  }

  @override
  void dispose() {
    if (_currentUserIdForTracking != null) {
      AnalyticsService.screenExit(
        screenName: 'search',
        uid: _currentUserIdForTracking!,
      );
    }
    _debounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    searchController.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    for (final c in _avatarVideoControllers.values) {
      c.dispose();
    }
    _avatarVideoControllers.clear();
    _avatarVideoControllersInitialized.clear();
    _mediaService.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────
  Future<void> _initData() async {
    if (currentUserId == null) {
      setState(() {
        _isLoading = false;
        _hasLoadError = false;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
    });

    _isFirstLoad = true;
    _offset = 0;
    _allPosts = [];
    _precachedImageUrls.clear();

    await Future.wait([_loadBlockedUsers(), _fetchPosts()]);
    setState(() => _isLoading = false);
    _ensureSufficientPosts();
  }

  Future<void> _loadBlockedUsers() async {
    if (currentUserId == null) {
      blockedUsersSet = {};
      return;
    }
    try {
      final response = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId!)
          .single();
      final blockedUsers = response['blockedUsers'] as List<dynamic>?;
      blockedUsersSet = Set<String>.from(blockedUsers ?? []);
    } catch (e, st) {
      await _logSearchError(
        operationType: 'load_blocked_users',
        error: e,
        stackTrace: st,
      );
      blockedUsersSet = {};
    }
  }

  Map<String, dynamic> _normalisePost(dynamic raw) {
    final Map<String, dynamic> post = {};
    (raw as Map).forEach((k, v) => post[k.toString()] = v);
    return post;
  }

  Future<void> _fetchPosts() async {
    if (currentUserId == null) {
      _allPosts = [];
      _hasMorePosts = false;
      _isFirstLoad = false;
      return;
    }

    final overallStopwatch = Stopwatch()..start();
    final rpcStopwatch = Stopwatch();
    final enrichStopwatch = Stopwatch();
    final wasFirstLoad = _isFirstLoad;

    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final postsLimit =
          _isFirstLoad ? _initialPostsLimit : _subsequentPostsLimit;

      rpcStopwatch.start();
      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': _offset,
        'page_limit': postsLimit,
      });
      rpcStopwatch.stop();

      if (response is List) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        enrichStopwatch.start();
        await _enrichPostsWithUserData(newPosts);
        enrichStopwatch.stop();
        if (!mounted) return;

        // NOTE: we no longer bulk-precache the whole batch.
        // Precache is now viewport-driven via _precacheAhead().

        setState(() {
          _allPosts = newPosts;
          _offset = _allPosts.length;
          _hasMorePosts = _allPosts.length == postsLimit;
          _isFirstLoad = false;
          _hasLoadError = false;
        });

        // Precache the first screenful so the top of the grid is instant.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _precacheAhead(0);
        });

        overallStopwatch.stop();
        _logPerf(
          operationType: 'fetch_posts_perf',
          durationMs: rpcStopwatch.elapsedMilliseconds,
          enrichDurationMs: enrichStopwatch.elapsedMilliseconds,
          pageOffset: _offset - newPosts.length,
          rowsReturned: newPosts.length,
          isFirstLoad: wasFirstLoad,
          mediaSnapshot: _mediaService.diagnosticsSnapshot(),
          additionalData: {
            'totalDurationMs': overallStopwatch.elapsedMilliseconds,
            'requestedLimit': postsLimit,
          },
        );
      } else {
        setState(() {
          _allPosts = [];
          _hasMorePosts = false;
          _isFirstLoad = false;
          _hasLoadError = true;
        });
        overallStopwatch.stop();
        _logPerf(
          operationType: 'fetch_posts_perf',
          durationMs: rpcStopwatch.elapsedMilliseconds,
          pageOffset: _offset,
          rowsReturned: 0,
          isFirstLoad: wasFirstLoad,
          additionalData: {
            'totalDurationMs': overallStopwatch.elapsedMilliseconds,
            'nonListResponse': true,
          },
        );
      }
    } catch (e, st) {
      overallStopwatch.stop();
      await _logSearchError(
        operationType: 'fetch_posts',
        additionalData: {'offset': _offset, 'isFirstLoad': _isFirstLoad},
        error: e,
        stackTrace: st,
      );
      _logPerf(
        operationType: 'fetch_posts_perf',
        durationMs: rpcStopwatch.elapsedMilliseconds,
        pageOffset: _offset,
        isFirstLoad: wasFirstLoad,
        additionalData: {
          'totalDurationMs': overallStopwatch.elapsedMilliseconds,
          'threw': true,
        },
      );
      setState(() {
        _allPosts = [];
        _hasMorePosts = false;
        _isFirstLoad = false;
        _hasLoadError = true;
      });
    }
  }

  Future<void> _loadMorePosts() async {
    if (!_hasMorePosts || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    final overallStopwatch = Stopwatch()..start();
    final rpcStopwatch = Stopwatch();
    final enrichStopwatch = Stopwatch();
    final offsetAtRequest = _offset;
    // Snapshot media state BEFORE the load, so we can see whether the
    // previous page's videos/thumbnails had even finished by the time the
    // user scrolled far enough to trigger the next page — i.e. whether
    // pagination is outrunning media loading.
    final mediaSnapshotBefore = _mediaService.diagnosticsSnapshot();

    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];

      rpcStopwatch.start();
      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': _offset,
        'page_limit': _subsequentPostsLimit,
      });
      rpcStopwatch.stop();

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        enrichStopwatch.start();
        await _enrichPostsWithUserData(newPosts);
        enrichStopwatch.stop();
        if (!mounted) return;

        setState(() {
          _allPosts.addAll(newPosts);
          _offset += newPosts.length;
          _hasMorePosts = newPosts.length == _subsequentPostsLimit;
        });

        overallStopwatch.stop();
        _logPerf(
          operationType: 'load_more_posts_perf',
          durationMs: rpcStopwatch.elapsedMilliseconds,
          enrichDurationMs: enrichStopwatch.elapsedMilliseconds,
          pageOffset: offsetAtRequest,
          rowsReturned: newPosts.length,
          isFirstLoad: false,
          mediaSnapshot: _mediaService.diagnosticsSnapshot(),
          additionalData: {
            'totalDurationMs': overallStopwatch.elapsedMilliseconds,
            'pendingControllersBeforeLoad':
                mediaSnapshotBefore['pendingControllers'],
            'pendingThumbnailFetchesBeforeLoad':
                mediaSnapshotBefore['pendingThumbnailFetches'],
          },
        );
      } else {
        setState(() => _hasMorePosts = false);
        overallStopwatch.stop();
        _logPerf(
          operationType: 'load_more_posts_perf',
          durationMs: rpcStopwatch.elapsedMilliseconds,
          pageOffset: offsetAtRequest,
          rowsReturned: 0,
          isFirstLoad: false,
          additionalData: {
            'totalDurationMs': overallStopwatch.elapsedMilliseconds,
            'emptyOrNonList': true,
          },
        );
      }
    } catch (e, st) {
      overallStopwatch.stop();
      await _logSearchError(
        operationType: 'load_more_posts',
        additionalData: {'offset': _offset},
        error: e,
        stackTrace: st,
      );
      _logPerf(
        operationType: 'load_more_posts_perf',
        durationMs: rpcStopwatch.elapsedMilliseconds,
        pageOffset: offsetAtRequest,
        isFirstLoad: false,
        additionalData: {
          'totalDurationMs': overallStopwatch.elapsedMilliseconds,
          'threw': true,
        },
      );
      setState(() => _hasMorePosts = false);
    } finally {
      setState(() => _isLoadingMore = false);
      _ensureSufficientPosts();
    }
  }

  void _ensureSufficientPosts() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.maxScrollExtent <= position.viewportDimension &&
          _hasMorePosts &&
          !_isLoadingMore) {
        _loadMorePosts();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadMorePostsForFeed(
      int currentCount) async {
    if (currentCount < _allPosts.length) {
      return List<Map<String, dynamic>>.from(_allPosts.sublist(currentCount));
    }

    if (!_hasMorePosts) return [];
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': currentCount,
        'page_limit': _subsequentPostsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();
        await _enrichPostsWithUserData(newPosts);
        if (!mounted) return [];

        if (mounted) {
          setState(() {
            _allPosts.addAll(newPosts);
            _offset += newPosts.length;
            _hasMorePosts = newPosts.length == _subsequentPostsLimit;
          });
        }
        return newPosts;
      }
      return [];
    } catch (e, st) {
      await _logSearchError(
        operationType: 'load_more_posts_for_feed',
        additionalData: {'currentCount': currentCount},
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  Future<void> _enrichPostsWithUserData(
      List<Map<String, dynamic>> posts) async {
    final missing = posts
        .map((p) => p['uid']?.toString() ?? '')
        .where((uid) => uid.isNotEmpty && !_userDataCache.containsKey(uid))
        .toSet()
        .toList();

    if (missing.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('users')
            .select('uid, username, photoUrl, isVerified, country')
            .inFilter('uid', missing);
        for (final row in rows) {
          final uid = row['uid']?.toString() ?? '';
          if (uid.isNotEmpty) {
            _userDataCache[uid] = {
              'uid': uid,
              'username': row['username']?.toString() ?? '',
              'photoUrl': row['photoUrl']?.toString() ?? '',
              'isVerified': row['isVerified'] ?? false,
              'country': row['country']?.toString() ?? '',
            };
          }
        }
      } catch (e, st) {
        await _logSearchError(
          operationType: 'enrich_posts_with_user_data',
          additionalData: {'missingCount': missing.length},
          error: e,
          stackTrace: st,
        );
      }
    }

    for (final post in posts) {
      final uid = post['uid']?.toString() ?? '';
      final cached = _userDataCache[uid];
      if (cached != null) {
        post['username'] ??= cached['username'];
        post['photoUrl'] ??= cached['photoUrl'];
        post['isVerified'] ??= cached['isVerified'];
        post['country'] ??= cached['country'];
      }
    }
  }

  // ── Viewport-driven image precache (replaces bulk _precacheImages) ──
  //
  // Precache only the next few images ahead of the current scroll position.
  // This keeps decoded-bitmap memory bounded as the grid grows.
  void _precacheAhead(double pixelOffset) {
    if (!mounted || _allPosts.isEmpty) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final cellWidth = (screenWidth -
            _gridPadding * 2 -
            _gridSpacing * (_gridCrossAxisCount - 1)) /
        _gridCrossAxisCount;
    final rowHeight = cellWidth / _gridChildAspectRatio + _gridSpacing;

    final firstRow = (pixelOffset / rowHeight).floor();
    final startIndex =
        (firstRow * _gridCrossAxisCount).clamp(0, _allPosts.length);
    // ~3 rows ahead of the top of the viewport = 9 items.
    final endIndex = (startIndex + 9).clamp(0, _allPosts.length);

    for (int i = startIndex; i < endIndex; i++) {
      final url = _allPosts[i]['postUrl']?.toString() ?? '';
      if (url.isEmpty || isVideoFile(url)) continue;
      if (_precachedImageUrls.contains(url)) continue;
      _precachedImageUrls.add(url);
      precacheImage(CachedNetworkImageProvider(url), context);
    }
  }

  // ── Search ──────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    if (query.trim().isEmpty || currentUserId == null) return [];

    try {
      final response = await _supabase
          .from('users')
          .select('uid, username, photoUrl, isVerified, country')
          .ilike('username', '%$query%')
          .limit(20);

      final List<Map<String, dynamic>> users =
          List<Map<String, dynamic>>.from(response);

      return users.where((user) {
        final uid = user['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(uid) && uid != currentUserId;
      }).toList();
    } catch (e, st) {
      await _logSearchError(
        operationType: 'search_users',
        additionalData: {'query': query},
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      isShowUsers = value.trim().isNotEmpty;
      _isSearchFocused = false;
    });

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.trim().isNotEmpty) {
        _performSearch(value.trim());
      } else {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
        // No results left on screen — nothing to keep.
        _pruneAvatarControllers({});
      }
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isSearching = true);
    final results = await _searchUsers(query);
    if (mounted) {
      // Drop avatar controllers for users no longer in the new result set,
      // so they don't accumulate for the life of the screen as the person
      // types different queries.
      final currentAvatarUrls = results
          .map((u) => u['photoUrl']?.toString() ?? '')
          .where((url) => url.isNotEmpty && url != 'default')
          .toSet();
      _pruneAvatarControllers(currentAvatarUrls);

      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  // ── Skeleton loaders ────────────────────────────────────────────────
  Widget _buildPostsGridSkeleton(AppColorSet colors) {
    return GridView.builder(
      padding: const EdgeInsets.all(8.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8.0,
        mainAxisSpacing: 8.0,
        childAspectRatio: 0.75,
      ),
      itemCount: 12,
      itemBuilder: (_, __) => _buildPostSkeleton(colors),
    );
  }

  Widget _buildPostSkeleton(AppColorSet colors) => Container(
        decoration: BoxDecoration(
            color: colors.skeletonColor,
            borderRadius: BorderRadius.circular(8)),
      );

  Widget _buildUserSkeleton(AppColorSet colors) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(backgroundColor: colors.skeletonColor, radius: 20),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            height: 14,
            width: 120,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 12,
            width: 80,
            decoration: BoxDecoration(
                color: colors.skeletonColor.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }

  Widget _buildUserSearchSkeleton(AppColorSet colors) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 5,
      itemBuilder: (_, __) => _buildUserSkeleton(colors),
    );
  }

  // ── Main build ──────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      if (userProvider.firebaseUid != null && currentUserId == null) {
        currentUserId = userProvider.firebaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      } else if (userProvider.firebaseUid == null &&
          userProvider.supabaseUid != null &&
          currentUserId == null) {
        currentUserId = userProvider.supabaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      }
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        backgroundColor: colors.appBarBackgroundColor,
        toolbarHeight: 80,
        elevation: 0,
        iconTheme: IconThemeData(color: colors.iconColor),
        title: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: SizedBox(
            height: 48,
            child: TextFormField(
              controller: searchController,
              style: TextStyle(color: colors.textColor),
              decoration: InputDecoration(
                hintText: 'Search for a user...',
                hintStyle: TextStyle(color: colors.hintTextColor),
                filled: true,
                fillColor: colors.cardColor,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.borderColor),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: colors.focusedBorderColor, width: 2),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
              onTap: () {
                if (searchController.text.trim().isEmpty) {
                  setState(() {
                    isShowUsers = false;
                    _isSearchFocused = true;
                  });
                }
              },
              onChanged: _onSearchChanged,
              onFieldSubmitted: (_) {
                setState(() {
                  isShowUsers = true;
                  _isSearchFocused = false;
                });
                _performSearch(searchController.text.trim());
              },
            ),
          ),
        ),
      ),
      body: _isLoading
          ? _buildEnhancedSkeletonLoading(colors)
          : Column(children: [
              Expanded(
                child: _isSearchFocused && searchController.text.trim().isEmpty
                    ? _buildPostsGrid(colors)
                    : isShowUsers
                        ? _buildUserSearch(colors)
                        : _buildPostsGrid(colors),
              ),
            ]),
    );
  }

  Widget _buildEnhancedSkeletonLoading(AppColorSet colors) {
    return Column(children: [
      Expanded(child: _buildPostsGridSkeleton(colors)),
    ]);
  }

  Widget _buildUserSearch(AppColorSet colors) {
    if (_isSearching) return _buildUserSearchSkeleton(colors);

    if (_searchResults.isEmpty) {
      return Center(
        child:
            Text('No users found.', style: TextStyle(color: colors.textColor)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final user = _searchResults[index];
        final uid = user['uid']?.toString() ?? '';
        final username = user['username']?.toString() ?? '';
        final photoUrl = user['photoUrl']?.toString() ?? '';
        final isVerified = user['isVerified'] ?? false;
        final country = user['country']?.toString() ?? '';

        return ListTile(
          leading: _buildUserAvatar(photoUrl, colors),
          title: Row(
            children: [
              Flexible(
                child: Text(username,
                    style: TextStyle(
                        color: colors.textColor, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
              ),
              if (isVerified) ...[
                const SizedBox(width: 4),
                const Icon(Icons.verified, color: Colors.blue, size: 16),
              ],
            ],
          ),
          subtitle: country.isNotEmpty
              ? Text(country,
                  style: TextStyle(color: colors.hintTextColor, fontSize: 12))
              : null,
          onTap: () => _navigateToProfile(uid),
        );
      },
    );
  }

  // ── Posts grid ──────────────────────────────────────────────────────
  //
  // CHANGED: uses a single lazy CustomScrollView + SliverGrid instead of a
  // shrinkWrapped GridView inside a ListView. The old approach laid out and
  // kept every item resident, which is what caused the lag as _allPosts grew.
  Widget _buildPostsGrid(AppColorSet colors) {
    if (_hasLoadError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: colors.iconColor, size: 48),
            const SizedBox(height: 12),
            Text('Something went wrong.',
                style: TextStyle(color: colors.textColor)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _initData,
              child: Text('Retry', style: TextStyle(color: colors.textColor)),
            ),
          ],
        ),
      );
    }

    if (_allPosts.isEmpty) {
      return Center(
          child: Text('No posts found.',
              style: TextStyle(color: colors.textColor)));
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        final extent = scrollInfo.metrics.maxScrollExtent;
        if (scrollInfo.metrics.pixels >= extent * 0.70 &&
            !_isLoadingMore &&
            _hasMorePosts &&
            !isShowUsers) {
          _loadMorePosts();
        }
        return false;
      },
      child: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(_gridPadding),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridCrossAxisCount,
                    childAspectRatio: _gridChildAspectRatio,
                    crossAxisSpacing: _gridSpacing,
                    mainAxisSpacing: _gridSpacing,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final post = _allPosts[index];
                      return _buildPostItem(
                        post,
                        post['postUrl']?.toString() ?? '',
                        index,
                        colors,
                      );
                    },
                    childCount: _allPosts.length,
                    // Don't keep offscreen cell widgets alive — the media
                    // service handles any persistent state.
                    addAutomaticKeepAlives: false,
                    addRepaintBoundaries: true,
                  ),
                ),
              ),
            ],
          ),
          if (_isLoadingMore)
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.backgroundColor.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: CircularProgressIndicator(
                      color: colors.progressIndicatorColor),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPostItem(Map<String, dynamic> post, String postUrl, int index,
      AppColorSet colors) {
    final isVideo = isVideoFile(postUrl);
    final postId = post['postId']?.toString() ?? '';
    final editResult = parseEditResult(post);

    // Ensure media is loaded (service takes care of loop vs thumbnail).
    // NOTE: because this now runs only for cells the sliver actually builds
    // (viewport + small cacheExtent), the service sees far fewer init calls
    // than with the previous eager grid.
    if (isVideo) {
      if (shouldShowVideoLoop(postId)) {
        _mediaService.initializeController(postUrl);
      } else {
        _mediaService.getThumbnailFuture(postUrl);
      }
    }

    return InkWell(
      onTap: () async {
        _pauseAllVideos();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SearchResultFeedScreen(
              initialPosts: List<Map<String, dynamic>>.from(_allPosts),
              initialIndex: index,
              onLoadMore: _loadMorePostsForFeed,
              initialHasMore: _hasMorePosts,
            ),
          ),
        ).then((_) {
          if (mounted) {
            // resume only the service's looping controllers
            _mediaService.resumeAll();
          }
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: isVideo ? colors.gridItemBackgroundColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(children: [
          if (postUrl.isNotEmpty)
            isVideo
                ? (shouldShowVideoLoop(postId)
                    ? _buildVideoPlayer(postUrl, colors, editResult)
                    : _buildVideoThumbnail(postUrl, colors, editResult))
                : _buildPostImage(postUrl, colors, editResult)
          else
            Container(
              color: colors.gridItemBackgroundColor,
              child: Icon(Icons.broken_image, color: colors.iconColor),
            ),
        ]),
      ),
    );
  }

  // ── Video player (using service) ───────────────────────────────────
  Widget _buildVideoPlayer(String videoUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final controller = _mediaService.getController(videoUrl);
    final isInitialized = _mediaService.isControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        color: colors.gridItemBackgroundColor,
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }

    final List<double> matrix = buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return AspectRatio(
      aspectRatio: _gridChildAspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: colors.gridItemBackgroundColor,
          child: Stack(fit: StackFit.expand, children: [
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(matrix),
                child: Transform.rotate(
                  angle: quarters * math.pi / 2,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: controller.value.size.width,
                      height: controller.value.size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ),
            ),
            if (editResult != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) => buildEditOverlayLayer(
                      editResult: editResult,
                      constraints: constraints,
                      screenSize: MediaQuery.of(context).size,
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildVideoThumbnail(String videoUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return AspectRatio(
      aspectRatio: _gridChildAspectRatio,
      child: FutureBuilder<Uint8List?>(
        future: _mediaService.getThumbnailFuture(videoUrl),
        builder: (context, snapshot) {
          final haveImage = snapshot.connectionState == ConnectionState.done &&
              snapshot.data != null;

          Widget imageLayer = haveImage
              ? Image.memory(snapshot.data!, fit: BoxFit.cover)
              : Container(color: colors.gridItemBackgroundColor);

          imageLayer = ColorFiltered(
            colorFilter: ColorFilter.matrix(matrix),
            child: Transform.rotate(
              angle: quarters * math.pi / 2,
              child: imageLayer,
            ),
          );

          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(fit: StackFit.expand, children: [
              Positioned.fill(child: imageLayer),
              if (editResult != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) => buildEditOverlayLayer(
                        editResult: editResult,
                        constraints: constraints,
                        screenSize: MediaQuery.of(context).size,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _buildPostImage(String imageUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    // Decode at the cell's pixel width, not the source's. This alone can cut
    // decoded-bitmap memory by 4–9x for typical phone photos.
    final screenWidth = MediaQuery.of(context).size.width;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cellPixelWidth = ((screenWidth -
                _gridPadding * 2 -
                _gridSpacing * (_gridCrossAxisCount - 1)) /
            _gridCrossAxisCount *
            dpr)
        .round();

    Widget networkImage = CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      memCacheWidth: cellPixelWidth,
      placeholder: (_, __) => Container(color: colors.skeletonColor),
      errorWidget: (_, __, ___) => Container(
        color: colors.gridItemBackgroundColor,
        child: Icon(Icons.broken_image, color: colors.iconColor),
      ),
    );

    if (editResult != null) {
      networkImage = ColorFiltered(
        colorFilter: ColorFilter.matrix(matrix),
        child: Transform.rotate(
          angle: quarters * math.pi / 2,
          child: networkImage,
        ),
      );
    }

    Widget baseImage = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: networkImage,
    );

    if (editResult == null) {
      return AspectRatio(aspectRatio: _gridChildAspectRatio, child: baseImage);
    }

    return AspectRatio(
      aspectRatio: _gridChildAspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(fit: StackFit.expand, children: [
          Positioned.fill(child: baseImage),
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) => buildEditOverlayLayer(
                  editResult: editResult,
                  constraints: constraints,
                  screenSize: MediaQuery.of(context).size,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildUserAvatar(String? photoUrl, AppColorSet colors) {
    final url = photoUrl?.toString() ?? '';
    final isDefault = url.isEmpty || url == 'default';
    final isVideo = !isDefault && isVideoFile(url);

    if (isDefault) {
      return CircleAvatar(
        backgroundColor: colors.avatarBackgroundColor,
        radius: 20,
        child: Icon(Icons.account_circle, size: 40, color: colors.iconColor),
      );
    }
    if (isVideo) {
      if (!_avatarVideoControllers.containsKey(url)) {
        _initializeAvatarVideoController(url);
      }
      return _buildAvatarVideoPlayer(url, colors);
    }
    return CircleAvatar(
      backgroundColor: colors.avatarBackgroundColor,
      radius: 20,
      backgroundImage: CachedNetworkImageProvider(url),
    );
  }

  Widget _buildAvatarVideoPlayer(String videoUrl, AppColorSet colors) {
    final controller = _avatarVideoControllers[videoUrl];
    final isInitialized = _avatarVideoControllersInitialized[videoUrl] == true;
    if (!isInitialized || controller == null) {
      return Container(
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: colors.avatarBackgroundColor),
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor, strokeWidth: 2.0)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  void _navigateToProfile(String uid) {
    if (uid.isEmpty) return;
    _pauseAllVideos();
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => ProfileScreen(uid: uid)))
        .then((_) {
      if (mounted) {
        setState(() {
          isShowUsers = false;
          searchController.clear();
          _searchResults = [];
        });
      }
    });
  }
}
