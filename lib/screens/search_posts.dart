import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/widgets/postshare.dart';
import 'package:Ratedly/widgets/rating_list_screen_postcard.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/resources/reactions_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:Ratedly/services/analytics_service.dart'; // ✅ screen tracking

// ─────────────────────────────────────────────────────────────────────────────
// Global video manager – ensures only one video plays at a time
// ─────────────────────────────────────────────────────────────────────────────
void unawaited(Future<void> future) {}

class VideoManager {
  static final VideoManager _instance = VideoManager._internal();
  factory VideoManager() => _instance;
  VideoManager._internal();

  VideoPlayerController? _currentPlayingController;
  String? _currentPostId;
  final Map<String, VideoPlayerController> _activeControllers = {};

  static void pauseAllVideos() => _instance._pauseAllVideos();

  void playVideo(VideoPlayerController controller, String postId) {
    if (_currentPlayingController != null &&
        _currentPlayingController != controller) {
      _currentPlayingController!.pause();
    }
    _currentPlayingController = controller;
    _currentPostId = postId;
    _activeControllers[postId] = controller;
    controller.play();
  }

  void pauseVideo(VideoPlayerController controller) {
    if (_currentPlayingController == controller) {
      controller.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.removeWhere((key, value) => value == controller);
  }

  void disposeController(VideoPlayerController controller, String postId) {
    if (_currentPlayingController == controller) {
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.remove(postId);
    controller.pause();
    controller.dispose();
  }

  bool isCurrentlyPlaying(VideoPlayerController controller) =>
      _currentPlayingController == controller;

  void onPostInvisible(String postId) {
    if (_currentPostId == postId && _currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.remove(postId);
  }

  String? get currentPlayingPostId => _currentPostId;

  void pauseCurrentVideo() {
    if (_currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
  }

  void _pauseAllVideos() {
    if (_currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.forEach((postId, controller) {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        controller.pause();
      }
    });
    _activeControllers.clear();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED EDITING / DRAWING CLASSES (normally from edit_shared.dart)
// ─────────────────────────────────────────────────────────────────────────────

class FilterAdjustments {
  final double brightness;
  final double contrast;
  final double saturation;

  FilterAdjustments({
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
  });

  List<double> combinedMatrix(List<double> baseMatrix) {
    final b = brightness;
    final c = contrast;
    final s = saturation;
    return [
      c * s,
      0,
      0,
      0,
      b,
      0,
      c * s,
      0,
      0,
      b,
      0,
      0,
      c * s,
      0,
      b,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      };

  factory FilterAdjustments.fromJson(Map<String, dynamic> json) =>
      FilterAdjustments(
        brightness: (json['brightness'] as num?)?.toDouble() ?? 0.0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
      );
}

class FilterInfo {
  final String name;
  final List<double> matrix;
  const FilterInfo({required this.name, required this.matrix});
}

const List<FilterInfo> kFilters = [
  FilterInfo(name: 'Original', matrix: [
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
  ]),
];

class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;

  DrawStroke({
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => {'dx': p.dx, 'dy': p.dy}).toList(),
        'color': color.value,
        'width': width,
        'isEraser': isEraser,
      };

  factory DrawStroke.fromJson(Map<String, dynamic> json) => DrawStroke(
        points: (json['points'] as List)
            .map((p) => Offset(p['dx'] as double, p['dy'] as double))
            .toList(),
        color: Color(json['color'] as int),
        width: (json['width'] as num).toDouble(),
        isEraser: json['isEraser'] as bool? ?? false,
      );
}

class TextOverlay {
  final String text;
  final Offset position;
  final Color color;
  final double fontSize;
  final String fontFamily;

  TextOverlay({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
    this.fontFamily = 'Roboto',
  });

  TextOverlay copyWith({double? fontSize}) => TextOverlay(
        text: text,
        position: position,
        color: color,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'dx': position.dx,
        'dy': position.dy,
        'color': color.value,
        'fontSize': fontSize,
        'fontFamily': fontFamily,
      };

  factory TextOverlay.fromJson(Map<String, dynamic> json) => TextOverlay(
        text: json['text'] as String,
        position: Offset(
            (json['dx'] as num).toDouble(), (json['dy'] as num).toDouble()),
        color: Color(json['color'] as int),
        fontSize: (json['fontSize'] as num).toDouble(),
        fontFamily: json['fontFamily'] as String? ?? 'Roboto',
      );
}

class VideoEditResult {
  final FilterAdjustments adjustments;
  final int filterIndex;
  final int rotationQuarters;
  final List<DrawStroke> strokes;
  final List<TextOverlay> overlays;
  final File file;

  VideoEditResult({
    required this.adjustments,
    required this.filterIndex,
    required this.rotationQuarters,
    required this.strokes,
    required this.overlays,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
        'adjustments': adjustments.toJson(),
        'filterIndex': filterIndex,
        'rotationQuarters': rotationQuarters,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'overlays': overlays.map((o) => o.toJson()).toList(),
      };

  factory VideoEditResult.fromJson(Map<String, dynamic> json, File file) =>
      VideoEditResult(
        adjustments: FilterAdjustments.fromJson(
            json['adjustments'] as Map<String, dynamic>),
        filterIndex: json['filterIndex'] as int,
        rotationQuarters: json['rotationQuarters'] as int? ?? 0,
        strokes: (json['strokes'] as List? ?? [])
            .map((s) => DrawStroke.fromJson(s as Map<String, dynamic>))
            .toList(),
        overlays: (json['overlays'] as List? ?? [])
            .map((o) => TextOverlay.fromJson(o as Map<String, dynamic>))
            .toList(),
        file: file,
      );
}

TextStyle overlayTextStyle(TextOverlay overlay) => TextStyle(
      color: overlay.color,
      fontSize: overlay.fontSize,
      fontFamily: overlay.fontFamily,
    );

TextStyle overlayShadowStyle(TextOverlay overlay) => TextStyle(
      color: Colors.black.withOpacity(0.5),
      fontSize: overlay.fontSize,
      fontFamily: overlay.fontFamily,
    );

class DrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final DrawStroke? currentStroke;

  DrawingPainter({required this.strokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!);
    }
  }

  void _drawStroke(Canvas canvas, DrawStroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.isEraser ? Colors.transparent : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;
    for (int i = 0; i < stroke.points.length - 1; i++) {
      canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) => true;
}

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

// ─────────────────────────────────────────────────────────────────────────────
// SearchResultFeedScreen  (full-screen vertical PageView)
// ─────────────────────────────────────────────────────────────────────────────

class SearchResultFeedScreen extends StatefulWidget {
  final List<Map<String, dynamic>> initialPosts;
  final int initialIndex;
  final Future<List<Map<String, dynamic>>> Function(int currentCount)
      onLoadMore;
  final bool initialHasMore;

  const SearchResultFeedScreen({
    Key? key,
    required this.initialPosts,
    required this.initialIndex,
    required this.onLoadMore,
    required this.initialHasMore,
  }) : super(key: key);

  @override
  State<SearchResultFeedScreen> createState() => _SearchResultFeedScreenState();
}

class _SearchResultFeedScreenState extends State<SearchResultFeedScreen> {
  late List<Map<String, dynamic>> _posts;
  late PageController _pageController;
  late int _currentIndex;
  bool _hasMore = false;
  bool _loadingMore = false;
  final String _sessionId = DateTime.now().microsecondsSinceEpoch.toString();
  String? _currentUserId; // ✅ screen tracking

  bool _isVideoUrl(String url) {
    final u = url.toLowerCase();
    return u.endsWith('.mp4') ||
        u.endsWith('.mov') ||
        u.endsWith('.avi') ||
        u.endsWith('.wmv') ||
        u.endsWith('.flv') ||
        u.endsWith('.mkv') ||
        u.endsWith('.webm') ||
        u.endsWith('.m4v') ||
        u.endsWith('.3gp') ||
        u.contains('/video/') ||
        u.contains('video=true');
  }

  @override
  void initState() {
    super.initState();
    // ✅ screen tracking: enter search_feed screen
    AnalyticsService.screenEnter('search_feed');

    // Get current user ID
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    _currentUserId = userProvider.firebaseUid ?? userProvider.supabaseUid;

    _posts = List.from(widget.initialPosts);
    _hasMore = widget.initialHasMore;
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);
  }

  @override
  void dispose() {
    // ✅ screen tracking: exit search_feed screen
    if (_currentUserId != null && _currentUserId!.isNotEmpty) {
      AnalyticsService.screenExit(
        screenName: 'search_feed',
        uid: _currentUserId!,
      );
    }
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final rawPage = _pageController.page ?? _currentIndex.toDouble();
    final page = rawPage.round();
    if (page != _currentIndex) {
      // ✅ FIX: stop all videos before switching active page
      VideoManager.pauseAllVideos();
      setState(() => _currentIndex = page);
    }
    if (page >= _posts.length - 3 && _hasMore && !_loadingMore) {
      _triggerLoadMore();
    }
  }

  Future<void> _triggerLoadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final batch = await widget.onLoadMore(_posts.length);
      if (mounted) {
        setState(() {
          _posts.addAll(batch);
          _hasMore = batch.isNotEmpty;
          _loadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;

    final itemCount = _posts.length + (_hasMore || _loadingMore ? 1 : 0);

    return Scaffold(
      resizeToAvoidBottomInset: false,   // ← prevents feed from shifting on keyboard
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: const Text('Search Results'),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index >= _posts.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: CircularProgressIndicator(color: textColor),
              ),
            );
          }
          final post = _posts[index];
          final Map<String, dynamic> userData = {
            'uid': post['uid']?.toString() ?? '',
            'username': post['username']?.toString() ?? '',
            'photoUrl': post['photoUrl']?.toString() ?? '',
            'isVerified': post['isVerified'] ?? false,
            'country': post['country']?.toString() ?? '',
          };
          return _FeedPostPage(
            key: ValueKey(post['postId']),
            post: post,
            userData: userData,
            isActive: index == _currentIndex,
            sessionId: _sessionId,
            onPostDeleted: null,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FeedPostPage  (single post in the vertical feed)
// ─────────────────────────────────────────────────────────────────────────────

class _FeedPostPage extends StatefulWidget {
  final Map<String, dynamic> post;
  final Map<String, dynamic> userData;
  final bool isActive;
  final String sessionId;
  final VoidCallback? onPostDeleted;

  const _FeedPostPage({
    Key? key,
    required this.post,
    required this.userData,
    required this.isActive,
    required this.sessionId,
    this.onPostDeleted,
  }) : super(key: key);

  @override
  State<_FeedPostPage> createState() => _FeedPostPageState();
}

class _FeedPostPageState extends State<_FeedPostPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();
  final VideoManager _videoManager = VideoManager(); // ← SINGLETON

  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = false;
  bool _isMuted = false;

  double _averageRating = 0.0;
  int _totalRatingsCount = 0;
  double? _userRating;
  bool _isLoadingRatings = true;
  String _reactionEmoji = '❤️';
  int _commentCount = 0;

  VideoEditResult? _editResult;
  bool _dataFetched = false;

  String get _postUrl => widget.post['postUrl']?.toString() ?? '';
  String get _postId => widget.post['postId']?.toString() ?? '';

  bool get _isVideo {
    final u = _postUrl.toLowerCase();
    return u.endsWith('.mp4') ||
        u.endsWith('.mov') ||
        u.endsWith('.avi') ||
        u.endsWith('.wmv') ||
        u.endsWith('.flv') ||
        u.endsWith('.mkv') ||
        u.endsWith('.webm') ||
        u.endsWith('.m4v') ||
        u.endsWith('.3gp') ||
        u.contains('/video/') ||
        u.contains('video=true');
  }

  // ------ NEW getter to check if THIS video is playing ------
  bool get _isVideoPlaying =>
      _videoController != null &&
      _videoManager.isCurrentlyPlaying(_videoController!);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // ← lifecycle observer
    _parseEditMetadata();
    _fetchAllData();
    if (widget.isActive) _onBecomeActive();
  }

  @override
  void didUpdateWidget(_FeedPostPage old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _onBecomeActive();
    } else if (!widget.isActive && old.isActive) {
      _onBecomeInactive();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeVideoController();
    super.dispose();
  }

  // ----- APP LIFECYCLE: pause when app goes to background -----
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseVideo();
    }
  }

  // ----- VIDEO LIFE CYCLE -----
  void _onBecomeActive() {
    if (_isVideo) {
      if (_isVideoInitialized) {
        _playVideo();
      } else if (!_isVideoLoading) {
        _initVideo();
      }
    }
  }

  void _onBecomeInactive() {
    _pauseVideo();
  }

  // ----- PLAY / PAUSE using VideoManager -----
  void _playVideo() {
    if (_videoController != null &&
        _isVideoInitialized &&
        mounted &&
        widget.isActive) {
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      _videoManager.playVideo(_videoController!, _postId);
      setState(() {});
    }
  }

  void _pauseVideo() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      _videoManager.pauseVideo(_videoController!);
      setState(() {});
    }
  }

  void _togglePlayback() {
    if (!_isVideoInitialized || _videoController == null) return;
    if (_isVideoPlaying) {
      _pauseVideo();
    } else {
      _playVideo();
    }
    setState(() {});
  }

  void _toggleMute() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      _isMuted = !_isMuted;
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  // ----- CLEANUP -----
  void _disposeVideoController() {
    if (_videoController != null) {
      _videoController!.removeListener(_videoListener);
      if (_isVideoPlaying) {
        _videoManager.pauseVideo(_videoController!);
      }
      _videoController!.pause();
      _videoController!.dispose();
      _videoController = null;
    }
    _isVideoInitialized = false;
    _isVideoLoading = false;
  }

  // ----- LISTENER (keeps UI in sync with manager) -----
  void _videoListener() {
    if (!mounted) return;
    // If video ended, loop it and keep playing if still active
    if (_videoController != null &&
        _videoController!.value.position == _videoController!.value.duration &&
        _videoController!.value.duration != Duration.zero) {
      _videoController!.seekTo(Duration.zero);
      if (widget.isActive && !_isVideoPlaying) {
        _videoController!.play();
      }
    }
    // Sync the actual play state with the manager
    if (_videoController != null && _isVideoInitialized) {
      final actuallyPlaying = _videoController!.value.isPlaying;
      final shouldBePlaying =
          _videoManager.isCurrentlyPlaying(_videoController!);
      if (actuallyPlaying != shouldBePlaying && widget.isActive) {
        if (shouldBePlaying && !actuallyPlaying) {
          _videoController!.play();
        } else if (!shouldBePlaying && actuallyPlaying) {
          _videoController!.pause();
        }
      }
    }
  }

  void _parseEditMetadata() {
    final raw = widget.post['video_edit_metadata'];
    if (raw == null) return;
    try {
      final map = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      _editResult = VideoEditResult.fromJson(map, File(''));
    } catch (_) {}
  }

  Future<void> _fetchAllData() async {
    if (_dataFetched) return;
    _dataFetched = true;
    await Future.wait([
      _fetchRatings(),
      _fetchReactionEmoji(),
      _fetchCommentsCount(),
    ]);
  }

  Future<void> _fetchRatings() async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    try {
      final ratings = await _supabase
          .from('post_rating')
          .select()
          .eq('postid', _postId) as List<dynamic>;

      double avg = 0;
      double? userRating;
      if (ratings.isNotEmpty) {
        final total = ratings.fold<double>(
            0, (s, r) => s + (r['rating'] as num).toDouble());
        avg = total / ratings.length;
        if (user != null) {
          for (final r in ratings) {
            if (r['userid'] == user.uid) {
              userRating = (r['rating'] as num).toDouble();
              break;
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _totalRatingsCount = ratings.length;
          _averageRating = avg;
          _userRating = userRating;
          _isLoadingRatings = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingRatings = false);
    }
  }

  Future<void> _fetchReactionEmoji() async {
    try {
      final resp = await _supabase
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', _postId)
          .maybeSingle();
      if (mounted && resp != null) {
        final emoji = resp['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() => _reactionEmoji = emoji);
        }
      }
    } catch (_) {}
  }

  Future<void> _fetchCommentsCount() async {
    try {
      final comments = await _supabase
          .from('comments')
          .select('id')
          .eq('postid', _postId) as List<dynamic>;
      final replies = await _supabase
          .from('replies')
          .select('id')
          .eq('postid', _postId) as List<dynamic>;
      if (mounted) {
        setState(() => _commentCount = comments.length + replies.length);
      }
    } catch (_) {}
  }

  Future<void> _initVideo() async {
    if (_isVideoLoading || _isVideoInitialized || _postUrl.isEmpty) return;

    setState(() => _isVideoLoading = true);

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(_postUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      await controller.initialize();
      controller.setLooping(true);
      controller.addListener(_videoListener); // ← attach listener

      if (mounted) {
        setState(() {
          _videoController = controller;
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        if (widget.isActive) {
          _playVideo(); // ← use manager
        }
      } else {
        controller.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  void _handleRatingSubmitted(double rating) async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;

    final oldRating = _userRating;
    final isUpdating = oldRating != null;

    setState(() {
      _userRating = rating;
      final currentTotal = _averageRating * _totalRatingsCount;
      if (isUpdating) {
        _averageRating =
            (currentTotal - oldRating! + rating) / _totalRatingsCount;
      } else {
        _totalRatingsCount++;
        _averageRating = (currentTotal + rating) / _totalRatingsCount;
      }
    });

    try {
      final res = await SupabaseReactionsMethods()
          .reactToPost(_postId, user.uid, rating);
      if (res != 'success' && mounted) _fetchRatings();
    } catch (_) {
      if (mounted) _fetchRatings();
    }
  }

  List<double> _buildColorMatrix() {
    if (_editResult == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return _editResult!.adjustments
        .combinedMatrix(kFilters[_editResult!.filterIndex].matrix);
  }

  void _goToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ProfileScreen(uid: widget.userData['uid']?.toString() ?? ''),
      ),
    );
  }

  void _openRatingsPanel() {
    _pauseVideo(); // ← pause via manager
    debugPrint('[SearchFeed] Opening ratings panel, video paused');

    RatingListScreen.show(
      context,
      postId: _postId,
      isVideo: _isVideo,
      videoController: _videoController,
      onClose: () {
        debugPrint('[SearchFeed] Ratings panel closed');
        if (widget.isActive) {
          _playVideo(); // ← resume via manager
        }
      },
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // BUILD METHOD
  // ───────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    super.build(context);

    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;
    final cardColor = isDark ? const Color(0xFF333333) : Colors.grey[200]!;
    final iconColor = textColor;

    final user = Provider.of<UserProvider>(context).user;
    final isOwner = user != null &&
        (user.uid == widget.userData['uid']?.toString() ||
            user.uid == widget.post['uid']?.toString());

    final dateRaw = widget.post['datePublished'];
    final date = dateRaw is DateTime
        ? dateRaw
        : (dateRaw is String ? DateTime.tryParse(dateRaw) : null);
    final timeStr = date != null ? timeago.format(date) : '';

    final photoUrl = widget.userData['photoUrl']?.toString() ?? '';
    final uid = widget.userData['uid']?.toString() ?? '';
    final matrix = _buildColorMatrix();
    final quarters = _editResult?.rotationQuarters ?? 0;
    final description = widget.post['description']?.toString() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: _goToProfile,
                child: _buildAvatar(
                    photoUrl, uid, user?.uid ?? '', cardColor, textColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: _goToProfile,
                      child: VerifiedUsernameWidget(
                        username: widget.userData['username']?.toString() ?? '',
                        uid: uid,
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: textColor),
                      ),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(timeStr,
                          style: TextStyle(
                              color: textColor.withOpacity(0.6), fontSize: 12)),
                  ],
                ),
              ),
              if (isOwner && widget.onPostDeleted != null)
                IconButton(
                  icon: Icon(Icons.more_vert, color: iconColor),
                  onPressed: () =>
                      _showOptionsMenu(context, bgColor, textColor),
                ),
            ],
          ),
        ),

        // ── Media (fills remaining space) ──
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return _buildMedia(matrix, quarters, cardColor, textColor,
                  maxHeight: constraints.maxHeight);
            },
          ),
        ),

        // ── Fixed bottom area – always visible ──
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              description,
              style: TextStyle(color: textColor, fontSize: 15),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

        if (!_isLoadingRatings)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: RatingBar(
              averageRating: _averageRating,
              reactionEmoji: _reactionEmoji,
              initialThumbPosition: _userRating == null ? 5.0 : _averageRating,
              onRatingEnd: _handleRatingSubmitted,
              hasUserRated: _userRating != null,
              userRating: _userRating,
              userProfilePhoto:
                  user?.photoUrl ?? '', // ★ YOUR profile picture here
            ),
          )
        else
          const SizedBox(height: 48),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: Icon(Icons.comment_outlined,
                        color: iconColor, size: 28),
                    onPressed: () => _showComments(context),
                  ),
                  if (_commentCount > 0)
                    Positioned(
                      top: -6,
                      left: -6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        constraints:
                            const BoxConstraints(minWidth: 20, minHeight: 20),
                        decoration: BoxDecoration(
                            color: cardColor, shape: BoxShape.circle),
                        child: Center(
                          child: Text(
                            _commentCount.toString(),
                            style: TextStyle(
                                color: textColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.send, color: iconColor),
                onPressed: () {
                  if (user != null) {
                    showDialog(
                      context: context,
                      builder: (_) =>
                          PostShare(currentUserId: user.uid, postId: _postId),
                    );
                  }
                },
              ),
              const Spacer(),
              GestureDetector(
                onTap: isOwner ? () => _openRatingsPanel() : null,
                child: Container(
                  decoration: BoxDecoration(
                      color: cardColor, borderRadius: BorderRadius.circular(4)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    _totalRatingsCount == 0
                        ? 'Be the first to react'
                        : '$_totalRatingsCount '
                            '${_totalRatingsCount == 1 ? 'voter' : 'voters'}',
                    style: TextStyle(
                        fontSize: 13,
                        color: textColor,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildAvatar(String photoUrl, String uid, String currentUserId,
      Color cardColor, Color textColor) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    return CircleAvatar(
      radius: 20,
      backgroundColor: cardColor,
      backgroundImage: !isDefault ? CachedNetworkImageProvider(photoUrl) : null,
      child: isDefault
          ? Icon(Icons.account_circle, size: 40, color: textColor)
          : null,
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Media builders now accept an optional maxHeight to crop when needed
  // ───────────────────────────────────────────────────────────────────────────

  Widget _buildMedia(
      List<double> matrix, int quarters, Color cardColor, Color textColor,
      {double? maxHeight}) {
    if (_isVideo)
      return _buildVideoPlayer(matrix, quarters, cardColor, textColor,
          maxHeight: maxHeight);
    return _buildImage(matrix, quarters, cardColor, textColor,
        maxHeight: maxHeight);
  }

  // ── UPDATED VIDEO PLAYER WITH TAP‑TO‑PAUSE AND PLAY OVERLAY ──────────
  Widget _buildVideoPlayer(
      List<double> matrix, int quarters, Color cardColor, Color textColor,
      {double? maxHeight}) {
    final double videoAspect = (_isVideoInitialized && _videoController != null)
        ? _videoController!.value.aspectRatio
        : 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double naturalHeight = width / videoAspect;
        final double containerHeight = maxHeight != null
            ? math.min(naturalHeight, maxHeight)
            : naturalHeight;
        final bool needsCropping =
            maxHeight != null && naturalHeight > maxHeight;

        return SizedBox(
          width: width,
          height: containerHeight,
          child: ClipRect(
            child: Container(
              color: Colors.black,
              child: GestureDetector(
                // Tapping the video toggles play/pause
                onTap: _togglePlayback,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isVideoInitialized && _videoController != null)
                      ColorFiltered(
                        colorFilter: ColorFilter.matrix(matrix),
                        child: Transform.rotate(
                          angle: quarters * math.pi / 2,
                          child: needsCropping
                              ? FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _videoController!.value.size.width,
                                    height: _videoController!.value.size.height,
                                    child: VideoPlayer(_videoController!),
                                  ),
                                )
                              : VideoPlayer(_videoController!),
                        ),
                      )
                    else if (_isVideoLoading)
                      Center(child: CircularProgressIndicator(color: textColor))
                    else
                      Center(
                          child:
                              Icon(Icons.videocam, color: textColor, size: 48)),

                    // Video edit strokes
                    if (_editResult != null && _editResult!.strokes.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: DrawingPainter(
                                strokes: _editResult!.strokes,
                                currentStroke: null),
                          ),
                        ),
                      ),
                    // Video edit overlays
                    if (_editResult != null && _editResult!.overlays.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: LayoutBuilder(
                            builder: (_, overlayConstraints) => Stack(
                              children: _editResult!.overlays.map((o) {
                                return Positioned(
                                  left: (o.position.dx *
                                          overlayConstraints.maxWidth)
                                      .clamp(0.0,
                                          overlayConstraints.maxWidth - 10),
                                  top: (o.position.dy *
                                          overlayConstraints.maxHeight)
                                      .clamp(0.0,
                                          overlayConstraints.maxHeight - 10),
                                  child:
                                      Stack(clipBehavior: Clip.none, children: [
                                    Text(o.text, style: overlayShadowStyle(o)),
                                    Text(o.text, style: overlayTextStyle(o)),
                                  ]),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),

                    // 🎬 PLAY BUTTON OVERLAY (shown when paused)
                    if (_isVideoInitialized && !_isVideoPlaying)
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            size: 40,
                            color: Colors.white,
                          ),
                        ),
                      ),

                    // 🔊 Mute button
                    if (_isVideoInitialized)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: GestureDetector(
                          onTap: _toggleMute,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                                color: Colors.black54, shape: BoxShape.circle),
                            child: Icon(
                              _isMuted ? Icons.volume_off : Icons.volume_up,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildImage(
      List<double> matrix, int quarters, Color cardColor, Color textColor,
      {double? maxHeight}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double naturalHeight = width; // square image
        final double containerHeight = maxHeight != null
            ? math.min(naturalHeight, maxHeight)
            : naturalHeight;
        final bool needsCropping =
            maxHeight != null && naturalHeight > maxHeight;

        return SizedBox(
          width: width,
          height: containerHeight,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                InteractiveViewer(
                  panEnabled: true,
                  scaleEnabled: true,
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(matrix),
                    child: Transform.rotate(
                      angle: quarters * math.pi / 2,
                      child: needsCropping
                          ? FittedBox(
                              fit: BoxFit.cover,
                              child: CachedNetworkImage(
                                imageUrl: _postUrl,
                                width: width,
                                height: width,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    Container(color: cardColor),
                                errorWidget: (_, __, ___) => Container(
                                  color: cardColor,
                                  child: Icon(Icons.broken_image,
                                      color: textColor, size: 48),
                                ),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: _postUrl,
                              width: width,
                              height: width,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: cardColor),
                              errorWidget: (_, __, ___) => Container(
                                color: cardColor,
                                child: Icon(Icons.broken_image,
                                    color: textColor, size: 48),
                              ),
                            ),
                    ),
                  ),
                ),
                if (_editResult != null &&
                    (_editResult!.strokes.isNotEmpty ||
                        _editResult!.overlays.isNotEmpty))
                  Positioned.fill(
                    child: IgnorePointer(
                      child: LayoutBuilder(
                        builder: (_, overlayConstraints) => Stack(
                          children: [
                            if (_editResult!.strokes.isNotEmpty)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: DrawingPainter(
                                      strokes: _editResult!.strokes,
                                      currentStroke: null),
                                ),
                              ),
                            ..._editResult!.overlays.map((o) {
                              return Positioned(
                                left: (o.position.dx *
                                        overlayConstraints.maxWidth)
                                    .clamp(
                                        0.0, overlayConstraints.maxWidth - 10),
                                top: (o.position.dy *
                                        overlayConstraints.maxHeight)
                                    .clamp(
                                        0.0, overlayConstraints.maxHeight - 10),
                                child:
                                    Stack(clipBehavior: Clip.none, children: [
                                  Text(o.text, style: overlayShadowStyle(o)),
                                  Text(o.text, style: overlayTextStyle(o)),
                                ]),
                              );
                            }),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showComments(BuildContext context) {
    _pauseVideo(); // ← pause via manager
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsBottomSheet(
        postId: _postId,
        postImage: _postUrl,
        isVideo: _isVideo,
        onClose: () {
          if (widget.isActive) _playVideo(); // ← resume via manager
        },
        videoController: _videoController,
      ),
    ).then((_) => _fetchCommentsCount());
  }

  void _showOptionsMenu(BuildContext context, Color bgColor, Color textColor) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: bgColor,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          shrinkWrap: true,
          children: [
            InkWell(
              onTap: () async {
                Navigator.of(context).pop();
                await _deletePost(context);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Text('Delete',
                    style: TextStyle(color: Colors.red[400], fontSize: 15)),
              ),
            ),
            InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Text('Cancel',
                    style: TextStyle(color: textColor, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deletePost(BuildContext context) async {
    try {
      await _postsMethods.deletePost(_postId);
      widget.onPostDeleted?.call();
    } catch (e) {
      if (mounted) showSnackBar(context, 'Failed to delete post: $e');
    }
  }
}
