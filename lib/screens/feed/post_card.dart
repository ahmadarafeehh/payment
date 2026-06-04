import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/models/user.dart' as model;
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/services/api_service.dart';
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';
import 'package:Ratedly/widgets/postshare.dart';
import 'package:Ratedly/widgets/blocked_content_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'dart:ui';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/resources/reactions_methods.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/services/analytics_service.dart'; // ✅ already imported

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

// ─────────────────────────────────────────────────────────────────────────────
// Pulsing skeleton bone – mirrors the style used in FeedSkeleton
// ─────────────────────────────────────────────────────────────────────────────
class _PulsingBone extends StatefulWidget {
  final double width;
  final double height;
  final double borderRadius;

  const _PulsingBone({
    required this.width,
    required this.height,
    this.borderRadius = 6,
  });

  @override
  State<_PulsingBone> createState() => _PulsingBoneState();
}

class _PulsingBoneState extends State<_PulsingBone>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.25, end: 0.55).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (_, __) => Container(
        width: widget.width == double.infinity ? null : widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(_opacity.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}

class PostCard extends StatefulWidget {
  final Map<String, dynamic> snap;
  final Function(Map<String, dynamic>)? onRateUpdate;
  final bool isVisible;
  final VoidCallback? onCommentTap;
  final VoidCallback? onPostSeen;
  final VideoPlayerController? preloadedVideoController;
  final bool isVideoPreloaded;
  final ImageProvider? preloadedImageProvider;
  final bool isImagePreloaded;
  final Color? skeletonColor;

  // ── NEW: where the follow button is being shown from ────────────────
  final String sourceScreen; // e.g., 'feed', 'comments', 'notifications'

  const PostCard({
    Key? key,
    required this.snap,
    this.onRateUpdate,
    this.isVisible = true,
    this.onCommentTap,
    this.onPostSeen,
    this.preloadedVideoController,
    this.isVideoPreloaded = false,
    this.preloadedImageProvider,
    this.isImagePreloaded = false,
    this.skeletonColor,
    this.sourceScreen = 'feed', // default for backward compatibility
  }) : super(key: key);

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with
        AutomaticKeepAliveClientMixin<PostCard>,
        WidgetsBindingObserver,
        TickerProviderStateMixin {
  // =========================================================================
  // DATA FIELDS
  // =========================================================================
  late int _commentCount;
  bool _isBlocked = false;
  bool _viewRecorded = false;
  late RealtimeChannel _postChannel;

  int _totalRatingsCount = 0;
  double _averageRating = 0.0;
  double? _userRating;
  late List<Map<String, dynamic>> _localRatings;

  String? _resolvedProfImage;
  String? _ownerUsername;
  bool _isTestUser = true;

  bool _isFollowing = false;
  bool _hasPendingRequest = false;
  bool _isLoadingFollow = false;
  bool _showFollowBadge = false;

  late AnimationController _followAnimController;
  late Animation<double> _followScaleAnim;
  late AnimationController _tickAnimController;
  late Animation<double> _tickAnim;

  bool _isCaptionExpanded = false;
  bool _hasBeenSeen = false;

  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = false;
  bool _videoLoadFailed = false;
  bool _isMuted = false;

  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;
  bool _isProfileVideoMuted = true;

  VideoEditResult? _editResult;

  final ApiService _apiService = ApiService();
  final VideoManager _videoManager = VideoManager();
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();

  bool _isPostDataLoading = true;

  final List<String> _reportReasons = [
    'I just don\'t like it',
    'Discriminatory content (e.g., religion, race, gender, or other)',
    'Bullying or harassment',
    'Violence, hate speech, or harmful content',
    'Selling prohibited items',
    'Pornography or nudity',
    'Scam or fraudulent activity',
    'Spam',
    'Misinformation',
  ];

  String get _postId => widget.snap['postId']?.toString() ?? '';
  String _reactionEmoji = '❤️';

  bool get _isVideo {
    final url = (widget.snap['postUrl']?.toString() ?? '').toLowerCase();
    return url.endsWith('.mp4') ||
        url.endsWith('.mov') ||
        url.endsWith('.avi') ||
        url.endsWith('.mkv') ||
        url.contains('video');
  }

  bool get _isProfileVideo {
    final url =
        (_resolvedProfImage ?? widget.snap['profImage']?.toString() ?? '')
            .toLowerCase();
    return url.isNotEmpty &&
        url != 'default' &&
        (url.endsWith('.mp4') ||
            url.endsWith('.mov') ||
            url.endsWith('.avi') ||
            url.endsWith('.mkv') ||
            url.contains('video'));
  }

  bool get _isVideoPlaying =>
      _videoController != null &&
      _videoManager.isCurrentlyPlaying(_videoController!);

  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
  }

  @override
  bool get wantKeepAlive => true;

  VideoEditResult? _parseEditResult() {
    final raw = widget.snap['video_edit_metadata'];
    if (raw == null) return null;
    try {
      final Map<String, dynamic> json = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      return VideoEditResult.fromJson(json, File(''));
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // LIFECYCLE
  // =========================================================================
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _followAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _followScaleAnim = CurvedAnimation(
        parent: _followAnimController, curve: Curves.elasticOut);

    _tickAnimController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _tickAnim =
        CurvedAnimation(parent: _tickAnimController, curve: Curves.easeOut);

    _editResult = _parseEditResult();

    _localRatings = [];
    if (widget.snap['ratings'] != null) {
      _localRatings = (widget.snap['ratings'] as List<dynamic>)
          .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
          .toList();
    }
    _commentCount = (widget.snap['commentsCount'] ?? 0).toInt();

    _setupRealtime();
    _recordView();
    _loadPostCardData();
    _fetchReactionEmoji();

    if (_isVideo) {
      if (widget.preloadedVideoController != null && widget.isVideoPreloaded) {
        _videoController = widget.preloadedVideoController;
        _isVideoInitialized = true;
        _videoLoadFailed = false;
        _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
        _videoController!.addListener(_videoListener);
        _videoController!.setLooping(true);
        _videoController!.addListener(() {
          if (_videoController != null &&
              _videoController!.value.position ==
                  _videoController!.value.duration &&
              _videoController!.value.duration != Duration.zero) {
            _videoController!.seekTo(Duration.zero);
            if (widget.isVisible && !_isVideoPlaying) {
              _videoController!.play();
            }
          }
        });
        if (widget.isVisible) {
          _playVideo();
        } else {
          _pauseVideo();
        }
      } else {
        _isVideoLoading = true;
        Future.delayed(const Duration(milliseconds: 50), () {
          if (mounted && _isVideo && !_isVideoInitialized) {
            unawaited(_initializeVideoPlayer());
          }
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeVideoController();
    _disposeProfileVideoController();
    _postChannel.unsubscribe();
    _followAnimController.dispose();
    _tickAnimController.dispose();
    if (_videoController != null && _isVideoPlaying) {
      _videoManager.pauseVideo(_videoController!);
    }
    super.dispose();
  }

  // =========================================================================
  // ERROR LOGGING HELPERS
  // =========================================================================

  Future<void> _logReactionError({
    required String operationType,
    String? userId,
    Map<String, dynamic>? additionalData,
    required dynamic error,
  }) async {
    try {
      await Supabase.instance.client.from('reactions_error').insert({
        'user_id': userId,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': error is Error ? error.stackTrace?.toString() : null,
        'additional_data': additionalData,
      });
    } catch (_) {}
  }

  Future<void> _logFeedError({
    required String operationType,
    String? userId,
    Map<String, dynamic>? additionalData,
    required dynamic error,
  }) async {
    try {
      await Supabase.instance.client.from('feed_errors').insert({
        'user_id': userId,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': error is Error ? error.stackTrace?.toString() : null,
        'additional_data': additionalData,
      });
    } catch (_) {}
  }

  // =========================================================================
  // FETCH REACTION EMOJI
  // =========================================================================
  Future<void> _fetchReactionEmoji() async {
    final existing = widget.snap['reaction_emoji']?.toString();
    if (existing != null && existing.isNotEmpty && existing != '❤️') {
      setState(() => _reactionEmoji = existing);
      return;
    }
    try {
      final response = await Supabase.instance.client
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', _postId)
          .maybeSingle();
      if (mounted && response != null) {
        final emoji = response['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() => _reactionEmoji = emoji);
        }
      }
    } catch (e) {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      await _logReactionError(
        operationType: 'fetch_reaction_emoji_post_card',
        userId: user?.uid,
        additionalData: {'postId': _postId},
        error: e,
      );
    }
  }

  // =========================================================================
  // RPC DATA LOADING
  // =========================================================================
  Future<void> _loadPostCardData() async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) {
      if (mounted) setState(() => _isPostDataLoading = false);
      return;
    }

    final postId = _postId;
    if (postId.isEmpty) {
      if (mounted) setState(() => _isPostDataLoading = false);
      return;
    }

    try {
      final response = await Supabase.instance.client.rpc(
        'get_post_card_data_text',
        params: {
          'p_post_id': _postId,
          'p_viewer_id': user.uid,
        },
      );

      if (!mounted) return;
      final data = response as Map<String, dynamic>;

      setState(() {
        _resolvedProfImage = data['ownerPhotoUrl'];
        _ownerUsername = data['ownerUsername'];
        _isTestUser = data['viewerIsTestUser'] ?? true;

        _totalRatingsCount = data['ratingsCount'] ?? 0;
        _averageRating = (data['averageRating'] ?? 0.0).toDouble();
        _userRating = data['userRating']?.toDouble();

        final allRatings = data['allRatings'] as List? ?? [];
        _localRatings = allRatings
            .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
            .toList();

        _commentCount = data['commentsCount'] ?? 0;

        _isFollowing = data['isFollowing'] ?? false;
        _hasPendingRequest = data['hasPendingRequest'] ?? false;
        _showFollowBadge = !_isFollowing && !_hasPendingRequest;
        if (_showFollowBadge) _followAnimController.forward();

        _isBlocked = data['isBlocked'] ?? false;

        _isPostDataLoading = false;
      });

      if (_isProfileVideo && !_isProfileVideoInitialized) {
        _initializeProfileVideo();
      }
    } catch (e) {
      await _logFeedError(
        operationType: 'load_post_card_data',
        userId: user.uid,
        additionalData: {'postId': _postId},
        error: e,
      );
      if (mounted) setState(() => _isPostDataLoading = false);
    }
  }

  // =========================================================================
  // REAL-TIME UPDATES
  // =========================================================================
  void _setupRealtime() {
    _postChannel =
        Supabase.instance.client.channel('post_${widget.snap['postId']}');
    _postChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'post_rating',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'postid',
          value: widget.snap['postId']),
      callback: (payload) => _handleRatingUpdate(payload),
    );
    _postChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'comments',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'postid',
          value: widget.snap['postId']),
      callback: (payload) => _refreshCommentCount(),
    );
    _postChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'replies',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'postid',
          value: widget.snap['postId']),
      callback: (payload) => _refreshCommentCount(),
    );
    _postChannel.subscribe();
  }

  void _refreshCommentCount() async {
    try {
      final commentsResponse = await Supabase.instance.client
          .from('comments')
          .select('id')
          .eq('postid', widget.snap['postId']);
      final repliesResponse = await Supabase.instance.client
          .from('replies')
          .select('id')
          .eq('postid', widget.snap['postId']);
      final int total = commentsResponse.length + repliesResponse.length;
      if (mounted) setState(() => _commentCount = total);
    } catch (_) {}
  }

  void _handleRatingUpdate(PostgresChangePayload payload) {
    final newRecord = payload.newRecord;
    final oldRecord = payload.oldRecord;
    final eventType = payload.eventType;
    setState(() {
      switch (eventType) {
        case PostgresChangeEvent.insert:
          if (newRecord != null) {
            _localRatings.insert(0, newRecord);
            _totalRatingsCount++;
            _updateAverageRating();
            final user = Provider.of<UserProvider>(context, listen: false).user;
            if (user != null && newRecord['userid'] == user.uid) {
              _userRating = (newRecord['rating'] as num).toDouble();
            }
          }
          break;
        case PostgresChangeEvent.update:
          if (oldRecord != null && newRecord != null) {
            final index = _localRatings
                .indexWhere((r) => r['userid'] == oldRecord['userid']);
            if (index != -1) _localRatings[index] = newRecord;
            _updateAverageRating();
            final user = Provider.of<UserProvider>(context, listen: false).user;
            if (user != null && newRecord['userid'] == user.uid) {
              _userRating = (newRecord['rating'] as num).toDouble();
            }
          }
          break;
        case PostgresChangeEvent.delete:
          if (oldRecord != null) {
            _localRatings
                .removeWhere((r) => r['userid'] == oldRecord['userid']);
            _totalRatingsCount--;
            _updateAverageRating();
            final user = Provider.of<UserProvider>(context, listen: false).user;
            if (user != null && oldRecord['userid'] == user.uid) {
              _userRating = null;
            }
          }
          break;
        default:
          break;
      }
    });
    if (widget.onRateUpdate != null) {
      widget.onRateUpdate!({
        ...widget.snap,
        'userRating': _userRating,
        'averageRating': _averageRating,
        'totalRatingsCount': _totalRatingsCount,
        'ratings': _localRatings,
      });
    }
  }

  void _updateAverageRating() {
    if (_localRatings.isEmpty) {
      setState(() => _averageRating = 0.0);
      return;
    }
    final total = _localRatings.fold(
        0.0, (sum, r) => sum + (r['rating'] as num).toDouble());
    setState(() => _averageRating = total / _localRatings.length);
  }

  // =========================================================================
  // RATING SUBMISSION
  // =========================================================================
  void _handleRatingSubmitted(double rating) async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;
    final double? oldUserRating = _userRating;
    final bool isUpdating = oldUserRating != null;

    setState(() {
      _userRating = rating;
      final currentTotal = _averageRating * _totalRatingsCount;
      if (isUpdating) {
        _averageRating =
            (currentTotal - oldUserRating! + rating) / _totalRatingsCount;
      } else {
        _totalRatingsCount++;
        _averageRating = (currentTotal + rating) / _totalRatingsCount;
      }
      final idx = _localRatings.indexWhere((r) => r['userid'] == user.uid);
      if (idx != -1) {
        _localRatings[idx]['rating'] = rating;
        _localRatings[idx]['timestamp'] = DateTime.now().toIso8601String();
      } else {
        _localRatings.add({
          'userid': user.uid,
          'postid': widget.snap['postId'],
          'rating': rating,
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    });
    if (widget.onRateUpdate != null) {
      widget.onRateUpdate!({
        ...widget.snap,
        'userRating': rating,
        'averageRating': _averageRating,
        'totalRatingsCount': _totalRatingsCount,
        'ratings': _localRatings,
      });
    }
    try {
      final success = await SupabaseReactionsMethods().reactToPost(
        widget.snap['postId'],
        user.uid,
        rating,
      );
      if (success != 'success' && mounted) _loadPostCardData();
    } catch (e) {
      if (mounted) _loadPostCardData();
    }
  }

  // =========================================================================
  // FOLLOW HANDLER (UPDATED)
  // =========================================================================

  Future<void> _handleFollowTap() async {
    final user = Provider.of<UserProvider>(context, listen: false).user;

    if (user == null || _isLoadingFollow) {
      return;
    }

    final postOwnerId = widget.snap['uid']?.toString() ?? '';
    if (postOwnerId.isEmpty) {
      return;
    }

    setState(() => _isLoadingFollow = true);
    try {
      // Log every tap
      AnalyticsService.logFollowPress(
        followerUid: user.uid,
        followedUid: postOwnerId,
        sourceScreen: widget.sourceScreen,
      );

      // --- perform the actual action ---
      if (_isFollowing) {
        await SupabaseProfileMethods().unfollowUser(user.uid, postOwnerId);
        if (mounted) {
          setState(() {
            _isFollowing = false;
            _hasPendingRequest = false;
            _showFollowBadge = true;
          });
          _followAnimController.forward(from: 0.0);
        }
      } else if (_hasPendingRequest) {
        await SupabaseProfileMethods()
            .declineFollowRequest(postOwnerId, user.uid);
        if (mounted) {
          setState(() {
            _hasPendingRequest = false;
            _showFollowBadge = true;
          });
          _followAnimController.forward(from: 0.0);
        }
      } else {
        // Optimistic UI for follow
        setState(() => _isFollowing = true);
        _tickAnimController.forward(from: 0.0).then((_) {
          if (mounted) {
            _followAnimController.reverse().then((_) {
              if (mounted) setState(() => _showFollowBadge = false);
            });
          }
        });

        SupabaseProfileMethods()
            .followUser(user.uid, postOwnerId)
            .then((_) async {
          final pending = await Supabase.instance.client
              .from('user_follow_request')
              .select()
              .eq('user_id', postOwnerId)
              .eq('requester_id', user.uid)
              .maybeSingle();
          if (mounted && pending != null) {
            setState(() {
              _isFollowing = false;
              _hasPendingRequest = true;
              _showFollowBadge = true;
            });
            _followAnimController.forward(from: 0.0);
          }
        }).catchError((_) {
          if (mounted) {
            setState(() {
              _isFollowing = false;
              _showFollowBadge = true;
            });
            _tickAnimController.reset();
            _followAnimController.forward(from: 0.0);
            showSnackBar(context, 'Please try again');
          }
        });
      }
    } catch (_) {
      if (mounted) showSnackBar(context, 'Please try again');
    } finally {
      if (mounted) setState(() => _isLoadingFollow = false);
    }
  }

  // =========================================================================
  // VIEW RECORDING
  // =========================================================================
  void _recordView() async {
    if (_viewRecorded) return;
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user != null) {
      await _apiService.recordPostView(widget.snap['postId'], user.uid);
      if (mounted) setState(() => _viewRecorded = true);
    }
  }

  void _markPostAsSeenIfVisible() {
    if (widget.isVisible && !_hasBeenSeen && widget.onPostSeen != null) {
      _hasBeenSeen = true;
      widget.onPostSeen!();
    }
  }

  // =========================================================================
  // VIDEO PLAYER
  // =========================================================================
  Future<void> _initializeVideoPlayer() async {
    if (_isVideoLoading && !_videoLoadFailed) {
      // Already in progress
    } else if (_isVideoInitialized) {
      return;
    }

    setState(() {
      _isVideoLoading = true;
      _videoLoadFailed = false;
    });

    try {
      final videoUrl = widget.snap['postUrl']?.toString() ?? '';
      if (videoUrl.isEmpty) throw Exception('Empty video URL');
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      _videoController!.addListener(_videoListener);
      await _videoController!.initialize().timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw Exception('Video loading timeout'),
          );
      _videoController!.setLooping(true);
      if (mounted) {
        setState(() {
          _isVideoInitialized = true;
          _isVideoLoading = false;
          _videoLoadFailed = false;
        });
        if (widget.isVisible) {
          _playVideo();
        } else {
          _pauseVideo();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isVideoLoading = false;
          _videoLoadFailed = true;
        });
      }
    }
  }

  void _disposeVideoController() {
    if (_videoController != null) {
      _videoController!.removeListener(_videoListener);
      if (widget.preloadedVideoController != null &&
          widget.preloadedVideoController == _videoController) {
        if (_videoController!.value.isPlaying) _videoController!.pause();
      } else {
        if (_isVideoPlaying) _videoManager.pauseVideo(_videoController!);
        try {
          _videoController!.pause();
          _videoController!.dispose();
        } catch (e) {}
      }
      _videoController = null;
    }
    _isVideoInitialized = false;
    _isVideoLoading = false;
  }

  void _videoListener() {
    if (!mounted) return;
    if (_videoController != null &&
        _videoController!.value.position == _videoController!.value.duration &&
        _videoController!.value.duration != Duration.zero) {
      _videoController!.seekTo(Duration.zero);
      if (widget.isVisible && !_isVideoPlaying) {
        _videoController!.play();
      }
    }
    if (_videoController != null && _isVideoInitialized) {
      final isActuallyPlaying = _videoController!.value.isPlaying;
      final shouldBePlaying =
          _videoManager.isCurrentlyPlaying(_videoController!);
      if (isActuallyPlaying != shouldBePlaying && widget.isVisible) {
        if (shouldBePlaying && !isActuallyPlaying) {
          _videoController!.play();
        } else if (!shouldBePlaying && isActuallyPlaying) {
          _videoController!.pause();
        }
      }
    }
  }

  void _playVideo() {
    if (_videoController != null &&
        _isVideoInitialized &&
        mounted &&
        widget.isVisible) {
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      _videoManager.playVideo(_videoController!, _postId);
      if (mounted) setState(() {});
    }
  }

  void _pauseVideo() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      _videoManager.pauseVideo(_videoController!);
      if (mounted) setState(() {});
    }
  }

  void _toggleMute() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      setState(() {
        _isMuted = !_isMuted;
        _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      });
    }
  }

  void _toggleVideoPlayback() {
    if (!_isVideoInitialized || _videoController == null) return;
    if (_isVideoPlaying) {
      _pauseVideo();
    } else {
      _playVideo();
    }
    if (mounted) setState(() {});
  }

  // =========================================================================
  // PROFILE VIDEO
  // =========================================================================
  Future<void> _initializeProfileVideo() async {
    if (_profileVideoController != null || _isProfileVideoInitialized) return;
    try {
      final videoUrl = _resolvedProfImage?.isNotEmpty == true
          ? _resolvedProfImage!
          : (widget.snap['profImage']?.toString() ?? '');
      if (videoUrl.isEmpty) throw Exception('Empty profile video URL');
      _profileVideoController = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _profileVideoController!.addListener(_profileVideoListener);
      await _profileVideoController!.initialize();
      await _profileVideoController!.setVolume(0.0);
      await _profileVideoController!.setLooping(true);
      if (mounted) {
        setState(() {
          _isProfileVideoInitialized = true;
          _isProfileVideoMuted = true;
        });
        if (widget.isVisible) {
          _playProfileVideo();
        } else {
          _pauseProfileVideo();
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isProfileVideoInitialized = false);
    }
  }

  void _disposeProfileVideoController() {
    if (_profileVideoController != null) {
      _profileVideoController!.removeListener(_profileVideoListener);
      _profileVideoController!.pause();
      _profileVideoController!.dispose();
      _profileVideoController = null;
    }
    _isProfileVideoInitialized = false;
  }

  void _profileVideoListener() {
    if (!mounted) return;
    if (_profileVideoController != null &&
        _profileVideoController!.value.position ==
            _profileVideoController!.value.duration &&
        _profileVideoController!.value.duration != Duration.zero) {
      _profileVideoController!.seekTo(Duration.zero);
      if (widget.isVisible) _profileVideoController!.play();
    }
  }

  void _playProfileVideo() {
    if (_profileVideoController != null &&
        _isProfileVideoInitialized &&
        mounted &&
        widget.isVisible) {
      _profileVideoController!.play();
    }
  }

  void _pauseProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      _profileVideoController!.pause();
    }
  }

  // =========================================================================
  // NAVIGATION
  // =========================================================================
  void _navigateToProfile() {
    if (_isVideo && _isVideoInitialized) _pauseVideo();
    if (_isProfileVideo && _isProfileVideoInitialized) _pauseProfileVideo();
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (context) => ProfileScreen(uid: widget.snap['uid'])),
    );
  }

  void _openCommentsPanel() {
    if (_isVideo && _isVideoInitialized) _pauseVideo();
    if (_isProfileVideo && _isProfileVideoInitialized) _pauseProfileVideo();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentsBottomSheet(
        postId: widget.snap['postId'],
        postImage: widget.snap['postUrl'],
        isVideo: _isVideo,
        onClose: () {
          if (widget.isVisible) {
            if (_isVideo && _isVideoInitialized && !_isVideoPlaying) {
              _playVideo();
            }
            if (_isProfileVideo && _isProfileVideoInitialized) {
              _playProfileVideo();
            }
          }
        },
        videoController: _videoController,
      ),
    ).then((_) => _refreshCommentCount());
  }

  void _navigateToShare(_ColorSet colors) {
    if (_isVideo && _isVideoInitialized) _pauseVideo();
    if (_isProfileVideo && _isProfileVideoInitialized) _pauseProfileVideo();
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;
    showDialog(
      context: context,
      builder: (context) =>
          PostShare(currentUserId: user.uid, postId: widget.snap['postId']),
    );
  }

  // =========================================================================
  // REPORT / DELETE
  // =========================================================================
  void _showReportDialog(_ColorSet colors) {
    String? selectedReason;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: colors.cardColor,
          title: Text('Report Post', style: TextStyle(color: colors.textColor)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Thank you for helping keep our community safe.\n\nPlease let us know the reason for reporting this content.',
                  style: TextStyle(color: colors.textColor.withOpacity(0.7)),
                ),
                const SizedBox(height: 16),
                ..._reportReasons
                    .map((reason) => RadioListTile<String>(
                          title: Text(reason,
                              style: TextStyle(color: colors.textColor)),
                          value: reason,
                          groupValue: selectedReason,
                          activeColor: colors.textColor,
                          onChanged: (value) =>
                              setState(() => selectedReason = value),
                        ))
                    .toList(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: colors.textColor)),
            ),
            TextButton(
              onPressed: selectedReason != null
                  ? () => _submitReport(selectedReason!)
                  : null,
              child: Text('Submit', style: TextStyle(color: colors.textColor)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitReport(String reason) async {
    Navigator.pop(context);
    try {
      await _apiService.reportPost(widget.snap['postId'], reason);
      showSnackBar(context, 'Report submitted successfully');
    } catch (e) {
      showSnackBar(
          context, 'Please try again or contact us at ratedly9@gmail.com');
    }
  }

  Future<void> _deletePost() async {
    try {
      await _apiService.deletePost(widget.snap['postId']);
      showSnackBar(context, 'Post deleted successfully');
    } catch (e) {
      showSnackBar(
          context, 'Please try again or contact us at ratedly9@gmail.com');
    }
  }

  void _showDeleteConfirmation(_ColorSet colors) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.cardColor,
        title: Text('Delete Post', style: TextStyle(color: colors.textColor)),
        content: Text('Are you sure you want to delete this post?',
            style: TextStyle(color: colors.textColor.withOpacity(0.7))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: colors.textColor)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deletePost();
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // LIFECYCLE OVERRIDES
  // =========================================================================
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseVideo();
      _pauseProfileVideo();
    }
  }

  @override
  void didUpdateWidget(PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible && !_hasBeenSeen && widget.onPostSeen != null) {
      _markPostAsSeenIfVisible();
    }
    if (oldWidget.isVisible != widget.isVisible && _isVideo) {
      if (widget.isVisible) {
        if (_isVideoInitialized && !_isVideoPlaying) {
          _playVideo();
        } else if (!_isVideoInitialized && !_isVideoLoading) {
          unawaited(_initializeVideoPlayer());
        }
      } else {
        if (_isVideoInitialized && _isVideoPlaying) _pauseVideo();
      }
    }
    if (oldWidget.isVisible != widget.isVisible && _isProfileVideo) {
      if (widget.isVisible) {
        if (_isProfileVideoInitialized) {
          _playProfileVideo();
        } else {
          _initializeProfileVideo();
        }
      } else {
        if (_isProfileVideoInitialized) _pauseProfileVideo();
      }
    }
  }

  // =========================================================================
  // UI HELPERS
  // =========================================================================
  Widget _buildCaptionWithVisibility(_ColorSet colors) {
    final caption = widget.snap['description'].toString();
    final bool needsTruncation = caption.length > 80;
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w500,
      fontFamily: 'Inter',
      shadows: [
        Shadow(
            offset: const Offset(1.0, 1.0),
            blurRadius: 3.0,
            color: Colors.black.withOpacity(0.8)),
        Shadow(
            offset: const Offset(-1.0, -1.0),
            blurRadius: 3.0,
            color: Colors.black.withOpacity(0.8)),
      ],
    );

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
      child: _isCaptionExpanded
          ? GestureDetector(
              onTap: () => setState(() => _isCaptionExpanded = false),
              child: Text(caption, style: textStyle),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isCaptionExpanded = true),
                    child: Text(caption,
                        style: textStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (needsTruncation) const SizedBox(width: 4),
                if (needsTruncation)
                  GestureDetector(
                    onTap: () => setState(() => _isCaptionExpanded = true),
                    child: Text(
                      'more',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Inter',
                        shadows: [
                          Shadow(
                              offset: const Offset(1.0, 1.0),
                              blurRadius: 3.0,
                              color: Colors.black.withOpacity(0.8)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildCommentButton(_ColorSet colors) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        IconButton(
          icon:
              const Icon(Icons.comment_outlined, color: Colors.white, size: 28),
          onPressed: () => widget.onCommentTap?.call(),
        ),
        if (_commentCount > 0)
          Positioned(
            top: -6,
            left: -6,
            child: Container(
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              decoration: BoxDecoration(
                  color: colors.cardColor, shape: BoxShape.circle),
              child: Center(
                child: Text(
                  _commentCount.toString(),
                  style: TextStyle(
                      color: colors.textColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildProfilePicture(_ColorSet colors) {
    final profImage = _resolvedProfImage?.isNotEmpty == true
        ? _resolvedProfImage!
        : (widget.snap['profImage']?.toString() ?? '');
    final isDefault = profImage.isEmpty || profImage == 'default';
    if (isDefault) {
      return Container(
        width: 42,
        height: 42,
        decoration:
            const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: Icon(Icons.account_circle, size: 42, color: colors.iconColor),
      );
    }
    if (_isProfileVideo) return _buildProfileVideoPlayer();
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        image:
            DecorationImage(image: NetworkImage(profImage), fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildProfileVideoPlayer() {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
        child: Center(
            child: CircularProgressIndicator(
                color: Colors.grey[700], strokeWidth: 2.0)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 42,
        height: 42,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _profileVideoController!.value.size.width,
            height: _profileVideoController!.value.size.height,
            child: VideoPlayer(_profileVideoController!),
          ),
        ),
      ),
    );
  }

  Widget _buildProfileWithFollow(_ColorSet colors) {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    final postOwnerId = widget.snap['uid']?.toString() ?? '';
    final isOwnPost = user?.uid == postOwnerId;

    const double pfpSize = 42;
    const double badgeSize = 20;
    const double stackH = pfpSize + badgeSize / 2;

    return SizedBox(
      width: pfpSize,
      height: stackH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: GestureDetector(
                onTap: _navigateToProfile, child: _buildProfilePicture(colors)),
          ),
          if (!isOwnPost && _showFollowBadge)
            Positioned(
              top: pfpSize - badgeSize / 2,
              left: (pfpSize - badgeSize) / 2,
              child: GestureDetector(
                onTap: _handleFollowTap,
                child: ScaleTransition(
                  scale: _followScaleAnim,
                  child: AnimatedBuilder(
                    animation: _tickAnim,
                    builder: (_, __) {
                      final showTick = _isFollowing || _hasPendingRequest;
                      return Container(
                        width: badgeSize,
                        height: badgeSize,
                        decoration: BoxDecoration(
                          color: showTick
                              ? Colors.grey[600]!.withOpacity(0.85)
                              : Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.black, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withOpacity(0.35),
                                blurRadius: 4,
                                offset: const Offset(0, 1))
                          ],
                        ),
                        child: Center(
                          child: _isLoadingFollow
                              ? const SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                      color: Colors.grey, strokeWidth: 1.5))
                              : showTick
                                  ? Icon(
                                      _hasPendingRequest
                                          ? Icons.schedule
                                          : Icons.check,
                                      size: 11,
                                      color: Colors.white)
                                  : const Icon(Icons.add,
                                      size: 13, color: Color(0xFF121212)),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRightActionButtons(_ColorSet colors) {
    return Column(
      children: [
        _buildProfileWithFollow(colors),
        const SizedBox(height: 20),
        _buildCommentButton(colors),
        const SizedBox(height: 8),
        IconButton(
          icon: const Icon(Icons.send, color: Colors.white, size: 28),
          onPressed: () => _navigateToShare(colors),
        ),
        const SizedBox(height: 8),
        if (_isVideo && _isVideoInitialized)
          IconButton(
            icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up,
                color: Colors.white, size: 24),
            onPressed: _toggleMute,
          ),
      ],
    );
  }

  Widget _buildRatingBarSkeleton() {
    return const SizedBox(
      height: 48,
      child: Row(
        children: [
          _PulsingBone(width: 36, height: 36, borderRadius: 18),
          SizedBox(width: 10),
          Expanded(
            child: _PulsingBone(
                width: double.infinity, height: 14, borderRadius: 7),
          ),
          SizedBox(width: 10),
          _PulsingBone(width: 36, height: 36, borderRadius: 18),
        ],
      ),
    );
  }

  Widget _buildVoterCountSkeleton() {
    return const _PulsingBone(width: 80, height: 28, borderRadius: 20);
  }

  Widget _buildBottomOverlay(model.AppUser user, _ColorSet colors) {
    final double initialPos = _userRating == null ? 5.0 : _averageRating;

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isPostDataLoading)
            _buildRatingBarSkeleton()
          else
            RatingBar(
              averageRating: _averageRating,
              reactionEmoji: _reactionEmoji,
              initialThumbPosition: initialPos,
              onRatingEnd: _handleRatingSubmitted,
              hasUserRated: _userRating != null,
              userRating: _userRating,
              userProfilePhoto: user.photoUrl,
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _navigateToProfile,
                  child: VerifiedUsernameWidget(
                    username: _ownerUsername ??
                        widget.snap['username']?.toString() ??
                        'Unknown',
                    uid: widget.snap['uid']?.toString() ?? '',
                    countryCode: widget.snap['country']?.toString(),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: 'Inter',
                      shadows: [
                        Shadow(
                          offset: const Offset(1.0, 1.0),
                          blurRadius: 3.0,
                          color: Colors.black.withOpacity(0.8),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_isPostDataLoading)
                _buildVoterCountSkeleton()
              else
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: _totalRatingsCount == 0
                      ? Text(
                          _isTestUser
                              ? 'Start the Reaction'
                              : 'Be the first to react',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        )
                      : Text(
                          '$_totalRatingsCount '
                          '${_totalRatingsCount == 1 ? 'voter' : 'voters'}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.snap['description']?.toString().isNotEmpty ?? false)
            _buildCaptionWithVisibility(colors),
        ],
      ),
    );
  }

  Widget _buildMediaContent(_ColorSet colors) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: _isVideo ? _buildVideoPlayer(colors) : _buildImageContent(colors),
    );
  }

  Widget _buildVideoPlayer(_ColorSet colors) {
    final VideoEditResult? er = _editResult;

    final List<double> matrix = er != null
        ? er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix)
        : [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

    final int quarters = er?.rotationQuarters ?? 0;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_isVideoInitialized)
            GestureDetector(
              onTap: _toggleVideoPlayback,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final videoAspect = _videoController!.value.aspectRatio;
                  final containerAspect =
                      constraints.maxWidth / constraints.maxHeight;

                  double displayWidth, displayHeight;
                  if (videoAspect > containerAspect) {
                    displayHeight = constraints.maxHeight;
                    displayWidth = displayHeight * videoAspect;
                  } else {
                    displayWidth = constraints.maxWidth;
                    displayHeight = displayWidth / videoAspect;
                  }

                  final offsetX = (constraints.maxWidth - displayWidth) / 2;
                  final offsetY = (constraints.maxHeight - displayHeight) / 2;

                  return Stack(
                    children: [
                      Positioned(
                        left: offsetX,
                        top: offsetY,
                        width: displayWidth,
                        height: displayHeight,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.matrix(matrix),
                          child: Transform.rotate(
                            angle: quarters * math.pi / 2,
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: SizedBox(
                                width: _videoController!.value.size.width,
                                height: _videoController!.value.size.height,
                                child: VideoPlayer(_videoController!),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (er != null && er.strokes.isNotEmpty)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _ScaledOverlayPainter(
                                strokes: er.strokes,
                                displayRect: Rect.fromLTWH(
                                  offsetX,
                                  offsetY,
                                  displayWidth,
                                  displayHeight,
                                ),
                                videoSize: Size(
                                  _videoController!.value.size.width,
                                  _videoController!.value.size.height,
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (er != null && er.overlays.isNotEmpty)
                        ...er.overlays.map((overlay) {
                          final double left =
                              offsetX + (overlay.position.dx * displayWidth);
                          final double top =
                              offsetY + (overlay.position.dy * displayHeight);
                          final double scale =
                              displayWidth / _videoController!.value.size.width;
                          final scaledOverlay = overlay.copyWith(
                              fontSize: overlay.fontSize * scale);
                          return Positioned(
                            left: left.clamp(
                                offsetX, offsetX + displayWidth - 10),
                            top: top.clamp(
                                offsetY, offsetY + displayHeight - 10),
                            child: Stack(clipBehavior: Clip.none, children: [
                              Text(overlay.text,
                                  style: overlayShadowStyle(scaledOverlay)),
                              Text(overlay.text,
                                  style: overlayTextStyle(scaledOverlay)),
                            ]),
                          );
                        }),
                    ],
                  );
                },
              ),
            )
          else if (_isVideoLoading)
            Container(
              color: Colors.black,
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[800]!.withOpacity(0.8),
                    shape: BoxShape.circle,
                  ),
                  child: CircularProgressIndicator(
                      color: Colors.grey[300]!, strokeWidth: 2),
                ),
              ),
            )
          else if (_videoLoadFailed)
            Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam, size: 50, color: Colors.grey[300]!),
                    const SizedBox(height: 8),
                    Text('Video not available',
                        style: TextStyle(color: Colors.grey[300]!)),
                  ],
                ),
              ),
            )
          else
            ColoredBox(color: widget.skeletonColor ?? const Color(0xFF333333)),
          if (_isVideoInitialized && !_isVideoPlaying)
            GestureDetector(
              onTap: _playVideo,
              child: Container(
                color: Colors.transparent,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: const BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow,
                          size: 40, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageContent(_ColorSet colors) {
    final placeholderColor = widget.skeletonColor ?? const Color(0xFF1C1C1C);
    final imageUrl = widget.snap['postUrl']?.toString() ?? '';
    if (widget.preloadedImageProvider != null && widget.isImagePreloaded) {
      return Container(
        decoration: BoxDecoration(
          image: DecorationImage(
              image: widget.preloadedImageProvider!, fit: BoxFit.cover),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(color: placeholderColor),
      errorWidget: (context, url, error) => Container(
        color: placeholderColor,
        child: Center(
            child:
                Icon(Icons.broken_image, size: 48, color: Colors.grey[300]!)),
      ),
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    WidgetsBinding.instance
        .addPostFrameCallback((_) => _markPostAsSeenIfVisible());

    if (_isBlocked) {
      return const BlockedContentMessage(
          message: 'Post unavailable due to blocking');
    }

    final user = Provider.of<UserProvider>(context).user;
    if (user == null) return const SizedBox.shrink();

    final scaffoldBg = widget.skeletonColor ?? const Color(0xFF1C1C1C);

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Stack(
        children: [
          _buildMediaContent(colors),
          Positioned(
            bottom: 260,
            right: 16,
            child: _buildRightActionButtons(colors),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: _buildBottomOverlay(user, colors),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SCALED OVERLAY PAINTER
// =============================================================================
class _ScaledOverlayPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final Rect displayRect;
  final Size videoSize;

  _ScaledOverlayPainter({
    required this.strokes,
    required this.displayRect,
    required this.videoSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;

    final scaleX = displayRect.width / videoSize.width;
    final scaleY = displayRect.height / videoSize.height;

    canvas.save();
    canvas.translate(displayRect.left, displayRect.top);
    canvas.scale(scaleX, scaleY);

    DrawingPainter(strokes: strokes, currentStroke: null)
        .paint(canvas, videoSize);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScaledOverlayPainter old) =>
      old.strokes != strokes ||
      old.displayRect != displayRect ||
      old.videoSize != videoSize;
}
