// lib/screens/Profile_page/current_profile_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/services/notification_service.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/edit_profile_screen.dart';
import 'package:Ratedly/screens/Profile_page/custom_camera_screen.dart';
import 'package:Ratedly/widgets/settings_screen.dart';
import 'package:Ratedly/widgets/user_list_screen.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter/gestures.dart';
import 'package:Ratedly/screens/Profile_page/gallery_detail_screen.dart';
import 'package:country_flags/country_flags.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/profile_post_feed_screen.dart';
import 'package:Ratedly/services/analytics_service.dart';

class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
        );
}

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

class CurrentUserProfileScreen extends StatefulWidget {
  final String uid;
  const CurrentUserProfileScreen({Key? key, required this.uid})
      : super(key: key);

  @override
  State<CurrentUserProfileScreen> createState() =>
      _CurrentUserProfileScreenState();
}

class _CurrentUserProfileScreenState extends State<CurrentUserProfileScreen>
    with WidgetsBindingObserver {
  final SupabaseClient _supabase = Supabase.instance.client;
  var userData = {};
  int followers = 0;
  int following = 0;
  int postCount = 0;
  List<dynamic> _followersList = [];
  List<dynamic> _followingList = [];
  bool isLoading = false;
  bool hasError = false;
  String errorMessage = '';
  final SupabaseProfileMethods _profileMethods = SupabaseProfileMethods();

  Timer? _noPostNudgeTimer;
  bool _nudgeSent = false;

  List<dynamic> _galleries = [];
  int _selectedTabIndex = 0;

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  Timer? _videoInitDebounce;

  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;
  bool _isProfileVideoMuted = false;

  List<dynamic> _displayedPosts = [];
  int _postsOffset = 0;
  final int _initialPostsLimit = 9;
  final int _subsequentPostsLimit = 6;
  bool _hasMorePosts = true;
  bool _isLoadingMore = false;
  bool _isFirstLoad = true;

  late ScrollController _scrollController;

  _ColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? _DarkColors()
        : _LightColors();
  }

  // ==========================================================================
  // ERROR LOGGING HELPER
  // ==========================================================================
  Future<void> _logProfileError({
    required String operation,
    required dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('profile_errors').insert({
        'user_id': widget.uid,
        'operation_type': operation,
        'error_message': error.toString(),
        'stack_trace': stack?.toString(),
        'additional_data': additionalData,
      });
    } catch (logError) {
      print('Failed to log profile error: $logError');
    }
  }

  bool _isVideoFile(String url) {
    if (url.isEmpty || url == 'default') return false;
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
    } catch (e, stack) {
      _logProfileError(
        operation: 'parseEditResult',
        error: e,
        stack: stack,
        additionalData: {'postId': post['postId']},
      );
      return null;
    }
  }

  List<double> _buildColorMatrix(VideoEditResult? er) {
    if (er == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix);
  }

  @override
  void initState() {
    super.initState();
    AnalyticsService.screenEnter('current_profile');

    WidgetsBinding.instance.addObserver(this);
    _scrollController = ScrollController();
    _scrollController.addListener(_scrollListener);
    getData();
  }

  @override
  void dispose() {
    AnalyticsService.screenExit(
      screenName: 'profile',
      uid: widget.uid,
    );

    _videoInitDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    _profileVideoController?.dispose();
    _profileVideoController = null;
    _noPostNudgeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _muteProfileVideo();
    } else if (state == AppLifecycleState.resumed) {
      _unmuteProfileVideo();
    }
  }

  void _muteProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.setVolume(0.0);
      } catch (e, stack) {
        _logProfileError(
          operation: 'muteProfileVideo',
          error: e,
          stack: stack,
        );
      }
    }
  }

  void _unmuteProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.setVolume(_isProfileVideoMuted ? 0.0 : 1.0);
      } catch (e, stack) {
        _logProfileError(
          operation: 'unmuteProfileVideo',
          error: e,
          stack: stack,
        );
      }
    }
  }

  void _toggleProfileVideoMute() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      setState(() => _isProfileVideoMuted = !_isProfileVideoMuted);
      try {
        _profileVideoController!.setVolume(_isProfileVideoMuted ? 0.0 : 1.0);
      } catch (e, stack) {
        _logProfileError(
          operation: 'toggleProfileVideoMute',
          error: e,
          stack: stack,
        );
      }
    }
  }

  void _pauseAllGridVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  void _resumeAllGridVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isInitialized && !c.value.isPlaying) c.play();
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

  // ========== PROFILE VIDEO ==========
  Future<void> _initializeProfileVideo(String videoUrl) async {
    if (_profileVideoController != null) {
      await _profileVideoController!.dispose();
      if (mounted) {
        setState(() {
          _profileVideoController = null;
          _isProfileVideoInitialized = false;
        });
      }
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
    } catch (e, stack) {
      await _logProfileError(
        operation: 'initializeProfileVideo',
        error: e,
        stack: stack,
        additionalData: {'videoUrl': videoUrl},
      );
      if (mounted) setState(() => _isProfileVideoInitialized = false);
    }
  }

  Widget _buildProfileVideoPlayer(_ColorSet colors) {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        decoration:
            BoxDecoration(shape: BoxShape.circle, color: colors.cardColor),
        child:
            Center(child: CircularProgressIndicator(color: colors.textColor)),
      );
    }
    return Stack(children: [
      ClipOval(
        child: SizedBox(
          width: 80,
          height: 80,
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
            width: 24,
            height: 24,
            decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
            child: Icon(
              _isProfileVideoMuted ? Icons.volume_off : Icons.volume_up,
              size: 12,
              color: Colors.white,
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildProfilePicture(_ColorSet colors) {
    final photoUrl = userData['photoUrl']?.toString() ?? '';
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    final isVideo = !isDefault && _isVideoFile(photoUrl);

    if (isDefault) {
      return CircleAvatar(
        radius: 40,
        backgroundColor: colors.cardColor,
        child: Icon(Icons.account_circle, size: 80, color: colors.textColor),
      );
    }
    if (isVideo) return _buildProfileVideoPlayer(colors);
    return ClipOval(
      child: Container(
        width: 80,
        height: 80,
        color: colors.cardColor,
        child: Image.network(photoUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(
                child: Icon(Icons.account_circle,
                    size: 80, color: colors.textColor))),
      ),
    );
  }

  // ========== POST VIDEOS ==========

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
      }).catchError((e, stack) {
        _logProfileError(
          operation: 'initializeVideoController',
          error: e,
          stack: stack,
          additionalData: {'videoUrl': videoUrl},
        );
      });
    } catch (e, stack) {
      await _logProfileError(
        operation: 'initializeVideoController',
        error: e,
        stack: stack,
        additionalData: {'videoUrl': videoUrl},
      );
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

  Widget _buildPostVideoPlayer(
      String videoUrl, _ColorSet colors, VideoEditResult? editResult) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);

    if (!isInitialized || controller == null) {
      return Container(
          color: colors.cardColor,
          child: Center(
              child: CircularProgressIndicator(color: colors.textColor)));
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
                builder: (context, constraints) =>
                    _buildEditOverlayLayer(editResult, constraints),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildGalleryVideoPlayer(
      String videoUrl, _ColorSet colors, VideoEditResult? editResult) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);

    if (!isInitialized || controller == null) {
      return Container(
          color: colors.cardColor,
          child: Center(
              child: CircularProgressIndicator(color: colors.textColor)));
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
                  child: VideoPlayer(controller),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  void _preInitializeVideoControllers(List<dynamic> posts) {
    for (final p in posts) {
      final url = p['postUrl'] ?? '';
      if (_isVideoFile(url)) _initializeVideoController(url);
    }
  }

  // ========== DATA FETCHING ==========

  Future<void> getData() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      hasError = false;
      errorMessage = '';
    });

    try {
      final countResponse = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', widget.uid)
          .count(CountOption.exact);
      final totalPostCount = countResponse.count;

      final postsLimit =
          _isFirstLoad ? _initialPostsLimit : _subsequentPostsLimit;

      final initialPosts = await _supabase
          .from('posts')
          .select(
              'postId, postUrl, description, datePublished, uid, viewers_count, video_edit_metadata')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false)
          .range(0, postsLimit - 1);

      final userResponse = await _supabase
          .from('users')
          .select()
          .eq('uid', widget.uid)
          .maybeSingle();

      if (userResponse == null) {
        if (mounted) {
          setState(() {
            hasError = true;
            errorMessage = 'User profile not found';
            isLoading = false;
            _isFirstLoad = false;
          });
        }
        return;
      }

      final bool isTestUser = userResponse['test'] == true;

      final followersResponse = await _supabase
          .from('user_followers')
          .select('follower_id, followed_at')
          .eq('user_id', widget.uid)
          .then<List>((v) => v)
          .catchError((e, stack) {
        _logProfileError(
          operation: 'getData_followers',
          error: e,
          stack: stack,
          additionalData: {'uid': widget.uid},
        );
        return <dynamic>[];
      });

      final followingResponse = await _supabase
          .from('user_following')
          .select('following_id, followed_at')
          .eq('user_id', widget.uid)
          .then<List>((v) => v)
          .catchError((e, stack) {
        _logProfileError(
          operation: 'getData_following',
          error: e,
          stack: stack,
          additionalData: {'uid': widget.uid},
        );
        return <dynamic>[];
      });

      final galleriesResponse = await _supabase
          .from('galleries')
          .select('''
 *,
 gallery_posts(count),
 posts!cover_post_id(postUrl, video_edit_metadata)
 ''')
          .eq('uid', widget.uid)
          .order('created_at', ascending: false)
          .then<List>((v) => v)
          .catchError((e, stack) {
            _logProfileError(
              operation: 'getData_galleries',
              error: e,
              stack: stack,
              additionalData: {'uid': widget.uid},
            );
            return <dynamic>[];
          });

      final photoUrl = userResponse['photoUrl'] ?? '';
      if (_isVideoFile(photoUrl)) _initializeProfileVideo(photoUrl);

      _preInitializeVideoControllers(initialPosts);
      for (final g in galleriesResponse) {
        final url = g['posts'] != null ? g['posts']['postUrl'] ?? '' : '';
        if (_isVideoFile(url)) _initializeVideoController(url);
      }

      final processedData = await Future.wait([
        _processUserList(followersResponse, 'follower_id'),
        _processUserList(followingResponse, 'following_id'),
      ]);

      if (mounted) {
        setState(() {
          userData = userResponse;
          postCount = totalPostCount;
          followers = followersResponse.length;
          following = followingResponse.length;
          _followersList = processedData[0];
          _followingList = processedData[1];
          _galleries = galleriesResponse;
          _displayedPosts = initialPosts;
          _postsOffset = initialPosts.length;
          _hasMorePosts = totalPostCount > initialPosts.length;
          _isFirstLoad = false;
        });

        if (isTestUser && totalPostCount == 0) {
          _startNoPostNudgeTimer();
        }
      }
    } catch (e, stackTrace) {
      await _logProfileError(
        operation: 'getData',
        error: e,
        stack: stackTrace,
        additionalData: {'uid': widget.uid},
      );
      if (mounted) {
        setState(() {
          hasError = true;
          errorMessage = 'Failed to load profile data';
          _isFirstLoad = false;
        });
        showSnackBar(
            context, "Please try again or contact us at ratedly9@gmail.com");
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _startNoPostNudgeTimer() {
    if (_nudgeSent || _noPostNudgeTimer != null) return;
    _noPostNudgeTimer = Timer(const Duration(minutes: 1), () async {
      if (!mounted || _nudgeSent) return;
      if (postCount > 0) return;
      _nudgeSent = true;
      try {
        NotificationService().triggerServerNotification(
          type: 'nudge',
          targetUserId: widget.uid,
          title: ' Post your first moment',
          body: 'Your first post could be the start of something big.',
          customData: {'source': 'no_post_nudge'},
        );
      } catch (e, stack) {
        await _logProfileError(
          operation: 'startNoPostNudgeTimer_notification',
          error: e,
          stack: stack,
          additionalData: {'uid': widget.uid},
        );
      }
    });
  }

  Future<void> _loadMorePosts() async {
    if (!_hasMorePosts || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final newPosts = await _supabase
          .from('posts')
          .select(
              'postId, postUrl, description, datePublished, uid, viewers_count, video_edit_metadata')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false)
          .range(_postsOffset, _postsOffset + _subsequentPostsLimit - 1);

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
    } catch (e, stack) {
      await _logProfileError(
        operation: 'loadMorePosts',
        error: e,
        stack: stack,
        additionalData: {'uid': widget.uid, 'offset': _postsOffset},
      );
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
    } catch (e, stack) {
      await _logProfileError(
        operation: 'loadMorePostsForFeed',
        error: e,
        stack: stack,
        additionalData: {'uid': widget.uid, 'currentCount': currentCount},
      );
      return [];
    }
  }

  Future<List<dynamic>> _processUserList(
      List<dynamic> userList, String idKey) async {
    if (userList.isEmpty) return [];
    final userIds = userList.map((u) => u[idKey] as String).toList();
    try {
      final usersData = await _supabase
          .from('users')
          .select('uid, username, photoUrl')
          .inFilter('uid', userIds);
      final userMap = {for (var u in usersData) u['uid'] as String: u};
      return userList
          .map((entry) {
            final info = userMap[entry[idKey]];
            return info != null
                ? {
                    'userId': entry[idKey],
                    'username': info['username'],
                    'photoUrl': info['photoUrl'],
                    'timestamp': entry['followed_at'],
                  }
                : null;
          })
          .where((item) => item != null)
          .toList();
    } catch (e, stack) {
      await _logProfileError(
        operation: 'processUserList',
        error: e,
        stack: stack,
        additionalData: {'idKey': idKey, 'userIds': userIds},
      );
      return [];
    }
  }

  void _navigateToSettings() {
    _muteProfileVideo();
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => const SettingsScreen()))
        .then((_) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _unmuteProfileVideo();
      });
    });
  }

  Widget _buildUsernameWithFlag(
      String username, bool isVerified, String? countryCode, _ColorSet colors) {
    final bool hasFlag = countryCode != null &&
        countryCode.isNotEmpty &&
        countryCode.length == 2;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(username,
          style:
              TextStyle(color: colors.textColor, fontWeight: FontWeight.bold)),
      if (hasFlag) ...[
        const SizedBox(width: 4),
        CountryFlagWidget(countryCode: countryCode!),
      ],
      if (isVerified) ...[
        const SizedBox(width: 4),
        const Icon(Icons.verified, color: Colors.blue, size: 16),
      ],
    ]);
  }

  // ========== BUILD ==========
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.textColor),
        backgroundColor: colors.backgroundColor,
        elevation: 0,
        title: isLoading
            ? Container(
                height: 16,
                width: 120,
                decoration: BoxDecoration(
                  color: colors.cardColor.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
              )
            : _buildUsernameWithFlag(
                userData['username'] ?? 'Loading...',
                userData['isVerified'] == true,
                userData['country']?.toString(),
                colors,
              ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.menu, color: colors.textColor),
            onPressed: _navigateToSettings,
          ),
        ],
      ),
      backgroundColor: colors.backgroundColor,
      body: hasError
          ? _buildErrorWidget(colors)
          : isLoading
              ? _buildProfileSkeleton(colors)
              : SingleChildScrollView(
                  controller: _scrollController,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      _buildProfileHeader(colors),
                      const SizedBox(height: 20),
                      Column(children: [
                        _buildBioSection(colors),
                        const SizedBox(height: 16),
                        Column(children: [
                          _buildTabButtons(colors),
                          _selectedTabIndex == 0
                              ? _buildPostsGrid(colors)
                              : _buildGalleriesGrid(colors),
                        ]),
                      ]),
                      if (_selectedTabIndex == 0 && _isLoadingMore)
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(
                              color: colors.textColor),
                        ),
                      const SizedBox(height: 20),
                    ]),
                  ),
                ),
    );
  }

  Widget _buildErrorWidget(_ColorSet colors) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.error_outline, color: colors.textColor, size: 64),
        const SizedBox(height: 16),
        Text('Something went wrong',
            style: TextStyle(
                color: colors.textColor,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(errorMessage,
            style: TextStyle(color: colors.textColor),
            textAlign: TextAlign.center),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: getData,
          style: ElevatedButton.styleFrom(
              backgroundColor: colors.cardColor,
              foregroundColor: colors.textColor),
          child: const Text('Try Again'),
        ),
      ]),
    );
  }

  Widget _buildProfileHeader(_ColorSet colors) {
    return Column(children: [
      SizedBox(
        height: 80,
        child: Center(
          child: Transform.translate(
            offset: const Offset(0, -12),   // moves profile picture up by 12px
            child: _buildProfilePicture(colors),
          ),
        ),
      ),
      Column(children: [
        SizedBox(
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildMetric(postCount, "Posts", colors.textColor),
              _buildInteractiveMetric(
                  followers, "Followers", _followersList, colors),
              _buildInteractiveMetric(
                  following, "Following", _followingList, colors),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Center(child: _buildEditProfileButton(colors)),
      ]),
    ]);
  }

  Widget _buildInteractiveMetric(
      int value, String label, List<dynamic> userList, _ColorSet colors) {
    return GestureDetector(
      onTap: () {
        _muteProfileVideo();
        Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  UserListScreen(title: label, userEntries: userList)),
        ).then((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) _unmuteProfileVideo();
          });
        });
      },
      child: _buildMetric(value, label, colors.textColor),
    );
  }

  Widget _buildEditProfileButton(_ColorSet colors) {
    return ElevatedButton(
      onPressed: () async {
        _muteProfileVideo();
        final result = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const EditProfileScreen()),
        );
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _unmuteProfileVideo();
        });
        if (result != null && mounted) {
          setState(() {
            userData['bio'] = result['bio'] ?? userData['bio'];
            userData['photoUrl'] = result['photoUrl'] ?? userData['photoUrl'];
          });
          await getData();
        }
      },
      style: ElevatedButton.styleFrom(
          backgroundColor: colors.cardColor, foregroundColor: colors.textColor),
      child: const Text("Edit Profile"),
    );
  }

  Widget _buildMetric(int value, String label, Color textColor) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text(value.toString(),
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: textColor)),
      const SizedBox(height: 4),
      Text(label,
          style: TextStyle(
              fontSize: 15, fontWeight: FontWeight.w400, color: textColor)),
    ]);
  }

  Widget _buildBioSection(_ColorSet colors) {
    final String bio = userData['bio'] ?? '';
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildUsernameWithFlag(
          userData['username'] ?? '',
          userData['isVerified'] == true,
          userData['country']?.toString(),
          colors,
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

  Widget _buildTabButtons(_ColorSet colors) {
    return Container(
      decoration: BoxDecoration(
          border:
              Border(bottom: BorderSide(color: colors.cardColor, width: 1))),
      child: Row(children: [
        Expanded(
          child: TextButton(
            onPressed: () => setState(() => _selectedTabIndex = 0),
            style: TextButton.styleFrom(
              foregroundColor: _selectedTabIndex == 0
                  ? colors.textColor
                  : colors.textColor.withOpacity(0.5),
              shape:
                  const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            ),
            child: Column(children: [
              Icon(Icons.grid_on,
                  color: _selectedTabIndex == 0
                      ? colors.textColor
                      : colors.textColor.withOpacity(0.5)),
              Text('POSTS',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: _selectedTabIndex == 0
                          ? FontWeight.bold
                          : FontWeight.normal)),
              if (_selectedTabIndex == 0)
                Container(height: 1, color: colors.textColor),
            ]),
          ),
        ),
        Expanded(
          child: TextButton(
            onPressed: () => setState(() => _selectedTabIndex = 1),
            style: TextButton.styleFrom(
              foregroundColor: _selectedTabIndex == 1
                  ? colors.textColor
                  : colors.textColor.withOpacity(0.5),
              shape:
                  const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            ),
            child: Column(children: [
              Icon(Icons.collections,
                  color: _selectedTabIndex == 1
                      ? colors.textColor
                      : colors.textColor.withOpacity(0.5)),
              Text('GALLERIES',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: _selectedTabIndex == 1
                          ? FontWeight.bold
                          : FontWeight.normal)),
              if (_selectedTabIndex == 1)
                Container(height: 1, color: colors.textColor),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildPostsGrid(_ColorSet colors) {
    if (_displayedPosts.isEmpty && !_isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Upload your first post',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textColor,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Go viral The world is waiting for you!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textColor.withOpacity(0.6),
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: () {
                _muteProfileVideo();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CustomCameraScreen(
                      onPostUploaded: () async => getData(),
                    ),
                    settings: const RouteSettings(
                        name: 'cameraFromProfile'), // <-- ADDED
                  ),
                ).then((_) {
                  Future.delayed(const Duration(milliseconds: 300), () {
                    if (mounted) _unmuteProfileVideo();
                  });
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3797EF),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                elevation: 0,
              ),
              child: const Text(
                'Upload',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _displayedPosts.length + 1,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 0.8),
      itemBuilder: (context, index) {
        if (index == 0) return _buildAddPostButton(colors);
        final postIndex = index - 1;
        if (postIndex < 0 || postIndex >= _displayedPosts.length) {
          return Container();
        }
        return _buildPostItem(_displayedPosts[postIndex], colors, postIndex);
      },
    );
  }

  Widget _buildAddPostButton(_ColorSet colors) {
    return GestureDetector(
      onTap: () {
        _muteProfileVideo();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CustomCameraScreen(
              onPostUploaded: () async => getData(),
            ),
            settings:
                const RouteSettings(name: 'cameraFromProfile'), // <-- ADDED
          ),
        ).then((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) _unmuteProfileVideo();
          });
        });
      },
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4), color: colors.cardColor),
        child:
            Icon(Icons.add_circle_outline, size: 40, color: colors.textColor),
      ),
    );
  }

  Widget _buildPostItem(
      Map<String, dynamic> post, _ColorSet colors, int postIndex) {
    final postUrl = post['postUrl'] ?? '';
    final isVideo = _isVideoFile(postUrl);
    final editResult = _parseEditResult(post);

    final Map<String, dynamic> feedUserData = {
      'uid': widget.uid,
      'username': userData['username'] ?? '',
      'photoUrl': userData['photoUrl'] ?? '',
      'isVerified': userData['isVerified'] ?? false,
      'country': userData['country'] ?? '',
    };

    return GestureDetector(
      onTap: () {
        _pauseAllGridVideos();
        _muteProfileVideo();

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProfilePostFeedScreen(
              initialPosts: List<Map<String, dynamic>>.from(_displayedPosts),
              initialIndex: postIndex,
              userData: feedUserData,
              onLoadMore: _loadMorePostsForFeed,
              initialHasMore: _hasMorePosts,
              onPostDeleted: () async => getData(),
            ),
          ),
        ).then((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) {
              _resumeAllGridVideos();
              _unmuteProfileVideo();
            }
          });
        });
      },
      child: Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: isVideo ? colors.cardColor : null),
        child: Stack(
          fit: StackFit.expand,
          children: [
            isVideo
                ? _buildPostVideoPlayer(postUrl, colors, editResult)
                : _buildPostImage(post, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildPostImage(Map<String, dynamic> post, _ColorSet colors) {
    final postUrl = post['postUrl'] ?? '';
    final editResult = _parseEditResult(post);
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    Widget baseImage = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: editResult == null
          ? Image.network(
              postUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, __, ___) => Container(
                color: colors.cardColor,
                child:
                    Icon(Icons.broken_image, color: colors.iconColor, size: 20),
              ),
            )
          : ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: Transform.rotate(
                angle: quarters * math.pi / 2,
                child: Image.network(
                  postUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => Container(
                    color: colors.cardColor,
                    child: Icon(Icons.broken_image,
                        color: colors.iconColor, size: 20),
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

  Widget _buildGalleriesGrid(_ColorSet colors) {
    if (_galleries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40.0),
        child: Column(children: [
          Icon(Icons.collections,
              size: 64, color: colors.textColor.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text('No Galleries Yet',
              style: TextStyle(
                  color: colors.textColor,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Create your first gallery to organize your posts',
              style: TextStyle(color: colors.textColor.withOpacity(0.7)),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _createNewGallery,
            style: ElevatedButton.styleFrom(
                backgroundColor: colors.cardColor,
                foregroundColor: colors.textColor),
            child: const Text('Create Gallery'),
          ),
        ]),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _galleries.length + 1,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          childAspectRatio: 1),
      itemBuilder: (context, index) {
        if (index == 0) return _buildAddGalleryButton(colors);
        final i = index - 1;
        if (i < 0 || i >= _galleries.length) return Container();
        return _buildGalleryItem(_galleries[i], colors);
      },
    );
  }

  Widget _buildAddGalleryButton(_ColorSet colors) {
    return GestureDetector(
      onTap: _createNewGallery,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: colors.cardColor,
          border: Border.all(color: colors.textColor.withOpacity(0.3)),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.add_photo_alternate,
              size: 40, color: colors.textColor.withOpacity(0.7)),
          const SizedBox(height: 8),
          Text('New Gallery',
              style: TextStyle(
                  color: colors.textColor.withOpacity(0.7), fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildGalleryItem(Map<String, dynamic> gallery, _ColorSet colors) {
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
        } catch (e, stack) {
          _logProfileError(
            operation: 'buildGalleryItem_parseEditResult',
            error: e,
            stack: stack,
            additionalData: {'galleryId': gallery['id']},
          );
        }
      }
    }

    return GestureDetector(
      onTap: () {
        _muteProfileVideo();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GalleryDetailScreen(
              galleryId: gallery['id'],
              galleryName: gallery['name'] ?? 'Unnamed Gallery',
              uid: widget.uid,
            ),
          ),
        ).then((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (mounted) _unmuteProfileVideo();
          });
          getData();
        });
      },
      child: Container(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8), color: colors.cardColor),
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
                  color: colors.cardColor.withOpacity(0.5)),
              child: Icon(Icons.collections,
                  size: 40, color: colors.textColor.withOpacity(0.5)),
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

  Widget _buildGalleryCoverImage(
      String url, _ColorSet colors, VideoEditResult? editResult) {
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    if (editResult == null) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: colors.cardColor.withOpacity(0.5)),
          child: Icon(Icons.collections,
              size: 40, color: colors.textColor.withOpacity(0.5)),
        ),
      );
    }

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix),
      child: Transform.rotate(
        angle: quarters * math.pi / 2,
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: colors.cardColor.withOpacity(0.5)),
            child: Icon(Icons.collections,
                size: 40, color: colors.textColor.withOpacity(0.5)),
          ),
        ),
      ),
    );
  }

  void _createNewGallery() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final colors = _getColors(themeProvider);
    showDialog(
      context: context,
      builder: (context) {
        final nameController = TextEditingController();
        return AlertDialog(
          title: Text('Create New Gallery',
              style: TextStyle(color: colors.textColor)),
          backgroundColor: colors.backgroundColor,
          content: TextField(
            controller: nameController,
            decoration: InputDecoration(
              hintText: 'Gallery name',
              hintStyle: TextStyle(color: colors.textColor.withOpacity(0.5)),
              border: const OutlineInputBorder(),
            ),
            style: TextStyle(color: colors.textColor),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child:
                    Text('Cancel', style: TextStyle(color: colors.textColor))),
            TextButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isNotEmpty) {
                  Navigator.of(context).pop();
                  await _createGallery(name);
                }
              },
              child: Text('Create', style: TextStyle(color: colors.textColor)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _createGallery(String name) async {
    try {
      final response = await _supabase.from('galleries').insert({
        'uid': widget.uid,
        'name': name,
      }).select();
      if (mounted) {
        setState(() => _galleries = [response.first, ..._galleries]);
      }
    } catch (e, stack) {
      await _logProfileError(
        operation: 'createGallery',
        error: e,
        stack: stack,
        additionalData: {'uid': widget.uid, 'name': name},
      );
      if (mounted) showSnackBar(context, 'Failed to create gallery: $e');
    }
  }

  // ========== SKELETONS ==========
  Widget _buildProfileSkeleton(_ColorSet colors) {
    return SingleChildScrollView(
      controller: _scrollController,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          _buildProfileHeaderSkeleton(colors),
          const SizedBox(height: 20),
          Column(children: [
            _buildBioSectionSkeleton(colors),
            const SizedBox(height: 16),
            Divider(color: colors.cardColor),
            _buildPostsGridSkeleton(colors),
          ]),
        ]),
      ),
    );
  }

  Widget _buildProfileHeaderSkeleton(_ColorSet colors) {
    return Column(children: [
      SizedBox(
        height: 80,
        child: Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.cardColor.withOpacity(0.6)),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildMetricSkeleton(colors),
          _buildMetricSkeleton(colors),
          _buildMetricSkeleton(colors),
        ],
      ),
      const SizedBox(height: 16),
      Container(
        width: 120,
        height: 36,
        decoration: BoxDecoration(
            color: colors.cardColor.withOpacity(0.6),
            borderRadius: BorderRadius.circular(8)),
      ),
    ]);
  }

  Widget _buildMetricSkeleton(_ColorSet colors) {
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
          height: 16,
          width: 30,
          decoration: BoxDecoration(
              color: colors.cardColor.withOpacity(0.8),
              borderRadius: BorderRadius.circular(4))),
      const SizedBox(height: 6),
      Container(
          height: 12,
          width: 50,
          decoration: BoxDecoration(
              color: colors.cardColor.withOpacity(0.6),
              borderRadius: BorderRadius.circular(4))),
    ]);
  }

  Widget _buildBioSectionSkeleton(_ColorSet colors) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            height: 18,
            width: 120,
            decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.8),
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 12),
        Container(
            height: 14,
            width: double.infinity,
            decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 14,
            width: 250,
            decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 14,
            width: 200,
            decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }

  Widget _buildPostsGridSkeleton(_ColorSet colors) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 7,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
          childAspectRatio: 0.8),
      itemBuilder: (_, __) => Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: colors.cardColor.withOpacity(0.5)),
      ),
    );
  }
}

// =============================================================================
// SCALED DRAWING PAINTER
// =============================================================================
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
