import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/global_variable.dart';
import 'package:Ratedly/screens/feed/post_card.dart' hide unawaited;
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/widgets/feedmessages.dart';
import 'package:Ratedly/services/ads.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/services/feed_cache_service.dart' hide unawaited;
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/feed/feed_skeleton.dart';
import 'package:Ratedly/services/iap_service.dart'; // ADDED for premium check

class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color skeletonColor;
  final Color progressIndicatorColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.skeletonColor,
    required this.progressIndicatorColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          skeletonColor: const Color(0xFF333333).withOpacity(0.6),
          progressIndicatorColor: Colors.white70,
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
          skeletonColor: Colors.grey[300]!.withOpacity(0.6),
          progressIndicatorColor: Colors.grey[700]!,
        );
}

class FeedScreen extends StatefulWidget {
  const FeedScreen({Key? key}) : super(key: key);

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  final SupabaseClient _supabase = Supabase.instance.client;
  String? currentUserId;

  int _selectedTab = 1;

  late PageController _followingPageController;
  late PageController _forYouPageController;

  List<Map<String, dynamic>> _followingPosts = [];
  List<Map<String, dynamic>> _forYouPosts = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;

  // FIX 3 — _offsetForYou is no longer used for For You pagination;
  // user_post_views handles exclusion server-side.  We keep _offsetFollowing
  // for the Following tab which still uses cursor-based pagination.
  int _offsetFollowing = 0;

  bool _hasMoreFollowing = true;
  bool _hasMoreForYou = true;

  List<String> _blockedUsers = [];
  List<String> _followingIds = [];
  bool _viewRecordingScheduled = false;
  final Set<String> _pendingViews = {};

  int _currentForYouPage = 0;
  int _currentFollowingPage = 0;
  final Map<String, bool> _postVisibility = {};
  String? _currentPlayingPostId;

  final Map<String, Map<String, dynamic>> _postCache = {};

  InterstitialAd? _interstitialAd;
  int _postViewCount = 0;
  DateTime? _lastInterstitialAdTime;

  Stream<int>? _unreadCountStream;
  StreamController<int>? _unreadCountController;
  Timer? _unreadCountTimer;

  final Map<String, Map<String, dynamic>> _userCache = {};
  static final Map<String, List<String>> _blockedUsersCache = {};
  static DateTime? _lastBlockedUsersCacheTime;

  List<Map<String, dynamic>> _nextForYouBatch = [];
  bool _nextBatchLoaded = false;
  Timer? _prefetchTimer; // FIX 2 — delayed prefetch timer

  static const int _mediaPreloadAhead = 4;
  static const int _mediaPreloadBehind = 2;
  final Map<String, VideoPlayerController> _feedVideoControllers = {};
  final Map<String, bool> _feedVideoControllersInitialized = {};
  final Map<String, Future<void>> _videoInitializationFutures = {};
  final Map<String, bool> _imagePreloaded = {};
  final Map<String, FileInfo?> _cachedImageInfo = {};
  final Map<String, ImageProvider> _loadedImageProviders = {};
  final List<Map<String, dynamic>> _visiblePosts = [];
  int _currentVisibleIndex = 0;

  static const int _initialBatchSize = 10;

  bool _essentialUiReady = false;
  bool _showOverlay = true;
  double _lastScrollOffset = 0;
  bool _firstVideoInitialized = false;
  final Map<String, bool> _postReadyToShow = {};
  final Set<String> _postsBeingPreloaded = {};
  final Set<String> _postsFullyPreloaded = {};

  Set<String> _immediateCachedPostIds = {};

  bool _cacheLoadAttempted = false;
  bool _cacheLoaded = false;
  Timer? _delayedCacheUpdateTimer;

  bool _followingIdsLoaded = false;
  bool _immediatePostsCached = false;
  DateTime? _appStartTime;

  // ---------------------------------------------------------------------------
  // HELPERS
  // ---------------------------------------------------------------------------

  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
  }

  dynamic _unwrapResponse(dynamic res) {
    if (res == null) return null;
    if (res is Map && res.containsKey('data')) return res['data'];
    return res;
  }

  void _pauseCurrentVideo() {
    VideoManager.pauseAllVideos();
    if (mounted) {
      setState(() => _currentPlayingPostId = null);
    } else {
      _currentPlayingPostId = null;
    }
  }

  void _cachePost(Map<String, dynamic> post) {
    final postId = post['postId']?.toString();
    if (postId != null && postId.isNotEmpty) {
      _postCache[postId] = Map<String, dynamic>.from(post);
    }
  }

  bool _isVideoFile(String url) {
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

  bool _isImageFile(String url) {
    if (url.isEmpty) return false;
    final l = url.toLowerCase();
    final hasImageExtension = l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.png') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp') ||
        l.endsWith('.bmp') ||
        l.endsWith('.svg');
    final hasImagePath = l.contains('/image/') ||
        l.contains('/images/') ||
        l.contains('/img/') ||
        l.contains('image=true') ||
        l.contains('type=image');
    final isSupabaseImage =
        l.contains('supabase.co/storage/v1/object/public/') &&
            (l.contains('/images/') ||
                l.contains('/Images/') ||
                l.contains('/posts/') ||
                (l.contains('/videos/') && hasImageExtension));
    final isFirebaseImage = l.contains('firebasestorage.googleapis.com') &&
        (l.contains('_1024x1024') ||
            l.contains('alt=media') ||
            l.contains('/posts/') ||
            l.contains('/images/') ||
            l.contains('/profilepics/') ||
            l.contains('/profilePics/'));
    final hasThumbnailPattern = l.contains('thumb') ||
        l.contains('thumbnail') ||
        l.contains('_thumb') ||
        l.contains('_thumbnail');
    final hasImageQueryParam = l.contains('format=jpg') ||
        l.contains('format=png') ||
        l.contains('format=webp') ||
        l.contains('image/jpeg') ||
        l.contains('image/png');
    return hasImageExtension ||
        hasImagePath ||
        isSupabaseImage ||
        isFirebaseImage ||
        hasThumbnailPattern ||
        hasImageQueryParam;
  }

  bool _isFirebaseStorageUrl(String url) {
    return url.contains('firebasestorage.googleapis.com') &&
        url.contains('alt=media') &&
        (url.contains('/profilePics/') ||
            url.contains('/posts/') ||
            url.contains('/images/'));
  }

  List<String> _getAllImageUrlsFromPost(Map<String, dynamic> post) {
    final urls = <String>{};
    for (final key in ['postUrl', 'thumbnailUrl', 'imageUrl', 'profImage']) {
      final value = post[key]?.toString() ?? '';
      if (value.isNotEmpty && _isImageFile(value)) urls.add(value);
    }
    for (final key in post.keys) {
      final value = post[key]?.toString() ?? '';
      if (value.isNotEmpty &&
          value.contains('http') &&
          _isImageFile(value) &&
          !urls.contains(value)) {
        urls.add(value);
      }
    }
    return urls.toList();
  }

  // ===========================================================================
  // EDIT METADATA ENRICHMENT
  // ===========================================================================

  Future<List<Map<String, dynamic>>> _enrichPostsWithEditMetadata(
      List<Map<String, dynamic>> posts) async {
    final videoPostIds = posts
        .where((p) {
          final url = p['postUrl']?.toString() ?? '';
          return _isVideoFile(url) && p['video_edit_metadata'] == null;
        })
        .map((p) => p['postId']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();

    if (videoPostIds.isEmpty) return posts;

    try {
      final rows = await _supabase
          .from('posts')
          .select('postId, video_edit_metadata')
          .inFilter('postId', videoPostIds);

      final metaMap = <String, dynamic>{};
      for (final row in rows) {
        final id = row['postId']?.toString() ?? '';
        if (id.isNotEmpty) metaMap[id] = row['video_edit_metadata'];
      }

      return posts.map((p) {
        final id = p['postId']?.toString() ?? '';
        if (metaMap.containsKey(id)) {
          return <String, dynamic>{...p, 'video_edit_metadata': metaMap[id]};
        }
        return p;
      }).toList();
    } catch (_) {
      return posts;
    }
  }

  // ===========================================================================
  // MEDIA PRELOADING
  // ===========================================================================

  Future<void> _preloadAllMediaForPost(Map<String, dynamic> post) async {
    final postId = post['postId']?.toString() ?? '';
    final postUrl = post['postUrl']?.toString() ?? '';

    if (postId.isEmpty) return;
    if (_postsBeingPreloaded.contains(postId) ||
        _postsFullyPreloaded.contains(postId)) return;

    _postsBeingPreloaded.add(postId);

    final completer = Completer<void>();
    int mediaToPreload = 0;
    int mediaPreloaded = 0;

    void checkCompletion() {
      mediaPreloaded++;
      if (mediaPreloaded >= mediaToPreload && !completer.isCompleted) {
        _postsBeingPreloaded.remove(postId);
        _postsFullyPreloaded.add(postId);
        if (mounted) setState(() => _postReadyToShow[postId] = true);
        completer.complete();
      }
    }

    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      mediaToPreload++;
      try {
        if (_feedVideoControllers.containsKey(postUrl) &&
            _feedVideoControllersInitialized[postUrl] == true) {
          checkCompletion();
        } else {
          await _initializeFeedVideoController(postUrl, postId);
          checkCompletion();
        }
      } catch (e) {
        checkCompletion();
      }
    }

    final imageUrls = _getAllImageUrlsFromPost(post);
    for (final imageUrl in imageUrls) {
      if (imageUrl.isNotEmpty && !_imagePreloaded.containsKey(imageUrl)) {
        mediaToPreload++;
        _preloadImage(imageUrl, postId).then((_) {
          checkCompletion();
        }).catchError((e) async {
          checkCompletion();
        });
      }
    }

    if (!_isVideoFile(postUrl) && imageUrls.isEmpty) {
      _postsBeingPreloaded.remove(postId);
      _postsFullyPreloaded.add(postId);
      if (mounted) setState(() => _postReadyToShow[postId] = true);
      completer.complete();
    }

    if (mediaToPreload == 0) _checkAndMarkPostReady(postId);

    return completer.future;
  }

  void _preloadAllMediaForPosts(List<Map<String, dynamic>> posts) {
    if (posts.isEmpty) return;
    for (final post in posts) {
      final postId = post['postId']?.toString() ?? '';
      if (postId.isNotEmpty &&
          !_postsBeingPreloaded.contains(postId) &&
          !_postsFullyPreloaded.contains(postId)) {
        unawaited(_preloadAllMediaForPost(post));
      }
    }
  }

  Future<void> _preloadImage(String imageUrl, String postId) async {
    if (imageUrl.isEmpty || _imagePreloaded[imageUrl] == true) return;
    try {
      _imagePreloaded[imageUrl] = false;
      if (_isFirebaseStorageUrl(imageUrl)) {
        await _preloadFirebaseImageWithSDK(imageUrl, postId);
      } else {
        await _preloadRegularImage(imageUrl, postId);
      }
      _checkAndMarkPostReady(postId);
    } catch (e) {
      _imagePreloaded[imageUrl] = false;
      _checkAndMarkPostReady(postId);
    }
  }

  Future<void> _preloadFirebaseImageWithSDK(
      String imageUrl, String postId) async {
    try {
      final ref = FirebaseStorage.instance.refFromURL(imageUrl);
      const maxSize = 2 * 1024 * 1024;
      final Uint8List? bytes = await ref.getData(maxSize);
      if (bytes != null && bytes.isNotEmpty) {
        final provider = MemoryImage(bytes);
        await _loadImageIntoMemory(provider);
        _loadedImageProviders[imageUrl] = provider;
        _imagePreloaded[imageUrl] = true;
      } else {
        throw Exception('Firebase SDK returned null or empty bytes');
      }
    } catch (e) {
      await _preloadFirebaseImageAlternative(imageUrl, postId);
    }
  }

  Future<void> _preloadFirebaseImageAlternative(
      String imageUrl, String postId) async {
    try {
      final uri = Uri.parse(imageUrl);
      final parts = uri.path.split('/o/');
      if (parts.length >= 2) {
        final storagePath = Uri.decodeFull(parts[1]);
        final ref = FirebaseStorage.instance.ref().child(storagePath);
        const maxSize = 2 * 1024 * 1024;
        final Uint8List? bytes = await ref.getData(maxSize);
        if (bytes != null && bytes.isNotEmpty) {
          final provider = MemoryImage(bytes);
          await _loadImageIntoMemory(provider);
          _loadedImageProviders[imageUrl] = provider;
          _imagePreloaded[imageUrl] = true;
        }
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _preloadRegularImage(String imageUrl, String postId) async {
    try {
      final cachedFile = await FeedCacheService.getCachedImageFile(imageUrl);
      if (cachedFile != null) {
        final provider = FileImage(cachedFile);
        await _loadImageIntoMemory(provider);
        _loadedImageProviders[imageUrl] = provider;
        _imagePreloaded[imageUrl] = true;
        return;
      }

      final file = await DefaultCacheManager().getSingleFile(
        imageUrl,
        headers: const {'Cache-Control': 'max-age=604800', 'Pragma': 'cache'},
      );
      if (file.existsSync()) {
        _cachedImageInfo[imageUrl] = FileInfo(
          file,
          FileSource.Online,
          DateTime.now().add(const Duration(days: 7)),
          imageUrl,
        );
        final provider = FileImage(file);
        await _loadImageIntoMemory(provider);
        _loadedImageProviders[imageUrl] = provider;
        _imagePreloaded[imageUrl] = true;
      } else {
        throw Exception('Image file does not exist: $imageUrl');
      }
    } catch (e) {
      rethrow;
    }
  }

  void _checkAndMarkPostReady(String postId) {
    final post = _forYouPosts.firstWhere(
      (p) => p['postId']?.toString() == postId,
      orElse: () => _followingPosts.firstWhere(
        (p) => p['postId']?.toString() == postId,
        orElse: () => {},
      ),
    );
    if (post.isEmpty) return;

    final postUrl = post['postUrl']?.toString() ?? '';
    final imageUrls = _getAllImageUrlsFromPost(post);
    bool allMediaReady = true;

    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      if (_feedVideoControllersInitialized[postUrl] != true) {
        allMediaReady = false;
      }
    }
    for (final imageUrl in imageUrls) {
      if (_imagePreloaded[imageUrl] != true) {
        allMediaReady = false;
        break;
      }
    }

    if (allMediaReady) {
      _postsBeingPreloaded.remove(postId);
      _postsFullyPreloaded.add(postId);
      if (mounted) setState(() => _postReadyToShow[postId] = true);
    }
  }

  Future<void> _loadImageIntoMemory(ImageProvider imageProvider) async {
    try {
      final stream = imageProvider.resolve(ImageConfiguration.empty);
      final completer = Completer<void>();
      final listener = ImageStreamListener(
        (_, __) => completer.complete(),
        onError: (_, __) => completer.complete(),
      );
      stream.addListener(listener);
      await completer.future.timeout(const Duration(seconds: 5));
      stream.removeListener(listener);
    } catch (_) {}
  }

  ImageProvider? _getPreloadedImageProvider(String imageUrl) =>
      _loadedImageProviders[imageUrl];

  // ===========================================================================
  // VIDEO CONTROLLER
  // ===========================================================================

  Future<void> _initializeFeedVideoController(
      String videoUrl, String postId) async {
    if (_videoInitializationFutures.containsKey(videoUrl)) {
      await _videoInitializationFutures[videoUrl];
      return;
    }
    if (_feedVideoControllers.containsKey(videoUrl) &&
        _feedVideoControllersInitialized[videoUrl] == true) {
      return;
    }

    final completer = Completer<void>();
    _videoInitializationFutures[videoUrl] = completer.future;

    try {
      VideoPlayerController controller;

      final cachedFile = await FeedCacheService.getCachedVideoFile(videoUrl);
      if (cachedFile != null) {
        controller = VideoPlayerController.file(
          cachedFile,
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
      } else {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(videoUrl),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
      }

      _feedVideoControllers[videoUrl] = controller;
      _feedVideoControllersInitialized[videoUrl] = false;

      await controller.initialize().timeout(
            const Duration(seconds: 15),
            onTimeout: () =>
                throw TimeoutException('Video initialization timeout'),
          );

      await controller.setVolume(1.0);
      await controller.pause();

      _feedVideoControllersInitialized[videoUrl] = true;
      _checkAndMarkPostReady(postId);
      completer.complete();
    } catch (e) {
      try {
        _feedVideoControllers.remove(videoUrl)?.dispose();
      } catch (_) {}
      _feedVideoControllersInitialized.remove(videoUrl);
      _videoInitializationFutures.remove(videoUrl);
      completer.completeError(e);
    } finally {
      _videoInitializationFutures.remove(videoUrl);
    }
  }

  VideoPlayerController? _getPreloadedVideoController(String videoUrl) =>
      _feedVideoControllers[videoUrl];

  bool _isVideoControllerInitialized(String videoUrl) =>
      _feedVideoControllersInitialized[videoUrl] == true;

  // ===========================================================================
  // VISIBLE / PRELOAD WINDOW
  // ===========================================================================

  void _updateVisiblePosts(int centerIndex) {
    final currentPosts = _selectedTab == 1 ? _forYouPosts : _followingPosts;
    if (currentPosts.isEmpty) return;

    final preloadStart = max(0, centerIndex - _mediaPreloadBehind);
    final preloadEnd =
        min(currentPosts.length - 1, centerIndex + _mediaPreloadAhead);

    final postsToPreload = <Map<String, dynamic>>[];
    for (int i = preloadStart; i <= preloadEnd; i++) {
      if (i < currentPosts.length) {
        final post = currentPosts[i];
        final postId = post['postId']?.toString() ?? '';
        if (postId.isNotEmpty &&
            !_postsFullyPreloaded.contains(postId) &&
            !_postsBeingPreloaded.contains(postId)) {
          postsToPreload.add(post);
        }
      }
    }
    if (postsToPreload.isNotEmpty) _preloadAllMediaForPosts(postsToPreload);

    final visibleStart = max(0, centerIndex - 1);
    final visibleEnd = min(currentPosts.length - 1, centerIndex + 1);
    _visiblePosts.clear();
    for (int i = visibleStart; i <= visibleEnd; i++) {
      if (i < currentPosts.length) _visiblePosts.add(currentPosts[i]);
    }

    _cleanupUnusedMediaControllers(
        preloadStart - 3, preloadEnd + 3, currentPosts);

    if (mounted) setState(() => _currentVisibleIndex = centerIndex);
  }

  void _cleanupUnusedMediaControllers(int preloadStart, int preloadEnd,
      List<Map<String, dynamic>> currentPosts) {
    final preloadedUrls = <String>{};
    for (int i = preloadStart; i <= preloadEnd; i++) {
      if (i >= 0 && i < currentPosts.length) {
        final post = currentPosts[i];
        final postUrl = post['postUrl']?.toString() ?? '';
        if (postUrl.isNotEmpty) preloadedUrls.add(postUrl);
        for (final url in _getAllImageUrlsFromPost(post)) {
          preloadedUrls.add(url);
        }
      }
    }

    final videoUrlsToRemove = <String>[];
    for (final url in _feedVideoControllers.keys) {
      final isInAnyPost =
          currentPosts.any((p) => p['postUrl']?.toString() == url);
      if (!isInAnyPost && !preloadedUrls.contains(url)) {
        videoUrlsToRemove.add(url);
      }
    }
    for (final url in videoUrlsToRemove) {
      final controller = _feedVideoControllers.remove(url);
      _feedVideoControllersInitialized.remove(url);
      _videoInitializationFutures.remove(url);
      if (controller != null && controller.value.isInitialized) {
        try {
          controller.pause();
          Future.delayed(const Duration(milliseconds: 100), () {
            try {
              controller.dispose();
            } catch (_) {}
          });
        } catch (_) {}
      }
    }

    final keysToRemove = _feedVideoControllers.entries
        .where((e) => !e.value.value.isInitialized)
        .map((e) => e.key)
        .toList();
    for (final key in keysToRemove) {
      _feedVideoControllers.remove(key);
      _feedVideoControllersInitialized.remove(key);
      _videoInitializationFutures.remove(key);
    }

    if (_loadedImageProviders.length > 100) {
      for (final url in _loadedImageProviders.keys
          .where((u) => !preloadedUrls.contains(u))
          .toList()) {
        _loadedImageProviders.remove(url);
        _imagePreloaded.remove(url);
        _cachedImageInfo.remove(url);
      }
    }
  }

  // ===========================================================================
  // VIEW RECORDING
  // ===========================================================================

  Future<void> _scheduleViewRecording(String postId) async {
    _pendingViews.add(postId);
    if (!_viewRecordingScheduled) {
      _viewRecordingScheduled = true;
      await Future.delayed(const Duration(seconds: 1));
      await _recordPendingViews();
    }
  }

  Future<void> _recordPendingViews() async {
    if (_pendingViews.isEmpty || !mounted) {
      _viewRecordingScheduled = false;
      return;
    }
    final viewsToRecord = _pendingViews.toList();
    _pendingViews.clear();
    try {
      final userId = currentUserId ?? '';
      await _supabase.from('user_post_views').upsert(
            viewsToRecord
                .map((postId) => ({
                      'user_id': userId,
                      'post_id': postId,
                      'viewed_at': DateTime.now().toUtc().toIso8601String(),
                    }))
                .toList(),
          );
      setState(() => _postViewCount += viewsToRecord.length);
      if (_postViewCount >= 10) {
        _showInterstitialAd();
        _postViewCount = 0;
      }
    } catch (e) {
      // Ignore error
    } finally {
      _viewRecordingScheduled = false;
    }
  }

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _appStartTime = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    VideoManager.pauseAllVideos();
    FeedCacheService.resetSession();
    _followingPageController = PageController();
    _forYouPageController = PageController();
    _tryLoadCacheWithPersistedUserId();
    _loadInterstitialAd();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      VideoManager.pauseAllVideos();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final resolvedId = userProvider.firebaseUid ?? userProvider.supabaseUid;

    if (resolvedId != null && resolvedId.isNotEmpty) {
      unawaited(FeedCacheService.persistLastUserId(resolvedId));

      if (currentUserId == null) {
        currentUserId = resolvedId;
        _unreadCountStream = _createUnreadCountStream();
        _loadInitialData();
      } else if (currentUserId != resolvedId) {
        currentUserId = resolvedId;
        unawaited(FeedCacheService.clearCache(resolvedId));
        _forYouPosts = [];
        _followingPosts = [];
        _essentialUiReady = false;
        _cacheLoaded = false;
        _cacheLoadAttempted = false;
        _immediatePostsCached = false;
        _immediateCachedPostIds = {};
        _unreadCountStream = _createUnreadCountStream();
        _loadInitialData();
      }
    } else if (currentUserId == null) {
      _loadInitialData();
    }
  }

  // ===========================================================================
  // STARTUP CACHE LOADING
  // ===========================================================================

  Future<void> _tryLoadCacheWithPersistedUserId() async {
    if (_cacheLoadAttempted) return;
    _cacheLoadAttempted = true;

    final persistedId = FeedCacheService.getLastUserIdSync();

    if (persistedId == null || persistedId.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _essentialUiReady = true);
      });
      return;
    }

    try {
      List<Map<String, dynamic>>? posts =
          await FeedCacheService.loadImmediatelyCachedPosts(
        persistedId,
        skipUserIdCheck: true,
      );
      posts ??= await FeedCacheService.loadCachedForYouPosts(persistedId);

      if (posts != null && posts.isNotEmpty) {
        final seenPosts = await FeedCacheService.getSeenPosts(persistedId);
        if (seenPosts.isNotEmpty) {
          posts = posts
              .where((p) => !seenPosts.contains(p['postId']?.toString()))
              .toList();
        }

        if (posts.isEmpty) {
          _essentialUiReady = true;
          if (mounted) setState(() {});
          return;
        }

        _cacheLoaded = true;
        currentUserId ??= persistedId;

        _immediateCachedPostIds = posts
            .map((p) => p['postId']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();

        if (mounted) {
          setState(() {
            _forYouPosts = posts!;
            _essentialUiReady = true;
          });

          if (_appStartTime != null) {
            _appStartTime = null;
          }

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _postsBeingPreloaded.clear();
            _postsFullyPreloaded.clear();
            final toPreload = posts!.length > 3 ? posts.sublist(0, 3) : posts;
            _preloadAllMediaForPosts(toPreload);

            if (_forYouPosts.isNotEmpty) {
              final firstPostId =
                  _forYouPosts.first['postId']?.toString() ?? '';
              if (firstPostId.isNotEmpty) {
                _postVisibility[firstPostId] = true;
                _currentPlayingPostId = firstPostId;
                _firstVideoInitialized = false;
                _updateVisiblePosts(0);
              }
            }

            // FIX 4 — Flush cached posts into user_post_views immediately so
            // the DB-side seen filter stays in sync even if the app was killed
            // before the previous session's view records were committed.
            final userId = currentUserId;
            if (userId != null && userId.isNotEmpty) {
              for (final p in posts.take(3)) {
                final id = p['postId']?.toString() ?? '';
                if (id.isNotEmpty) _pendingViews.add(id);
              }
              unawaited(_recordPendingViews());
            }
          });
        }
      } else {
        _essentialUiReady = true;
        if (mounted) setState(() {});
      }
    } catch (e) {
      _essentialUiReady = true;
      if (mounted) setState(() {});
    }
  }

  Stream<int> _createUnreadCountStream() {
    _unreadCountController?.close();
    _unreadCountTimer?.cancel();
    _unreadCountController = StreamController<int>.broadcast();
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _unreadCountController!.add(0);
      return _unreadCountController!.stream;
    }

    _unreadCountTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final data = await _supabase
            .from('messages')
            .select('id')
            .eq('receiver_id', userId)
            .eq('is_read', false);
        final int count = (data is List) ? data.length : 0;
        if (!(_unreadCountController?.isClosed ?? true)) {
          _unreadCountController!.add(count);
        }
      } catch (e) {
        if (!(_unreadCountController?.isClosed ?? true)) {
          _unreadCountController!.add(0);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final data = await _supabase
            .from('messages')
            .select('id')
            .eq('receiver_id', userId)
            .eq('is_read', false);
        final int count = (data is List) ? data.length : 0;
        if (!(_unreadCountController?.isClosed ?? true)) {
          _unreadCountController!.add(count);
        }
      } catch (e) {
        if (!(_unreadCountController?.isClosed ?? true)) {
          _unreadCountController!.add(0);
        }
      }
    });

    return _unreadCountController!.stream;
  }

  Future<void> _bulkFetchUsers(List<Map<String, dynamic>> posts) async {
    final Set<String> userIds = {};
    for (final post in posts) {
      final uid = post['uid']?.toString() ?? '';
      if (uid.isNotEmpty && !_userCache.containsKey(uid)) userIds.add(uid);
    }
    if (userIds.isEmpty) return;
    try {
      final response = await _supabase
          .from('users')
          .select('uid, username, photoUrl')
          .inFilter('uid', userIds.toList());
      for (final user in response) {
        final m = Map<String, dynamic>.from(user);
        _userCache[m['uid']] = m;
      }
    } catch (e) {
      // Ignore error
    }
  }

  void _updatePostVisibility(
      int page, List<Map<String, dynamic>> posts, bool isForYou) {
    if (!mounted || posts.isEmpty) return;

    final previouslyPlayingPostId = _currentPlayingPostId;
    String? newPlayingPostId;

    setState(() {
      for (final post in posts) {
        final id = post['postId']?.toString() ?? '';
        if (id.isNotEmpty) _postVisibility[id] = false;
      }
      if (page < posts.length) {
        final id = posts[page]['postId']?.toString() ?? '';
        if (id.isNotEmpty) {
          _postVisibility[id] = true;
          newPlayingPostId = id;
          unawaited(_scheduleViewRecording(id));
          if (page == 0 && isForYou && !_firstVideoInitialized) {
            _firstVideoInitialized = true;
          }
        }
      }
      if (page > 0) {
        final id = posts[page - 1]['postId']?.toString() ?? '';
        if (id.isNotEmpty) _postVisibility[id] = true;
      }
      if (page < posts.length - 1) {
        final id = posts[page + 1]['postId']?.toString() ?? '';
        if (id.isNotEmpty) _postVisibility[id] = true;
      }
      _updateVisiblePosts(page);
    });

    if (newPlayingPostId != null &&
        newPlayingPostId != previouslyPlayingPostId) {
      _currentPlayingPostId = newPlayingPostId;
      if (previouslyPlayingPostId != null) VideoManager.pauseAllVideos();
    }

    if (isForYou) unawaited(_delayedCacheUpdate());
  }

  Future<void> _delayedCacheUpdate() async {
    _delayedCacheUpdateTimer?.cancel();
    _delayedCacheUpdateTimer = Timer(const Duration(seconds: 2), () async {
      if (!mounted) return;
      if (_nextForYouBatch.isEmpty && !_nextBatchLoaded) {
        _nextForYouBatch = await _loadNextForYouBatch();
        _nextBatchLoaded = true;
      }
      final userId = currentUserId;
      if (_nextForYouBatch.isNotEmpty && userId != null) {
        await FeedCacheService.safeCacheUpdate(
            userId, _forYouPosts, _nextForYouBatch);
      }
    });
  }

  void _onPageChanged(int page, bool isForYou) {
    if (isForYou) {
      _currentForYouPage = page;
      _updatePostVisibility(page, _forYouPosts, true);
    } else {
      _currentFollowingPage = page;
      _updatePostVisibility(page, _followingPosts, false);
    }

    final currentPosts = isForYou ? _forYouPosts : _followingPosts;
    final postsToPreload = <Map<String, dynamic>>[];
    for (int i = 1; i <= 3; i++) {
      final nextPage = page + i;
      if (nextPage < currentPosts.length) {
        final post = currentPosts[nextPage];
        final id = post['postId']?.toString() ?? '';
        if (id.isNotEmpty &&
            !_postsFullyPreloaded.contains(id) &&
            !_postsBeingPreloaded.contains(id)) {
          postsToPreload.add(post);
        }
      }
    }
    if (postsToPreload.isNotEmpty) _preloadAllMediaForPosts(postsToPreload);

    final hasMore = isForYou ? _hasMoreForYou : _hasMoreFollowing;
    if (page >= currentPosts.length - 3 && hasMore && !_isLoadingMore) {
      _loadData(loadMore: true);
    }
  }

  void _openComments(BuildContext context, Map<String, dynamic> post) {
    final postId = post['postId']?.toString() ?? '';
    final isVideo = _isVideoFile(post['postUrl']?.toString() ?? '');
    final postImage = post['postUrl']?.toString() ?? '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => CommentsBottomSheet(
        postId: postId,
        postImage: postImage,
        isVideo: isVideo,
        onClose: () {},
      ),
    );
  }

  // ===========================================================================
  // MODIFIED: premium check added to prevent loading ads for premium users
  // ===========================================================================
  void _loadInterstitialAd() async {
    // Don't load ads for premium users
    final isPremium = await IAPService().isPurchased();
    if (isPremium) return;

    InterstitialAd.load(
      adUnitId: AdHelper.feedInterstitialAdUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _interstitialAd!.fullScreenContentCallback =
              FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              _loadInterstitialAd();
            },
            onAdFailedToShowFullScreenContent: (ad, _) {
              ad.dispose();
              _loadInterstitialAd();
            },
          );
        },
        onAdFailedToLoad: (_) {
          Future.delayed(const Duration(seconds: 30), _loadInterstitialAd);
        },
      ),
    );
  }

  // ===========================================================================
  // MODIFIED: premium check added to prevent showing ads for premium users
  // ===========================================================================
  void _showInterstitialAd() async {
    // Don't show ads for premium users
    final isPremium = await IAPService().isPurchased();
    if (isPremium) return;

    final now = DateTime.now();
    if (_lastInterstitialAdTime != null &&
        now.difference(_lastInterstitialAdTime!) <
            const Duration(minutes: 10)) {
      return;
    }
    if (_interstitialAd != null) {
      _interstitialAd!.show();
      _lastInterstitialAdTime = now;
    } else {
      _loadInterstitialAd();
    }
  }

  Future<void> _loadBlockedUsers() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _blockedUsers = [];
      return;
    }
    final now = DateTime.now();
    if (_blockedUsersCache[userId] != null &&
        _lastBlockedUsersCacheTime != null &&
        now.difference(_lastBlockedUsersCacheTime!) <
            const Duration(minutes: 5)) {
      _blockedUsers = _blockedUsersCache[userId]!;
      return;
    }
    try {
      final raw = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', userId)
          .maybeSingle();
      final res = _unwrapResponse(raw);
      if (res != null && res is Map) {
        final blocked = res['blockedUsers'];
        if (blocked is List) {
          _blockedUsers = blocked.map((e) => e.toString()).toList();
        } else if (blocked is String) {
          try {
            _blockedUsers =
                (jsonDecode(blocked) as List).map((e) => e.toString()).toList();
          } catch (_) {
            _blockedUsers = [];
          }
        } else {
          _blockedUsers = [];
        }
      } else {
        _blockedUsers = [];
      }
      _blockedUsersCache[userId] = _blockedUsers;
      _lastBlockedUsersCacheTime = now;
    } catch (e) {
      _blockedUsers = [];
    }
  }

  Future<void> _loadFollowingIds() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) {
      _followingIds = [];
      return;
    }
    try {
      final raw = await _supabase
          .from('user_following')
          .select('following_id')
          .eq('user_id', userId);
      final res = _unwrapResponse(raw);
      if (res is List) {
        _followingIds =
            res.map((row) => row['following_id'].toString()).toList();
      } else {
        _followingIds = [];
      }
    } catch (e) {
      _followingIds = [];
    }
  }

  // ===========================================================================
  // INITIAL DATA LOAD
  // ===========================================================================

  Future<void> _loadInitialData() async {
    if (!mounted) return;
    try {
      if (currentUserId == null || currentUserId!.isEmpty) {
        final userProvider = Provider.of<UserProvider>(context, listen: false);
        currentUserId =
            userProvider.firebaseUid ?? userProvider.supabaseUid ?? '';
      }

      if (_cacheLoaded && _forYouPosts.isNotEmpty) {
        // FIX 2 — schedule the prefetch with a delay so in-flight view records
        // have time to commit to user_post_views before we query the DB.
        _schedulePrefetch();
        if (currentUserId == null || currentUserId!.isEmpty) {
          _blockedUsers = [];
        } else {
          await _loadBlockedUsers();
        }
        await _loadData();
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (currentUserId == null || currentUserId!.isEmpty) {
        _blockedUsers = [];
      } else {
        await _loadBlockedUsers();
      }
      await _loadData();
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _essentialUiReady = true;
        });
      }
    }
  }

  // FIX 2 — Prefetch helper: waits 3 seconds before firing so that the views
  // recorded for the current batch have time to land in user_post_views.  This
  // prevents the prefetch RPC from seeing posts that are about to be marked as
  // seen, which was the root cause of seen posts reappearing.
  void _schedulePrefetch() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      _nextForYouBatch = await _loadNextForYouBatch();
      _nextBatchLoaded = true;
    });
  }

  // FIX 1 — The next batch now uses the same offset as the current feed
  // position (not _offsetForYou + _initialBatchSize), because _offsetForYou
  // is no longer used for For You pagination.  The SQL relies on
  // user_post_views for exclusion, so passing offset 0 is correct: every call
  // will naturally skip already-seen posts server-side.
  Future<List<Map<String, dynamic>>> _loadNextForYouBatch() async {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) return [];
    try {
      final excludedUsers = [..._blockedUsers, userId];
      final raw = await _supabase.rpc('get_for_you_feed_test', params: {
        'current_user_id': userId,
        'excluded_users': excludedUsers,
        // FIX 3 — always offset 0; user_post_views handles deduplication.
        'page_offset': 0,
        'page_limit': _initialBatchSize,
      });
      final res = _unwrapResponse(raw);
      if (res is List) {
        final rawPosts = res.map<Map<String, dynamic>>((post) {
          final m = <String, dynamic>{};
          (post as Map).forEach((k, v) {
            if (k.toString() == 'postScore') {
              m['score'] = v;
            } else {
              m[k.toString()] = v;
            }
          });
          m['postId'] = m['postId']?.toString();
          return m;
        }).toList();
        return await _enrichPostsWithEditMetadata(rawPosts);
      }
    } catch (e) {
      // Error loading next batch
    }
    return [];
  }

  // ===========================================================================
  // POST SEEN TRACKING + AUTOMATIC CACHE REFRESH
  // ===========================================================================

  void _onPostSeen(String postId) {
    final userId = currentUserId;
    if (userId == null || userId.isEmpty) return;
    FeedCacheService.markPostAsSeen(postId, userId);
    if (_immediateCachedPostIds.remove(postId) &&
        _immediateCachedPostIds.isEmpty) {
      unawaited(_refreshImmediateCache(userId));
    }
  }

  Future<void> _refreshImmediateCache(String userId) async {
    final seenPosts = await FeedCacheService.getSeenPosts(userId);

    List<Map<String, dynamic>> candidates = _forYouPosts
        .where((p) => !seenPosts.contains(p['postId']?.toString()))
        .take(3)
        .toList();

    if (candidates.isEmpty && _nextForYouBatch.isNotEmpty) {
      candidates = _nextForYouBatch
          .where((p) => !seenPosts.contains(p['postId']?.toString()))
          .take(3)
          .toList();
    }

    if (candidates.isEmpty) return;

    _immediateCachedPostIds = candidates
        .map((p) => p['postId']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    unawaited(FeedCacheService.cacheCurrentPostsNow(candidates, userId));
  }

  // ===========================================================================
  // MAIN DATA LOADER
  // ===========================================================================

  Future<void> _loadData({bool loadMore = false}) async {
    if ((_selectedTab == 1 && !_hasMoreForYou && loadMore) ||
        (_selectedTab == 0 && !_hasMoreFollowing && loadMore) ||
        _isLoadingMore) {
      return;
    }

    // FIX 2 — Flush any pending view records before fetching more posts so
    // the DB exclusion filter sees the most up-to-date seen set.
    if (loadMore && _pendingViews.isNotEmpty) {
      await _recordPendingViews();
    }

    if (mounted) setState(() => _isLoadingMore = true);

    try {
      List<Map<String, dynamic>> newPosts = [];
      final userId = currentUserId ?? '';

      if (userId.isNotEmpty) {
        unawaited(FeedCacheService.persistLastUserId(userId));
      }

      final excludedUsers = [..._blockedUsers, userId];

      if (_selectedTab == 0) {
        // ── Following tab: uses cursor-based offset pagination ──────────────
        if (_followingIds.isEmpty) {
          setState(() {
            _hasMoreFollowing = false;
            _isLoadingMore = false;
          });
          return;
        }
        try {
          final raw = await _supabase.rpc('get_following_feed', params: {
            'current_user_id': userId,
            'excluded_users': excludedUsers,
            'following_ids': _followingIds,
            'page_offset': _offsetFollowing,
            'page_limit': _initialBatchSize,
          });
          final res = _unwrapResponse(raw);
          if (res is List) {
            final rawPosts = res.map<Map<String, dynamic>>((post) {
              final m = <String, dynamic>{};
              (post as Map).forEach((k, v) => m[k.toString()] = v);
              m['postId'] = m['postId']?.toString();
              return m;
            }).toList();
            newPosts = await _enrichPostsWithEditMetadata(rawPosts);
          }
        } catch (rpcErr) {}
        _offsetFollowing += newPosts.length;
        _hasMoreFollowing = newPosts.isNotEmpty;
      } else {
        // ── For You tab: offset is always 0; SQL uses user_post_views ────────
        try {
          final raw = await _supabase.rpc('get_for_you_feed_test', params: {
            'current_user_id': userId,
            'excluded_users': excludedUsers,
            // FIX 3 — offset always 0 for For You; the SQL OFFSET clauses have
            // been removed from the stored function; exclusion is handled
            // entirely by the LEFT JOIN on user_post_views.
            'page_offset': 0,
            'page_limit': _initialBatchSize,
          });
          final res = _unwrapResponse(raw);

          if (res is List) {
            final rawPosts = res.map<Map<String, dynamic>>((post) {
              final m = <String, dynamic>{};
              (post as Map).forEach((k, v) {
                if (k.toString() == 'postScore') {
                  m['score'] = v;
                } else {
                  m[k.toString()] = v;
                }
              });
              m['postId'] = m['postId']?.toString();
              return m;
            }).toList();
            newPosts = await _enrichPostsWithEditMetadata(rawPosts);
          }
        } catch (rpcErr) {
          // RPC error
        }

        _hasMoreForYou = newPosts.isNotEmpty;

        // FIX 2 — Replace the immediate unawaited prefetch with a delayed one
        // so view records have time to commit before the next RPC call.
        _schedulePrefetch();
      }

      if (!loadMore) {
        _postsBeingPreloaded.clear();
        _postsFullyPreloaded.clear();
        final toPreload =
            newPosts.length > 3 ? newPosts.sublist(0, 3) : newPosts;
        _preloadAllMediaForPosts(toPreload);
      } else {
        _preloadAllMediaForPosts(newPosts);
      }

      for (final post in newPosts) _cachePost(post);

      if (mounted) {
        setState(() {
          if (_selectedTab == 0) {
            _followingPosts =
                loadMore ? [..._followingPosts, ...newPosts] : newPosts;
          } else {
            if (loadMore) {
              // Dedupe by postId to guard against any overlap between batches.
              final existingIds = _forYouPosts
                  .map((p) => p['postId']?.toString())
                  .whereType<String>()
                  .toSet();
              final dedupedNew = newPosts
                  .where((p) => !existingIds.contains(p['postId']?.toString()))
                  .toList();
              _forYouPosts = [..._forYouPosts, ...dedupedNew];
            } else if (_cacheLoaded && _forYouPosts.isNotEmpty) {
              final existingIds = _forYouPosts
                  .map((p) => p['postId']?.toString())
                  .whereType<String>()
                  .toSet();
              final dedupedNew = newPosts
                  .where((p) => !existingIds.contains(p['postId']?.toString()))
                  .toList();
              _forYouPosts = [..._forYouPosts, ...dedupedNew];
            } else {
              _forYouPosts = newPosts;
            }
          }
          _isLoadingMore = false;
        });

        if (!loadMore &&
            _selectedTab == 1 &&
            !_immediatePostsCached &&
            userId.isNotEmpty &&
            newPosts.isNotEmpty) {
          _immediatePostsCached = true;
          final toImmediateCache = newPosts.take(3).toList();
          _immediateCachedPostIds = toImmediateCache
              .map((p) => p['postId']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet();
          unawaited(
              FeedCacheService.cacheCurrentPostsNow(toImmediateCache, userId));
        }

        if (!loadMore &&
            _selectedTab == 1 &&
            _appStartTime != null &&
            newPosts.isNotEmpty) {
          _appStartTime = null;
        }

        unawaited(_bulkFetchUsers(newPosts));

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || loadMore) return;
          final currentPage =
              _selectedTab == 1 ? _currentForYouPage : _currentFollowingPage;
          final currentPosts =
              _selectedTab == 1 ? _forYouPosts : _followingPosts;

          _updateVisiblePosts(currentPage);

          if (_selectedTab == 1 && currentPosts.isNotEmpty && !_cacheLoaded) {
            final firstPostId = currentPosts.first['postId']?.toString() ?? '';
            if (firstPostId.isNotEmpty) {
              setState(() {
                _postVisibility[firstPostId] = true;
                _currentPlayingPostId = firstPostId;
                _firstVideoInitialized = false;
              });
              unawaited(_scheduleViewRecording(firstPostId));
            }
          }
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final currentPage =
              _selectedTab == 1 ? _currentForYouPage : _currentFollowingPage;
          final currentPosts =
              _selectedTab == 1 ? _forYouPosts : _followingPosts;
          _updatePostVisibility(currentPage, currentPosts, _selectedTab == 1);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
          _isLoading = false;
        });
      }
    }
  }

  // ===========================================================================
  // TAB SWITCHING
  // ===========================================================================

  void _switchTab(int index) {
    if (_selectedTab == index) return;
    _pauseCurrentVideo();
    _currentPlayingPostId = null;
    _firstVideoInitialized = false;
    _prefetchTimer?.cancel();

    for (final controller in _feedVideoControllers.values) {
      controller.dispose();
    }
    _feedVideoControllers.clear();
    _feedVideoControllersInitialized.clear();
    _videoInitializationFutures.clear();
    _loadedImageProviders.clear();
    _imagePreloaded.clear();
    _cachedImageInfo.clear();
    _visiblePosts.clear();
    _postReadyToShow.clear();
    _postsBeingPreloaded.clear();
    _postsFullyPreloaded.clear();

    setState(() {
      _selectedTab = index;
      _isLoading = true;
      _showOverlay = true;
    });

    if (index == 0) {
      _offsetFollowing = 0;
      _followingPosts.clear();
      _hasMoreFollowing = true;
      _currentFollowingPage = 0;
      if (!_followingIdsLoaded) {
        _followingIdsLoaded = true;
        _loadFollowingIds().then((_) => _loadData()).then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      } else {
        _loadData().then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      }
    } else {
      _forYouPosts.clear();
      _hasMoreForYou = true;
      _currentForYouPage = 0;
      _nextForYouBatch = [];
      _nextBatchLoaded = false;
      _loadData().then((_) {
        if (mounted) setState(() => _isLoading = false);
      });
    }
  }

  // ===========================================================================
  // DISPOSE
  // ===========================================================================

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VideoManager.pauseAllVideos();
    _currentPlayingPostId = null;
    _firstVideoInitialized = false;

    _followingPageController.dispose();
    _forYouPageController.dispose();
    _interstitialAd?.dispose();
    _unreadCountTimer?.cancel();
    _unreadCountController?.close();
    _delayedCacheUpdateTimer?.cancel();
    _prefetchTimer?.cancel();

    for (final controller in _feedVideoControllers.values) {
      try {
        if (controller.value.isInitialized) {
          controller.pause();
          controller.dispose();
        }
      } catch (_) {}
    }
    _feedVideoControllers.clear();
    _feedVideoControllersInitialized.clear();
    _videoInitializationFutures.clear();
    _loadedImageProviders.clear();
    _imagePreloaded.clear();
    _cachedImageInfo.clear();
    _postReadyToShow.clear();
    _postsBeingPreloaded.clear();
    _postsFullyPreloaded.clear();

    super.dispose();
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  bool _shouldPostPlayVideo(String postId) =>
      postId == _currentPlayingPostId && (_postVisibility[postId] == true);

  VideoPlayerController? _getVideoControllerForPost(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      return _getPreloadedVideoController(postUrl);
    }
    return null;
  }

  bool _isVideoPreloadedAndReady(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    if (postUrl.isNotEmpty && _isVideoFile(postUrl)) {
      return _isVideoControllerInitialized(postUrl);
    }
    return false;
  }

  bool _isImagePreloadedAndReady(Map<String, dynamic> post) {
    final postUrl = post['postUrl']?.toString() ?? '';
    if (postUrl.isNotEmpty &&
        _isImageFile(postUrl) &&
        _imagePreloaded[postUrl] == true &&
        _loadedImageProviders.containsKey(postUrl)) {
      return true;
    }
    for (final imageUrl in _getAllImageUrlsFromPost(post)) {
      if (_imagePreloaded[imageUrl] == true &&
          _loadedImageProviders.containsKey(imageUrl)) {
        return true;
      }
    }
    return false;
  }

  void _navigateToMessages() {
    VideoManager.pauseAllVideos();
    _currentPlayingPostId = null;
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? userId = userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to view messages')),
      );
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => FeedMessages()),
      );
    });
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final width = MediaQuery.of(context).size.width;

    if (!_essentialUiReady) {
      final isDark = colors.backgroundColor == const Color(0xFF121212);
      return FeedSkeleton(isDark: isDark);
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      body: Stack(
        children: [
          _buildFeedBody(colors),
          if (width <= webScreenSize)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: _buildOverlayContent(colors),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOverlayContent(_ColorSet colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTabItem(1, 'For You', colors),
                const SizedBox(width: 40),
                _buildTabItem(0, 'Following', colors),
              ],
            ),
          ),
          Positioned(right: 0, child: _buildMessageButton(colors)),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label, _ColorSet colors) {
    final isSelected = _selectedTab == index;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        _switchTab(index);
        _showInterstitialAd();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 16,
                fontFamily: 'Inter',
              ),
            ),
            const SizedBox(height: 4),
            Container(
              height: 2,
              width: 60,
              decoration: BoxDecoration(
                color: isSelected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageButton(_ColorSet colors) {
    return GestureDetector(
      onTap: _navigateToMessages,
      child: StreamBuilder<int>(
        stream: _unreadCountStream,
        builder: (context, snapshot) {
          final count = snapshot.data ?? 0;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Material(
                color: Colors.transparent,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                  icon: Icon(Icons.message, color: colors.iconColor, size: 24),
                  onPressed: _navigateToMessages,
                ),
              ),
              if (count > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    constraints:
                        const BoxConstraints(minWidth: 20, minHeight: 20),
                    decoration: BoxDecoration(
                      color: colors.cardColor,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        _formatMessageCount(count),
                        style: TextStyle(
                          color: colors.textColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFeedBody(_ColorSet colors) {
    return SizedBox.expand(
      child: _selectedTab == 1
          ? _buildForYouFeed(colors)
          : _buildFollowingFeed(colors),
    );
  }

  Widget _buildFollowingFeed(_ColorSet colors) {
    if (_isLoading && _followingPosts.isEmpty) {
      return _buildLoadingFeed(colors);
    }
    if (!_isLoading && _followingIds.isEmpty) {
      return _buildNoFollowingMessage(colors);
    }
    return _buildPostsPageView(
        _followingPosts, _followingPageController, colors, false);
  }

  Widget _buildForYouFeed(_ColorSet colors) {
    if (_isLoading && _forYouPosts.isEmpty) return _buildLoadingFeed(colors);
    if (_forYouPosts.isNotEmpty) {
      return _buildPostsPageView(
          _forYouPosts, _forYouPageController, colors, true);
    }
    return _buildLoadingFeed(colors);
  }

  Widget _buildLoadingFeed(_ColorSet colors) {
    final isDark = colors.backgroundColor == const Color(0xFF121212);
    return FeedSkeleton(isDark: isDark);
  }

  Widget _buildNoFollowingMessage(_ColorSet colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Text(
          'Follow users to see their posts here!',
          style: TextStyle(
            color: colors.textColor.withOpacity(0.7),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildPostsPageView(
    List<Map<String, dynamic>> posts,
    PageController controller,
    _ColorSet colors,
    bool isForYou,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        if (scrollInfo is ScrollUpdateNotification) {
          final current = scrollInfo.metrics.pixels;
          final diff = current - _lastScrollOffset;
          if (diff > 5 && _showOverlay) {
            setState(() => _showOverlay = false);
          } else if (diff < -5 && !_showOverlay) {
            setState(() => _showOverlay = true);
          }
          _lastScrollOffset = current;
        }
        return false;
      },
      child: PageView.builder(
        controller: controller,
        scrollDirection: Axis.vertical,
        itemCount: posts.length + (_isLoadingMore ? 1 : 0),
        onPageChanged: (page) => _onPageChanged(page, isForYou),
        itemBuilder: (ctx, index) {
          if (index >= posts.length) {
            return Center(
              child: CircularProgressIndicator(color: colors.textColor),
            );
          }
          final post = posts[index];
          final postId = post['postId']?.toString() ?? '';
          final postUrl = post['postUrl']?.toString() ?? '';
          final isVisible = _shouldPostPlayVideo(postId);

          return Container(
            width: double.infinity,
            height: double.infinity,
            color: colors.backgroundColor,
            child: PostCard(
              snap: post,
              isVisible: isVisible,
              onCommentTap: () => _openComments(context, post),
              onPostSeen: isForYou ? () => _onPostSeen(postId) : null,
              preloadedVideoController: _getVideoControllerForPost(post),
              isVideoPreloaded: _isVideoPreloadedAndReady(post),
              preloadedImageProvider: _getPreloadedImageProvider(postUrl),
              isImagePreloaded: _isImagePreloadedAndReady(post),
            ),
          );
        },
      ),
    );
  }

  String _formatMessageCount(int count) {
    if (count < 1000) return count.toString();
    if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '${count ~/ 1000}k';
  }
}
