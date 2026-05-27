import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/screens/messaging_screen.dart';
import 'package:Ratedly/screens/Profile_page/blocked_profile_screen.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/gestures.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:country_flags/country_flags.dart';
import 'package:Ratedly/screens/Profile_page/gallery_post_view_screen.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/Profile_page/profile_post_feed_screen.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart'; // ✅ Import shared editing classes

// -----------------------------------------------------------------------------
// Color definitions (same as original)
// -----------------------------------------------------------------------------
class _OtherProfileColorSet {
  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color progressIndicatorColor;
  final Color avatarBackgroundColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color dividerColor;
  final Color dialogBackgroundColor;
  final Color dialogTextColor;
  final Color errorTextColor;
  final Color radioActiveColor;
  final Color skeletonColor;

  _OtherProfileColorSet({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.progressIndicatorColor,
    required this.avatarBackgroundColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.dividerColor,
    required this.dialogBackgroundColor,
    required this.dialogTextColor,
    required this.errorTextColor,
    required this.radioActiveColor,
    required this.skeletonColor,
  });
}

class _OtherProfileDarkColors extends _OtherProfileColorSet {
  _OtherProfileDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          textColor: const Color(0xFFd9d9d9),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          avatarBackgroundColor: const Color(0xFF333333),
          buttonBackgroundColor: const Color(0xFF333333),
          buttonTextColor: const Color(0xFFd9d9d9),
          dividerColor: const Color(0xFF333333),
          dialogBackgroundColor: const Color(0xFF121212),
          dialogTextColor: const Color(0xFFd9d9d9),
          errorTextColor: Colors.grey,
          radioActiveColor: const Color(0xFFd9d9d9),
          skeletonColor: const Color(0xFF333333),
        );
}

class _OtherProfileLightColors extends _OtherProfileColorSet {
  _OtherProfileLightColors()
      : super(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
          progressIndicatorColor: Colors.grey,
          avatarBackgroundColor: Colors.grey,
          buttonBackgroundColor: Colors.grey,
          buttonTextColor: Colors.black,
          dividerColor: Colors.grey,
          dialogBackgroundColor: Colors.white,
          dialogTextColor: Colors.black,
          errorTextColor: Colors.grey,
          radioActiveColor: Colors.black,
          skeletonColor: Colors.grey,
        );
}

// -----------------------------------------------------------------------------
// Reusable widgets (same as original)
// -----------------------------------------------------------------------------
class CountryFlagWidget extends StatelessWidget {
  final String countryCode;
  final double width;
  final double height;
  final double borderRadius;

  const CountryFlagWidget({
    Key? key,
    required this.countryCode,
    this.width = 16,
    this.height = 12,
    this.borderRadius = 2,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool hasCountryFlag =
        countryCode.isNotEmpty && countryCode.length == 2;
    if (!hasCountryFlag) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: CountryFlag.fromCountryCode(countryCode),
      ),
    );
  }
}

class ExpandableBioText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color expandColor;
  final int maxLength;

  const ExpandableBioText({
    Key? key,
    required this.text,
    required this.style,
    required this.expandColor,
    this.maxLength = 115,
  }) : super(key: key);

  @override
  State<ExpandableBioText> createState() => _ExpandableBioTextState();
}

class _ExpandableBioTextState extends State<ExpandableBioText> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final shouldTruncate = widget.text.length > widget.maxLength;
    if (!shouldTruncate || _isExpanded) {
      return Text(widget.text, style: widget.style);
    }
    final truncatedText = widget.text.substring(0, widget.maxLength);
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(text: '$truncatedText... ', style: widget.style),
          TextSpan(
            text: 'more',
            style: widget.style.copyWith(
              color: widget.expandColor,
              fontWeight: FontWeight.w600,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => setState(() => _isExpanded = true),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Main OtherUserProfileScreen (corrected)
// -----------------------------------------------------------------------------
class OtherUserProfileScreen extends StatefulWidget {
  final String uid;
  const OtherUserProfileScreen({Key? key, required this.uid}) : super(key: key);

  @override
  State<OtherUserProfileScreen> createState() => _OtherUserProfileScreenState();
}

class _OtherUserProfileScreenState extends State<OtherUserProfileScreen>
    with WidgetsBindingObserver {
  final SupabaseClient _supabase = Supabase.instance.client;
  var userData = {};
  int postLen = 0;
  int followers = 0;
  bool isFollowing = false;
  bool isLoading = true;
  bool _isBlockedByMe = false;
  bool _isBlocked = false;
  bool _isBlockedByThem = false;
  bool _isViewerFollower = false;
  bool hasPendingRequest = false;
  List<dynamic> _followersList = [];
  int following = 0;
  bool _isMutualFollow = false;

  // Video controllers (same as current profile screen)
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};
  Timer? _videoInitDebounce;

  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;
  bool _isProfileVideoMuted = false;

  List<dynamic> _galleries = [];
  int _selectedTabIndex = 0;

  List<dynamic> _displayedPosts = [];
  int _postsOffset = 0;
  final int _initialPostsLimit = 9;
  final int _subsequentPostsLimit = 6;
  bool _hasMorePosts = true;
  bool _isLoadingMore = false;
  bool _isFirstLoad = true;

  late ScrollController _scrollController;

  final List<String> profileReportReasons = [
    'Impersonation (Pretending to be someone else)',
    'Fake Account (Misleading or suspicious profile)',
    'Bullying or Harassment',
    'Hate Speech or Discrimination (e.g., race, religion, gender, sexual orientation)',
    'Scam or Fraud (Deceptive activity, phishing, or financial fraud)',
    'Spam (Unwanted promotions or repetitive content)',
    'Inappropriate Content (Explicit, offensive, or disturbing profile)',
  ];

  bool _hasLoaded = false;

  // Logging (optional, kept from original)
  String? _currentSessionId;
  DateTime? _screenOpenAt;
  final Set<String> _loggedPostRenders = {};

  DateTime? _lastLoadMoreTime;
  static const Duration _loadMoreCooldown = Duration(milliseconds: 500);

  Future<void> _sendLog(Map<String, dynamic> payload) async {
    try {
      _currentSessionId ??= DateTime.now().microsecondsSinceEpoch.toString();
      final int elapsedMs =
          _screenOpenAt != null && !payload.containsKey('elapsed_ms')
              ? DateTime.now().difference(_screenOpenAt!).inMilliseconds
              : (payload['elapsed_ms'] as int? ?? 0);
      await _supabase.from('profile_screen_logs').insert({
        'session_id': _currentSessionId,
        'user_id': widget.uid,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'created_at': DateTime.now().toIso8601String(),
        'elapsed_ms': elapsedMs,
        ...payload,
      });
    } catch (_) {}
  }

  _OtherProfileColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? _OtherProfileDarkColors()
        : _OtherProfileLightColors();
  }

  // --------------------------------------------------------------
  // Video helpers (identical to current_profile_screen.dart)
  // --------------------------------------------------------------
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

  Map<String, dynamic>? _extractEditMetadata(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  VideoEditResult? _parseEditResult(Map<String, dynamic> post) {
    final meta = _extractEditMetadata(post['video_edit_metadata']);
    if (meta == null) return null;
    try {
      return VideoEditResult.fromJson(meta, File(''));
    } catch (_) {
      return null;
    }
  }

  List<double> _buildColorMatrix(VideoEditResult? er) {
    if (er == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix);
  }

  Future<void> _initializeVideoController(String videoUrl) async {
    if (_videoControllers.containsKey(videoUrl) ||
        _videoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _videoControllers[videoUrl] = controller;
      _videoControllersInitialized[videoUrl] = false;

      controller.initialize().then((_) {
        if (!mounted || !_videoControllers.containsKey(videoUrl)) return;
        _videoControllersInitialized[videoUrl] = true;
        _configureVideoLoop(controller);
        controller.setVolume(0.0);

        _videoInitDebounce?.cancel();
        _videoInitDebounce = Timer(const Duration(milliseconds: 80), () {
          if (mounted) setState(() {});
        });
      }).catchError((_) {
        _videoControllers.remove(videoUrl)?.dispose();
        _videoControllersInitialized.remove(videoUrl);
      });
    } catch (_) {
      _videoControllers.remove(videoUrl)?.dispose();
      _videoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureVideoLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) controller.seekTo(Duration.zero);
      }
    });
    controller.play();
  }

  VideoPlayerController? _getVideoController(String url) =>
      _videoControllers[url];

  bool _isVideoControllerInitialized(String url) =>
      _videoControllersInitialized[url] == true;

  void _preInitializeVideoControllers(List<dynamic> posts) {
    for (final p in posts) {
      final url = p['postUrl'] ?? '';
      if (_isVideoFile(url)) _initializeVideoController(url);
    }
  }

  Widget _buildEditOverlayLayer(
      VideoEditResult editResult, BoxConstraints constraints) {
    if (editResult.strokes.isEmpty && editResult.overlays.isEmpty) {
      return const SizedBox.shrink();
    }

    final double previewW = constraints.maxWidth;
    final double previewH = constraints.maxHeight;
    final double screenW = MediaQuery.of(context).size.width;
    final double screenH = MediaQuery.of(context).size.height;
    final double scaleX = previewW / screenW;
    final double scaleY = previewH / screenH;
    final double fontScale = math.min(scaleX, scaleY);

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        if (editResult.strokes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _ScaledDrawingPainter(
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

  // --------------------------------------------------------------
  // Profile video
  // --------------------------------------------------------------
  Future<void> _initializeProfileVideo(String videoUrl) async {
    if (_profileVideoController != null) {
      await _profileVideoController!.dispose();
      setState(() {
        _profileVideoController = null;
        _isProfileVideoInitialized = false;
      });
    }
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      await controller.setVolume(1.0);
      await controller.setLooping(true);
      await controller.play();
      if (mounted) {
        setState(() {
          _profileVideoController = controller;
          _isProfileVideoInitialized = true;
          _isProfileVideoMuted = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isProfileVideoInitialized = false);
    }
  }

  Widget _buildProfileVideoPlayer(_OtherProfileColorSet colors) {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: colors.avatarBackgroundColor),
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }
    return Stack(
      children: [
        ClipOval(
          child: SizedBox(
            width: 90,
            height: 90,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _profileVideoController!.value.size.width,
                height: _profileVideoController!.value.size.height,
                child: VideoPlayer(_profileVideoController!),
              ),
            ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: _toggleProfileVideoMute,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: Icon(
                _isProfileVideoMuted ? Icons.volume_off : Icons.volume_up,
                size: 14,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProfilePicture(_OtherProfileColorSet colors) {
    final photoUrl = userData['photoUrl']?.toString() ?? '';
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    final isVideo = !isDefault && _isVideoFile(photoUrl);

    if (isDefault) {
      return CircleAvatar(
        radius: 45,
        backgroundColor: colors.avatarBackgroundColor,
        child: Icon(Icons.account_circle, size: 90, color: colors.iconColor),
      );
    }
    if (isVideo) return _buildProfileVideoPlayer(colors);
    return CircleAvatar(
      backgroundColor: colors.avatarBackgroundColor,
      radius: 45,
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  void _pauseAllVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  void _resumeAllVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isInitialized && !c.value.isPlaying) c.play();
    }
  }

  void _muteProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.setVolume(0.0);
      } catch (_) {}
    }
  }

  void _unmuteProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.setVolume(_isProfileVideoMuted ? 0.0 : 1.0);
      } catch (_) {}
    }
  }

  void _toggleProfileVideoMute() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      setState(() => _isProfileVideoMuted = !_isProfileVideoMuted);
      try {
        _profileVideoController!.setVolume(_isProfileVideoMuted ? 0.0 : 1.0);
      } catch (_) {}
    }
  }

  // --------------------------------------------------------------
  // Lifecycle
  // --------------------------------------------------------------
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasLoaded) {
      _hasLoaded = true;
      _loadDataInParallel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
      _muteProfileVideo();
    } else if (state == AppLifecycleState.resumed) {
      _unmuteProfileVideo();
    }
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 50 &&
        !_isLoadingMore &&
        _hasMorePosts &&
        _selectedTabIndex == 0) {
      Future.delayed(const Duration(milliseconds: 15), () {
        if (mounted) _loadMorePosts();
      });
    }
  }

  // --------------------------------------------------------------
  // Data loading (identical logic to current profile screen)
  // --------------------------------------------------------------
  Future<void> _loadDataInParallel() async {
    _screenOpenAt = DateTime.now();
    await _sendLog({
      'event_type': 'screen_open',
      'client_timestamp': _screenOpenAt!.toIso8601String(),
      'elapsed_ms': 0,
    });

    setState(() => isLoading = true);
    try {
      await Future.wait([
        _loadUserData(),
        _loadPostsCountAndFirstBatch(),
        _loadGalleriesData(),
        _loadBlockStatus(),
      ]);
      if (!_isBlocked && mounted) await _loadRelationshipData();
    } catch (e) {
      unawaited(_sendLog({
        'event_type': 'load_error',
        'error_message': e.toString(),
      }));
      if (mounted) {
        showSnackBar(
            context, "Please try again or contact us at ratedly9@gmail.com");
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }

    unawaited(_sendLog({
      'event_type': 'screen_ready',
      'post_count': postLen,
      'extra': {
        'displayed_posts': _displayedPosts.length,
        'has_more_posts': _hasMorePosts,
        'galleries_count': _galleries.length,
        'is_blocked': _isBlocked,
        'is_following': isFollowing,
      },
    }));
  }

  Future<void> _loadUserData() async {
    try {
      final userResponse =
          await _supabase.from('users').select().eq('uid', widget.uid).single();
      if (mounted) {
        setState(() => userData = userResponse);
        final photoUrl = userResponse['photoUrl'] ?? '';
        if (_isVideoFile(photoUrl)) _initializeProfileVideo(photoUrl);
      }
    } catch (_) {}
  }

  Future<void> _loadGalleriesData() async {
    try {
      final galleriesResponse = await _supabase.from('galleries').select('''
            *,
            gallery_posts(count),
            posts!cover_post_id(postUrl, video_edit_metadata)
          ''').eq('uid', widget.uid).order('created_at', ascending: false);

      for (final g in galleriesResponse) {
        final url = g['posts'] != null ? g['posts']['postUrl'] ?? '' : '';
        if (_isVideoFile(url)) _initializeVideoController(url);
      }
      if (mounted) setState(() => _galleries = galleriesResponse);
    } catch (_) {
      if (mounted) setState(() => _galleries = []);
    }
  }

  Future<void> _loadPostsCountAndFirstBatch() async {
    final countStart = DateTime.now();
    unawaited(_sendLog({
      'event_type': 'api_request',
      'client_timestamp': countStart.toIso8601String(),
      'extra': {'query': 'posts_count', 'uid': widget.uid},
    }));

    try {
      final countResponse = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', widget.uid)
          .count(CountOption.exact);
      final totalPostCount = countResponse.count;

      unawaited(_sendLog({
        'event_type': 'api_response',
        'post_count': totalPostCount,
        'duration_ms': DateTime.now().difference(countStart).inMilliseconds,
        'status_code': 200,
        'extra': {'query': 'posts_count'},
      }));

      final postsLimit =
          _isFirstLoad ? _initialPostsLimit : _subsequentPostsLimit;

      final batchStart = DateTime.now();
      unawaited(_sendLog({
        'event_type': 'api_request',
        'client_timestamp': batchStart.toIso8601String(),
        'extra': {
          'query': 'initial_posts_batch',
          'limit': postsLimit,
          'uid': widget.uid,
        },
      }));

      final initialPosts = await _supabase
          .from('posts')
          .select(
              'postId, postUrl, description, datePublished, uid, viewers_count, video_edit_metadata')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false)
          .range(0, postsLimit - 1);

      final int videoCount =
          initialPosts.where((p) => _isVideoFile(p['postUrl'] ?? '')).length;
      final int imageCount = initialPosts.length - videoCount;

      unawaited(_sendLog({
        'event_type': 'batch_fetched',
        'batch_index': 0,
        'post_count': initialPosts.length,
        'duration_ms': DateTime.now().difference(batchStart).inMilliseconds,
        'status_code': 200,
        'extra': {
          'total_posts_on_profile': totalPostCount,
          'video_count': videoCount,
          'image_count': imageCount,
        },
      }));

      _preInitializeVideoControllers(initialPosts);

      if (mounted) {
        setState(() {
          _displayedPosts = initialPosts;
          postLen = totalPostCount;
          _postsOffset = initialPosts.length;
          _hasMorePosts = totalPostCount > initialPosts.length;
          _isFirstLoad = false;
        });
      }
    } catch (e) {
      unawaited(_sendLog({
        'event_type': 'api_error',
        'error_message': e.toString(),
        'duration_ms': DateTime.now().difference(countStart).inMilliseconds,
        'extra': {'query': 'posts_count_or_initial_batch'},
      }));
      if (mounted) {
        setState(() {
          _displayedPosts = [];
          postLen = 0;
          _hasMorePosts = false;
          _isFirstLoad = false;
        });
      }
    }
  }

  Future<void> _loadBlockStatus() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;

    if (currentUserId == null || currentUserId.isEmpty) {
      if (mounted) {
        setState(() {
          _isBlockedByMe = false;
          _isBlockedByThem = false;
          _isBlocked = false;
        });
      }
      return;
    }

    try {
      final isBlockedByMe = await SupabaseBlockMethods().isBlockInitiator(
          currentUserId: currentUserId, targetUserId: widget.uid);
      final isBlockedByThem = await SupabaseBlockMethods().isUserBlocked(
          currentUserId: currentUserId, targetUserId: widget.uid);

      if (mounted) {
        setState(() {
          _isBlockedByMe = isBlockedByMe;
          _isBlockedByThem = isBlockedByThem;
          _isBlocked = isBlockedByMe || isBlockedByThem;
        });
      }

      if (_isBlocked && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => BlockedProfileScreen(
                  uid: widget.uid, isBlocker: _isBlockedByMe),
            ),
          );
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isBlockedByMe = false;
          _isBlockedByThem = false;
          _isBlocked = false;
        });
      }
    }
  }

  Future<void> _loadRelationshipData() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;

    if (currentUserId == null || currentUserId.isEmpty) {
      if (mounted) {
        setState(() {
          followers = 0;
          following = 0;
          isFollowing = false;
          hasPendingRequest = false;
          _isMutualFollow = false;
        });
      }
      return;
    }

    try {
      final results = await Future.wait<dynamic>([
        _supabase
            .from('user_followers')
            .select('follower_id, followed_at')
            .eq('user_id', widget.uid)
            .then((v) => v as List<dynamic>),
        _supabase
            .from('user_following')
            .select('following_id, followed_at')
            .eq('user_id', widget.uid)
            .then((v) => v as List<dynamic>),
        _supabase
            .from('user_following')
            .select()
            .eq('user_id', currentUserId)
            .eq('following_id', widget.uid)
            .maybeSingle()
            .then((v) => v as Map<String, dynamic>?),
        _supabase
            .from('user_follow_request')
            .select()
            .eq('user_id', widget.uid)
            .eq('requester_id', currentUserId)
            .maybeSingle()
            .then((v) => v as Map<String, dynamic>?),
        _supabase
            .from('user_following')
            .select()
            .eq('user_id', widget.uid)
            .eq('following_id', currentUserId)
            .maybeSingle()
            .then((v) => v as Map<String, dynamic>?),
      ]);

      if (mounted) {
        setState(() {
          followers = (results[0] as List).length;
          following = (results[1] as List).length;
          isFollowing = results[2] != null;
          hasPendingRequest = results[3] != null;
          _isMutualFollow = results[2] != null && results[4] != null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          followers = 0;
          following = 0;
          isFollowing = false;
          hasPendingRequest = false;
          _isMutualFollow = false;
        });
      }
    }
  }

  Future<void> _loadMorePosts() async {
    if (_lastLoadMoreTime != null) {
      final elapsed = DateTime.now().difference(_lastLoadMoreTime!);
      if (elapsed < _loadMoreCooldown) {
        unawaited(_sendLog({
          'event_type': 'load_more_throttled',
          'extra': {
            'elapsed_ms': elapsed.inMilliseconds,
            'cooldown_ms': _loadMoreCooldown.inMilliseconds,
          },
        }));
        return;
      }
    }

    if (!_hasMorePosts || _isLoadingMore) return;

    _lastLoadMoreTime = DateTime.now();
    setState(() => _isLoadingMore = true);

    final batchStart = DateTime.now();
    final int batchIndex = _postsOffset ~/ _subsequentPostsLimit;
    unawaited(_sendLog({
      'event_type': 'api_request',
      'batch_index': batchIndex,
      'client_timestamp': batchStart.toIso8601String(),
      'extra': {
        'query': 'load_more_posts',
        'range_start': _postsOffset,
        'range_end': _postsOffset + _subsequentPostsLimit - 1,
      },
    }));

    try {
      final newPosts = await _supabase
          .from('posts')
          .select(
              'postId, postUrl, description, datePublished, uid, viewers_count, video_edit_metadata')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false)
          .range(_postsOffset, _postsOffset + _subsequentPostsLimit - 1);

      final int videoCount =
          newPosts.where((p) => _isVideoFile(p['postUrl'] ?? '')).length;
      final int imageCount = newPosts.length - videoCount;

      unawaited(_sendLog({
        'event_type': 'batch_fetched',
        'batch_index': batchIndex,
        'post_count': newPosts.length,
        'duration_ms': DateTime.now().difference(batchStart).inMilliseconds,
        'status_code': 200,
        'extra': {
          'video_count': videoCount,
          'image_count': imageCount,
          'new_total_displayed': _displayedPosts.length + newPosts.length,
        },
      }));

      _preInitializeVideoControllers(newPosts);

      if (newPosts.isNotEmpty && mounted) {
        setState(() {
          _displayedPosts.addAll(newPosts);
          _postsOffset += newPosts.length;
          _hasMorePosts = newPosts.length == _subsequentPostsLimit;
        });
      } else {
        if (mounted) setState(() => _hasMorePosts = false);
      }
    } catch (e) {
      unawaited(_sendLog({
        'event_type': 'api_error',
        'batch_index': batchIndex,
        'error_message': e.toString(),
        'duration_ms': DateTime.now().difference(batchStart).inMilliseconds,
        'extra': {'query': 'load_more_posts'},
      }));
      if (mounted) showSnackBar(context, 'Failed to load more posts');
    } finally {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<List<Map<String, dynamic>>> _loadMorePostsForFeed(
      int currentCount) async {
    try {
      final newPosts = await _supabase
          .from('posts')
          .select(
              'postId, postUrl, description, datePublished, uid, viewers_count, video_edit_metadata')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false)
          .range(currentCount, currentCount + _subsequentPostsLimit - 1);

      _preInitializeVideoControllers(newPosts);
      return List<Map<String, dynamic>>.from(newPosts);
    } catch (_) {
      return [];
    }
  }

  // --------------------------------------------------------------
  // Thumbnail builders (identical to current profile screen)
  // --------------------------------------------------------------
  Widget _buildPostVideoPlayer(String videoUrl, _OtherProfileColorSet colors,
      [VideoEditResult? editResult]) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
          color: colors.avatarBackgroundColor,
          child: Center(
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor, strokeWidth: 1.5)));
    }

    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
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
                    child: VideoPlayer(controller)),
              ),
            ),
          ),
        ),
        if (editResult != null)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildEditOverlayLayer(editResult, constraints),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildPostImage(String imageUrl, _OtherProfileColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    Widget baseImage = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: editResult == null
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  color: colors.avatarBackgroundColor,
                  child: Center(
                    child: CircularProgressIndicator(
                      value: loadingProgress.expectedTotalBytes != null
                          ? loadingProgress.cumulativeBytesLoaded /
                              (loadingProgress.expectedTotalBytes ?? 1)
                          : null,
                      color: colors.progressIndicatorColor,
                      strokeWidth: 1.5,
                    ),
                  ),
                );
              },
              errorBuilder: (_, __, ___) => Container(
                color: colors.avatarBackgroundColor,
                child: Center(
                    child: Icon(Icons.broken_image,
                        color: colors.errorTextColor, size: 20)),
              ),
            )
          : ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: Transform.rotate(
                angle: quarters * math.pi / 2,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Container(
                      color: colors.avatarBackgroundColor,
                      child: Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                  (loadingProgress.expectedTotalBytes ?? 1)
                              : null,
                          color: colors.progressIndicatorColor,
                          strokeWidth: 1.5,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (_, __, ___) => Container(
                    color: colors.avatarBackgroundColor,
                    child: Center(
                        child: Icon(Icons.broken_image,
                            color: colors.errorTextColor, size: 20)),
                  ),
                ),
              ),
            ),
    );

    if (editResult == null) return baseImage;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: baseImage),
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _buildEditOverlayLayer(editResult, constraints),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildGalleryVideoPlayer(String videoUrl, _OtherProfileColorSet colors,
      [VideoEditResult? editResult]) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
          color: colors.avatarBackgroundColor,
          child: Center(
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor, strokeWidth: 1.5)));
    }

    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
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
                    child: VideoPlayer(controller)),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildGalleryCoverImage(String imageUrl, _OtherProfileColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    if (editResult == null) {
      return Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: colors.avatarBackgroundColor.withOpacity(0.5)),
          child:
              Icon(Icons.collections, size: 40, color: colors.errorTextColor),
        ),
      );
    }

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix),
      child: Transform.rotate(
        angle: quarters * math.pi / 2,
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: colors.avatarBackgroundColor.withOpacity(0.5)),
            child:
                Icon(Icons.collections, size: 40, color: colors.errorTextColor),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------
  // Follow / Message / Report (unchanged)
  // --------------------------------------------------------------
  void _otherHandleFollow() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (currentUserId == null || currentUserId.isEmpty) {
      if (mounted) showSnackBar(context, "Please sign in to follow users");
      return;
    }
    try {
      final isPrivate = userData['isPrivate'] ?? false;
      if (isFollowing) {
        await SupabaseProfileMethods().unfollowUser(currentUserId, widget.uid);
        if (mounted) {
          setState(() {
            isFollowing = false;
            _isMutualFollow = false;
          });
        }
      } else if (hasPendingRequest) {
        await SupabaseProfileMethods()
            .declineFollowRequest(widget.uid, currentUserId);
        if (mounted) setState(() => hasPendingRequest = false);
      } else {
        await SupabaseProfileMethods().followUser(currentUserId, widget.uid);
        if (isPrivate) {
          if (mounted) setState(() => hasPendingRequest = true);
        } else {
          if (mounted) setState(() => isFollowing = true);
          _checkMutualFollowAfterFollow();
        }
      }
    } catch (_) {
      if (mounted) {
        showSnackBar(
            context, "Please try again or contact us at ratedly9@gmail.com");
      }
    }
  }

  Future<void> _checkMutualFollowAfterFollow() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (currentUserId == null || currentUserId.isEmpty) return;
    final result = await _supabase
        .from('user_following')
        .select()
        .eq('user_id', widget.uid)
        .eq('following_id', currentUserId)
        .maybeSingle();
    if (mounted) setState(() => _isMutualFollow = result != null);
  }

  void _otherNavigateToMessaging() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? userId = userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (userId == null || userId.isEmpty) {
      if (mounted) showSnackBar(context, "Please sign in to message users");
      return;
    }
    _pauseAllVideos();
    _muteProfileVideo();
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MessagingScreen(
            recipientUid: widget.uid,
            recipientUsername: userData['username'] ?? '',
            recipientPhotoUrl: userData['photoUrl'] ?? '',
          ),
        ),
      ).then((_) {
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _resumeAllVideos();
            _unmuteProfileVideo();
          }
        });
      });
    }
  }

  void _showProfileReportDialog(_OtherProfileColorSet colors) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    if (currentUserId == null || currentUserId.isEmpty) {
      if (mounted) showSnackBar(context, "Please sign in to report profiles");
      return;
    }
    String? selectedReason;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: colors.dialogBackgroundColor,
          title: Text('Report Profile',
              style: TextStyle(color: colors.dialogTextColor)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Thank you for helping keep our community safe.\n\nPlease let us know the reason for reporting this content. Your report is anonymous, and our moderators will review it as soon as possible.\n\nIf you prefer not to see this user\'s content, you can choose to block them.',
                  style: TextStyle(color: colors.dialogTextColor, fontSize: 14),
                ),
                const SizedBox(height: 16),
                Text('Select a reason:',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colors.dialogTextColor)),
                ...profileReportReasons.map((reason) => RadioListTile<String>(
                      title: Text(reason,
                          style: TextStyle(color: colors.dialogTextColor)),
                      value: reason,
                      groupValue: selectedReason,
                      activeColor: colors.radioActiveColor,
                      onChanged: (v) => setState(() => selectedReason = v),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel',
                    style: TextStyle(color: colors.dialogTextColor))),
            TextButton(
                onPressed: selectedReason != null
                    ? () => _submitProfileReport(selectedReason!)
                    : null,
                child: Text('Submit',
                    style: TextStyle(color: colors.dialogTextColor))),
          ],
        ),
      ),
    );
  }

  Future<void> _submitProfileReport(String reason) async {
    try {
      await _supabase.from('reports').insert({
        'user_id': widget.uid,
        'reason': reason,
        'timestamp': DateTime.now().toIso8601String(),
        'type': 'profile',
      });
      if (mounted) {
        Navigator.pop(context);
        showSnackBar(context, 'Report submitted. Thank you!');
      }
    } catch (_) {
      if (mounted) {
        showSnackBar(
            context, 'Please try again or contact us at ratedly9@gmail.com');
      }
    }
  }

  // --------------------------------------------------------------
  // UI Builders (skeletons, grids, etc.)
  // --------------------------------------------------------------
  Widget _buildOtherProfileSkeleton(_OtherProfileColorSet colors) {
    return SingleChildScrollView(
      controller: _scrollController,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildOtherProfileHeaderSkeleton(colors),
            const SizedBox(height: 20),
            _buildOtherBioSectionSkeleton(colors),
            const SizedBox(height: 16),
            _buildTabButtonsSkeleton(colors),
            Divider(color: colors.dividerColor),
            _buildOtherPostsGridSkeleton(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildOtherProfileHeaderSkeleton(_OtherProfileColorSet colors) {
    return Column(children: [
      Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: colors.skeletonColor)),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildOtherMetricSkeleton(colors),
          _buildOtherMetricSkeleton(colors),
          _buildOtherMetricSkeleton(colors),
        ],
      ),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
            width: 100,
            height: 40,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(8))),
        const SizedBox(width: 8),
        Container(
            width: 100,
            height: 40,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(8))),
      ]),
    ]);
  }

  Widget _buildOtherMetricSkeleton(_OtherProfileColorSet colors) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
          height: 16,
          width: 30,
          decoration: BoxDecoration(
              color: colors.skeletonColor,
              borderRadius: BorderRadius.circular(4))),
      const SizedBox(height: 6),
      Container(
          height: 12,
          width: 50,
          decoration: BoxDecoration(
              color: colors.skeletonColor,
              borderRadius: BorderRadius.circular(4))),
    ]);
  }

  Widget _buildOtherBioSectionSkeleton(_OtherProfileColorSet colors) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            height: 18,
            width: 120,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 12),
        Container(
            height: 14,
            width: double.infinity,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 14,
            width: 250,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 14,
            width: 200,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }

  Widget _buildTabButtonsSkeleton(_OtherProfileColorSet colors) {
    return Row(children: [
      Expanded(
          child: Container(
              height: 50,
              decoration: BoxDecoration(
                  color: colors.skeletonColor,
                  borderRadius: BorderRadius.circular(8)))),
      const SizedBox(width: 8),
      Expanded(
          child: Container(
              height: 50,
              decoration: BoxDecoration(
                  color: colors.skeletonColor,
                  borderRadius: BorderRadius.circular(8)))),
    ]);
  }

  Widget _buildOtherPostsGridSkeleton(_OtherProfileColorSet colors) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 9,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 0.8),
      itemBuilder: (_, __) => Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: colors.skeletonColor),
      ),
    );
  }

  Widget _buildAppBarTitleSkeleton(_OtherProfileColorSet colors) {
    return Container(
        height: 16,
        width: 120,
        decoration: BoxDecoration(
            color: colors.skeletonColor,
            borderRadius: BorderRadius.circular(4)));
  }

  Widget _buildTabButtons(_OtherProfileColorSet colors) {
    return Row(children: [
      Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _selectedTabIndex = 0),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: _selectedTabIndex == 0
                            ? colors.textColor
                            : colors.dividerColor,
                        width: 2))),
            child: Column(children: [
              Icon(Icons.grid_on,
                  color: _selectedTabIndex == 0
                      ? colors.textColor
                      : colors.textColor.withOpacity(0.5)),
              const SizedBox(height: 4),
              Text('POSTS',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: _selectedTabIndex == 0
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: _selectedTabIndex == 0
                          ? colors.textColor
                          : colors.textColor.withOpacity(0.5))),
            ]),
          ),
        ),
      ),
      Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _selectedTabIndex = 1),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(
                        color: _selectedTabIndex == 1
                            ? colors.textColor
                            : colors.dividerColor,
                        width: 2))),
            child: Column(children: [
              Icon(Icons.collections,
                  color: _selectedTabIndex == 1
                      ? colors.textColor
                      : colors.textColor.withOpacity(0.5)),
              const SizedBox(height: 4),
              Text('GALLERIES',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: _selectedTabIndex == 1
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: _selectedTabIndex == 1
                          ? colors.textColor
                          : colors.textColor.withOpacity(0.5))),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _buildOtherProfileHeader(_OtherProfileColorSet colors) {
    return Column(children: [
      _buildProfilePicture(colors),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          Expanded(
            child: Column(children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildOtherMetric(postLen, "Posts", colors),
                  _buildOtherMetric(followers, "Followers", colors),
                  _buildOtherMetric(following, "Following", colors),
                ],
              ),
              const SizedBox(height: 8),
              _buildOtherInteractionButtons(colors),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _buildOtherInteractionButtons(_OtherProfileColorSet colors) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    final bool isCurrentUser = currentUserId == widget.uid;
    final bool isPrivateAccount = userData['isPrivate'] ?? false;

    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (!isCurrentUser) _buildFollowButton(isPrivateAccount, colors),
        const SizedBox(width: 5),
        if (!isCurrentUser)
          ElevatedButton(
            onPressed: _otherNavigateToMessaging,
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.buttonBackgroundColor,
              foregroundColor: colors.buttonTextColor,
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              minimumSize: const Size(100, 40),
            ),
            child: Text("Message",
                style: TextStyle(color: colors.buttonTextColor)),
          ),
      ]),
      const SizedBox(height: 5),
    ]);
  }

  Widget _buildFollowButton(
      bool isPrivateAccount, _OtherProfileColorSet colors) {
    final isPending = hasPendingRequest && isPrivateAccount;
    return ElevatedButton(
      onPressed: _otherHandleFollow,
      style: ElevatedButton.styleFrom(
        backgroundColor: colors.buttonBackgroundColor,
        foregroundColor: colors.buttonTextColor,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        side: BorderSide(color: colors.buttonBackgroundColor),
        minimumSize: const Size(100, 40),
      ),
      child: Text(
        isFollowing
            ? 'Unfollow'
            : isPending
                ? 'Requested'
                : 'Follow',
        style: TextStyle(
            fontWeight: FontWeight.w600, color: colors.buttonTextColor),
      ),
    );
  }

  Widget _buildOtherMetric(
      int value, String label, _OtherProfileColorSet colors) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text(value.toString(),
          style: TextStyle(
              fontSize: 13.6,
              fontWeight: FontWeight.bold,
              color: colors.textColor)),
      const SizedBox(height: 4),
      Text(label,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: colors.textColor)),
    ]);
  }

  Widget _buildOtherBioSection(_OtherProfileColorSet colors) {
    final String bio = userData['bio'] ?? '';
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        VerifiedUsernameWidget(
          username: userData['username'] ?? '',
          uid: widget.uid,
          style: TextStyle(
              color: colors.textColor,
              fontWeight: FontWeight.bold,
              fontSize: 16),
        ),
        const SizedBox(height: 4),
        if (bio.isNotEmpty)
          ExpandableBioText(
            text: bio,
            style: TextStyle(color: colors.textColor),
            expandColor: colors.textColor.withOpacity(0.8),
          ),
      ]),
    );
  }

  Widget _buildPrivateAccountMessage(_OtherProfileColorSet colors) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.lock, size: 60, color: colors.errorTextColor),
      const SizedBox(height: 20),
      Text('This Account is Private',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.textColor)),
      const SizedBox(height: 10),
      Text('Follow to see their galleries',
          style: TextStyle(fontSize: 14, color: colors.textColor)),
    ]);
  }

  Widget _buildOtherPostsGrid(_OtherProfileColorSet colors) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    final bool isCurrentUser = currentUserId == widget.uid;
    final bool isPrivate = userData['isPrivate'] ?? false;
    final bool shouldHidePosts = isPrivate && !isFollowing && !isCurrentUser;
    final bool isMutuallyBlocked = _isBlockedByMe || _isBlockedByThem;

    if (isMutuallyBlocked) {
      return SizedBox(
          height: 200,
          child: Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                const Icon(Icons.block, size: 50, color: Colors.red),
                const SizedBox(height: 10),
                Text('Posts unavailable due to blocking',
                    style: TextStyle(color: colors.errorTextColor)),
              ])));
    }
    if (shouldHidePosts) {
      return SizedBox(height: 200, child: _buildPrivateAccountMessage(colors));
    }
    if (_displayedPosts.isEmpty) {
      return SizedBox(
          height: 200,
          child: Center(
              child: Text('This user has no posts.',
                  style:
                      TextStyle(fontSize: 16, color: colors.errorTextColor))));
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _displayedPosts.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 0.8),
      itemBuilder: (context, index) =>
          _buildOtherPostItem(_displayedPosts[index], colors),
    );
  }

  Widget _buildOtherGalleriesGrid(_OtherProfileColorSet colors) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    final bool isCurrentUser = currentUserId == widget.uid;
    final bool isPrivate = userData['isPrivate'] ?? false;
    final bool shouldHideGalleries =
        isPrivate && !isFollowing && !isCurrentUser;
    final bool isMutuallyBlocked = _isBlockedByMe || _isBlockedByThem;

    if (isMutuallyBlocked) {
      return SizedBox(
          height: 200,
          child: Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                const Icon(Icons.block, size: 50, color: Colors.red),
                const SizedBox(height: 10),
                Text('Galleries unavailable due to blocking',
                    style: TextStyle(color: colors.errorTextColor)),
              ])));
    }
    if (shouldHideGalleries) {
      return SizedBox(height: 200, child: _buildPrivateAccountMessage(colors));
    }
    if (_galleries.isEmpty) {
      return Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(children: [
            Icon(Icons.collections, size: 64, color: colors.errorTextColor),
            const SizedBox(height: 16),
            Text('No Galleries Yet',
                style: TextStyle(
                    color: colors.textColor,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('This user hasn\'t created any galleries',
                style: TextStyle(color: colors.textColor.withOpacity(0.7)),
                textAlign: TextAlign.center),
          ]));
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _galleries.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1),
      itemBuilder: (context, index) =>
          _buildGalleryItem(_galleries[index], colors),
    );
  }

  Widget _buildOtherPostItem(
      Map<String, dynamic> post, _OtherProfileColorSet colors) {
    final postUrl = post['postUrl'] ?? '';
    final isVideo = _isVideoFile(postUrl);
    final editResult = _parseEditResult(post);
    final postId = post['postId']?.toString() ?? '';

    if (postId.isNotEmpty && !_loggedPostRenders.contains(postId)) {
      _loggedPostRenders.add(postId);
      unawaited(_sendLog({
        'event_type': 'post_render',
        'post_id': postId,
        'thumbnail_url': postUrl,
        'extra': {
          'classified_as': isVideo ? 'video' : 'image',
          'controller_ready':
              isVideo ? _isVideoControllerInitialized(postUrl) : true,
          'has_edit_metadata': editResult != null,
          'grid_index': _displayedPosts
              .indexWhere((p) => p['postId']?.toString() == postId),
        },
      }));
    }

    if (_isBlocked) {
      return Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: colors.avatarBackgroundColor),
        child:
            const Center(child: Icon(Icons.block, color: Colors.red, size: 24)),
      );
    }

    final int tappedIndex =
        _displayedPosts.indexWhere((p) => p['postId']?.toString() == postId);
    final int startIndex = tappedIndex < 0 ? 0 : tappedIndex;

    final Map<String, dynamic> feedUserData = {
      'uid': widget.uid,
      'username': userData['username'] ?? '',
      'photoUrl': userData['photoUrl'] ?? '',
      'isVerified': userData['isVerified'] ?? false,
      'country': userData['country'] ?? '',
    };

    return GestureDetector(
      onTap: () {
        _pauseAllVideos();
        _muteProfileVideo();

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProfilePostFeedScreen(
              initialPosts: List<Map<String, dynamic>>.from(_displayedPosts),
              initialIndex: startIndex,
              userData: feedUserData,
              onLoadMore: _loadMorePostsForFeed,
              initialHasMore: _hasMorePosts,
              onPostDeleted: null,
            ),
          ),
        ).then((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) {
              _resumeAllVideos();
              _unmuteProfileVideo();
            }
          });
        });
      },
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: isVideo ? colors.avatarBackgroundColor : null),
        child: Stack(
          fit: StackFit.expand,
          children: [
            isVideo
                ? _buildPostVideoPlayer(postUrl, colors, editResult)
                : _buildPostImage(postUrl, colors, editResult),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryItem(
      Map<String, dynamic> gallery, _OtherProfileColorSet colors) {
    final postCount =
        gallery['gallery_posts'] != null && gallery['gallery_posts'].isNotEmpty
            ? gallery['gallery_posts'][0]['count'] ?? 0
            : 0;
    final coverPost = gallery['posts'] != null
        ? gallery['posts'] as Map<String, dynamic>
        : null;
    final coverImageUrl = coverPost != null ? coverPost['postUrl'] ?? '' : '';
    final isVideoCover = _isVideoFile(coverImageUrl);

    VideoEditResult? coverEditResult;
    if (coverPost != null) {
      final coverMeta = _extractEditMetadata(coverPost['video_edit_metadata']);
      if (coverMeta != null) {
        try {
          coverEditResult = VideoEditResult.fromJson(coverMeta, File(''));
        } catch (_) {}
      }
    }

    return GestureDetector(
      onTap: () async {
        _pauseAllVideos();
        _muteProfileVideo();
        try {
          final galleryPostsResponse =
              await _supabase.from('gallery_posts').select('''
            post_id,
            posts!inner(postId, postUrl, description, datePublished, uid, username, profImage)
          ''').eq('gallery_id', gallery['id']);

          final List<Map<String, dynamic>> posts =
              (galleryPostsResponse as List).map<Map<String, dynamic>>((item) {
            final p = item['posts'];
            return {
              'postId': p['postId']?.toString() ?? '',
              'postUrl': p['postUrl']?.toString() ?? '',
              'description': p['description']?.toString() ?? '',
              'uid': p['uid']?.toString() ?? '',
              'datePublished': p['datePublished']?.toString() ?? '',
              'username': p['username']?.toString() ?? '',
              'profImage': p['profImage']?.toString() ?? '',
            };
          }).toList();

          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GalleryPostViewScreen(
                  posts: posts,
                  initialIndex: 0,
                  galleryName: gallery['name'] ?? 'Unnamed Gallery',
                ),
              ),
            ).then((_) {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) {
                  _resumeAllVideos();
                  _unmuteProfileVideo();
                }
              });
            });
          }
        } catch (e) {
          if (mounted) {
            showSnackBar(context, 'Failed to load gallery posts: $e');
          }
        }
      },
      child: Container(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: colors.avatarBackgroundColor),
        child: Stack(fit: StackFit.expand, children: [
          if (coverImageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: isVideoCover
                  ? _buildGalleryVideoPlayer(
                      coverImageUrl, colors, coverEditResult)
                  : _buildGalleryCoverImage(
                      coverImageUrl, colors, coverEditResult),
            )
          else
            Container(
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: colors.avatarBackgroundColor.withOpacity(0.5)),
              child: Icon(Icons.collections,
                  size: 40, color: colors.errorTextColor),
            ),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withOpacity(0.7),
                  Colors.transparent,
                ],
              ),
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(gallery['name'] ?? 'Unnamed Gallery',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('$postCount ${postCount == 1 ? 'post' : 'posts'}',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 12)),
                    ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // --------------------------------------------------------------
  // Build
  // --------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final String? currentUserId =
        userProvider.firebaseUid ?? userProvider.supabaseUid;
    final bool isCurrentUser = currentUserId == widget.uid;
    final bool isAuthenticated =
        currentUserId != null && currentUserId.isNotEmpty;

    if (isLoading) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: colors.appBarBackgroundColor,
          elevation: 0,
          leading: BackButton(color: colors.appBarIconColor),
          title: _buildAppBarTitleSkeleton(colors),
          centerTitle: true,
        ),
        backgroundColor: colors.backgroundColor,
        body: _buildOtherProfileSkeleton(colors),
      );
    }

    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.appBarIconColor),
        backgroundColor: colors.appBarBackgroundColor,
        elevation: 0,
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          VerifiedUsernameWidget(
            username: userData['username'] ?? 'User',
            uid: widget.uid,
            style:
                TextStyle(color: colors.textColor, fontWeight: FontWeight.bold),
          ),
        ]),
        centerTitle: true,
        leading: BackButton(color: colors.appBarIconColor),
        actions: [
          if (isAuthenticated)
            PopupMenuButton(
              icon: Icon(Icons.more_vert, color: colors.appBarIconColor),
              onSelected: (value) async {
                if (value == 'block') {
                  try {
                    setState(() => isLoading = true);
                    if (currentUserId == null) return;
                    await SupabaseBlockMethods().blockUser(
                        currentUserId: currentUserId, targetUserId: widget.uid);
                    if (mounted) {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BlockedProfileScreen(
                              uid: widget.uid, isBlocker: true),
                        ),
                      );
                    }
                  } catch (_) {
                    if (mounted) {
                      showSnackBar(context,
                          "Please try again or contact us at ratedly9@gmail.com");
                    }
                  } finally {
                    if (mounted) setState(() => isLoading = false);
                  }
                } else if (value == 'remove_follower') {
                  if (currentUserId == null) return;
                  try {
                    await SupabaseProfileMethods()
                        .removeFollower(currentUserId, widget.uid);
                    if (mounted) {
                      setState(() {
                        _isViewerFollower = false;
                        followers = followers - 1;
                      });
                      showSnackBar(context, "Follower removed successfully");
                    }
                  } catch (_) {
                    if (mounted) {
                      showSnackBar(context,
                          "Please try again or contact us at ratedly9@gmail.com");
                    }
                  }
                } else if (value == 'report') {
                  _showProfileReportDialog(colors);
                }
              },
              itemBuilder: (_) => [
                if (_isViewerFollower)
                  PopupMenuItem(
                      value: 'remove_follower',
                      child: Text('Remove Follower',
                          style: TextStyle(color: colors.textColor))),
                if (!isCurrentUser)
                  PopupMenuItem(
                      value: 'report',
                      child: Text('Report Profile',
                          style: TextStyle(color: colors.textColor))),
                PopupMenuItem(
                    value: 'block',
                    child: Text('Block User',
                        style: TextStyle(color: colors.textColor))),
              ],
            )
        ],
      ),
      backgroundColor: colors.backgroundColor,
      body: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (scrollInfo is ScrollEndNotification) {
            if (scrollInfo.metrics.pixels >=
                    scrollInfo.metrics.maxScrollExtent - 100 &&
                !_isLoadingMore &&
                _hasMorePosts &&
                _selectedTabIndex == 0) {
              _loadMorePosts();
            }
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: _scrollController,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _buildOtherProfileHeader(colors),
                const SizedBox(height: 20),
                _buildOtherBioSection(colors),
              ]),
            ),
            const SizedBox(height: 16),
            _buildTabButtons(colors),
            const SizedBox(height: 8),
            _selectedTabIndex == 0
                ? _buildOtherPostsGrid(colors)
                : _buildOtherGalleriesGrid(colors),
            if (_isLoadingMore && _selectedTabIndex == 0)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: CircularProgressIndicator(color: colors.textColor),
              ),
            const SizedBox(height: 20),
          ]),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _videoInitDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    for (final c in _videoControllers.values) {
      c.pause();
      c.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    _profileVideoController?.dispose();
    _profileVideoController = null;
    super.dispose();
  }
}

// -----------------------------------------------------------------------------
// Scaled Drawing Painter (identical to current_profile_screen.dart)
// -----------------------------------------------------------------------------
class _ScaledDrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final double scaleX;
  final double scaleY;

  const _ScaledDrawingPainter({
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
  bool shouldRepaint(_ScaledDrawingPainter old) =>
      old.strokes != strokes || old.scaleX != scaleX || old.scaleY != scaleY;
}
