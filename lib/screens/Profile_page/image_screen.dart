import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/widgets/rating_list_screen_postcard.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';
import 'package:Ratedly/widgets/postshare.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/widgets/blocked_content_message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:video_player/video_player.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:Ratedly/services/ads.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';

// ── VideoManager (unchanged) ────────────────────────────────────────────────
class VideoManager {
  static final VideoManager _instance = VideoManager._internal();
  factory VideoManager() => _instance;
  VideoManager._internal();

  VideoPlayerController? _currentPlayingController;
  String? _currentPostId;

  void playVideo(VideoPlayerController controller, String postId) {
    if (_currentPlayingController != null &&
        _currentPlayingController != controller) {
      _currentPlayingController!.pause();
    }
    _currentPlayingController = controller;
    _currentPostId = postId;
    controller.play();
  }

  void pauseVideo(VideoPlayerController controller) {
    if (_currentPlayingController == controller) {
      controller.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
  }

  void disposeController(VideoPlayerController controller, String postId) {
    if (_currentPlayingController == controller) {
      _currentPlayingController = null;
      _currentPostId = null;
    }
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
  }

  String? get currentPlayingPostId => _currentPostId;

  void pauseCurrentVideo() {
    if (_currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
  }
}

// ── Color schemes (unchanged) ───────────────────────────────────────────────
class _ImageViewColorSet {
  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color dialogBackgroundColor;
  final Color dialogTextColor;
  final Color avatarBackgroundColor;
  final Color progressIndicatorColor;
  final Color buttonBackgroundColor;
  final Color dividerColor;
  final Color radioActiveColor;
  final Color errorIconColor;
  final Color badgeBackgroundColor;
  final Color badgeTextColor;

  _ImageViewColorSet({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.dialogBackgroundColor,
    required this.dialogTextColor,
    required this.avatarBackgroundColor,
    required this.progressIndicatorColor,
    required this.buttonBackgroundColor,
    required this.dividerColor,
    required this.radioActiveColor,
    required this.errorIconColor,
    required this.badgeBackgroundColor,
    required this.badgeTextColor,
  });
}

class _ImageViewDarkColors extends _ImageViewColorSet {
  _ImageViewDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          textColor: const Color(0xFFd9d9d9),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          dialogBackgroundColor: const Color(0xFF121212),
          dialogTextColor: const Color(0xFFd9d9d9),
          avatarBackgroundColor: const Color(0xFF333333),
          progressIndicatorColor: Colors.white70,
          buttonBackgroundColor: const Color(0xFF333333),
          dividerColor: const Color(0xFF333333),
          radioActiveColor: const Color(0xFFd9d9d9),
          errorIconColor: Colors.white54,
          badgeBackgroundColor: const Color(0xFF333333),
          badgeTextColor: const Color(0xFFd9d9d9),
        );
}

class _ImageViewLightColors extends _ImageViewColorSet {
  _ImageViewLightColors()
      : super(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
          dialogBackgroundColor: Colors.white,
          dialogTextColor: Colors.black,
          avatarBackgroundColor: Colors.grey[300]!,
          progressIndicatorColor: Colors.grey[700]!,
          buttonBackgroundColor: Colors.grey[300]!,
          dividerColor: Colors.grey[300]!,
          radioActiveColor: Colors.black,
          errorIconColor: Colors.grey[600]!,
          badgeBackgroundColor: Colors.grey[300]!,
          badgeTextColor: Colors.black,
        );
}

// ── Follow badge (unchanged) ────────────────────────────────────────────────
class _FollowBadge extends StatefulWidget {
  final String ownerUid;
  final String currentUserId;

  const _FollowBadge({
    Key? key,
    required this.ownerUid,
    required this.currentUserId,
  }) : super(key: key);

  @override
  State<_FollowBadge> createState() => _FollowBadgeState();
}

class _FollowBadgeState extends State<_FollowBadge>
    with TickerProviderStateMixin {
  bool _isFollowing = false;
  bool _hasPendingRequest = false;
  bool _isLoadingFollow = false;
  bool _showBadge = false;

  late AnimationController _scaleController;
  late Animation<double> _scaleAnim;
  late AnimationController _tickController;
  late Animation<double> _tickAnim;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _scaleAnim =
        CurvedAnimation(parent: _scaleController, curve: Curves.elasticOut);
    _tickController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));
    _tickAnim = CurvedAnimation(parent: _tickController, curve: Curves.easeOut);
    _loadStatus();
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _tickController.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    if (widget.ownerUid.isEmpty || widget.ownerUid == widget.currentUserId)
      return;
    try {
      final supabase = Supabase.instance.client;
      final following = await supabase
          .from('user_following')
          .select()
          .eq('user_id', widget.currentUserId)
          .eq('following_id', widget.ownerUid)
          .maybeSingle();
      final pending = await supabase
          .from('user_follow_request')
          .select()
          .eq('user_id', widget.ownerUid)
          .eq('requester_id', widget.currentUserId)
          .maybeSingle();
      if (mounted) {
        final isFollowing = following != null;
        final hasPending = pending != null;
        setState(() {
          _isFollowing = isFollowing;
          _hasPendingRequest = hasPending;
          _showBadge = !isFollowing && !hasPending;
        });
        if (_showBadge) _scaleController.forward();
      }
    } catch (_) {}
  }

  Future<void> _handleTap() async {
    if (_isLoadingFollow) return;
    setState(() => _isLoadingFollow = true);
    try {
      if (_isFollowing) {
        await SupabaseProfileMethods()
            .unfollowUser(widget.currentUserId, widget.ownerUid);
        if (mounted) {
          setState(() {
            _isFollowing = false;
            _hasPendingRequest = false;
            _showBadge = true;
          });
          _scaleController.forward(from: 0.0);
        }
      } else if (_hasPendingRequest) {
        await SupabaseProfileMethods()
            .declineFollowRequest(widget.ownerUid, widget.currentUserId);
        if (mounted) {
          setState(() {
            _hasPendingRequest = false;
            _showBadge = true;
          });
          _scaleController.forward(from: 0.0);
        }
      } else {
        setState(() => _isFollowing = true);
        _tickController.forward(from: 0.0).then((_) {
          if (mounted) {
            _scaleController.reverse().then((_) {
              if (mounted) setState(() => _showBadge = false);
            });
          }
        });
        SupabaseProfileMethods()
            .followUser(widget.currentUserId, widget.ownerUid)
            .then((_) async {
          final pending = await Supabase.instance.client
              .from('user_follow_request')
              .select()
              .eq('user_id', widget.ownerUid)
              .eq('requester_id', widget.currentUserId)
              .maybeSingle();
          if (mounted && pending != null) {
            setState(() {
              _isFollowing = false;
              _hasPendingRequest = true;
              _showBadge = true;
            });
            _scaleController.forward(from: 0.0);
          }
        }).catchError((_) {
          if (mounted) {
            setState(() {
              _isFollowing = false;
              _showBadge = true;
            });
            _tickController.reset();
            _scaleController.forward(from: 0.0);
          }
        });
      }
    } catch (_) {
      // silent
    } finally {
      if (mounted) setState(() => _isLoadingFollow = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_showBadge || widget.ownerUid == widget.currentUserId) {
      return const SizedBox.shrink();
    }
    const double badgeSize = 18.0;
    return GestureDetector(
      onTap: _handleTap,
      child: ScaleTransition(
        scale: _scaleAnim,
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
                        width: 9,
                        height: 9,
                        child: CircularProgressIndicator(
                            color: Colors.grey, strokeWidth: 1.5))
                    : showTick
                        ? Icon(
                            _hasPendingRequest ? Icons.schedule : Icons.check,
                            size: 10,
                            color: Colors.white)
                        : const Icon(Icons.add,
                            size: 11, color: Color(0xFF121212)),
              ),
            );
          },
        ),
      ),
    );
  }
}

Widget _buildAvatarWithFollow({
  required Widget avatar,
  required double avatarDiameter,
  required String ownerUid,
  required String currentUserId,
}) {
  const double badgeSize = 18.0;
  final double stackH = avatarDiameter + badgeSize / 2;
  return SizedBox(
    width: avatarDiameter,
    height: stackH,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(top: 0, left: 0, child: avatar),
        Positioned(
          top: avatarDiameter - badgeSize / 2,
          left: (avatarDiameter - badgeSize) / 2,
          child: _FollowBadge(ownerUid: ownerUid, currentUserId: currentUserId),
        ),
      ],
    ),
  );
}

// ── ImageViewScreen ─────────────────────────────────────────────────────────
class ImageViewScreen extends StatefulWidget {
  final String imageUrl;
  final String postId;
  final String description;
  final String userId;
  final String username;
  final String profImage;
  final dynamic datePublished;
  final VoidCallback? onPostDeleted;
  final Map<String, dynamic>? videoEditMetadata;

  const ImageViewScreen({
    Key? key,
    required this.imageUrl,
    required this.postId,
    required this.description,
    required this.userId,
    required this.username,
    required this.profImage,
    required this.datePublished,
    this.onPostDeleted,
    this.videoEditMetadata,
  }) : super(key: key);

  @override
  State<ImageViewScreen> createState() => _ImageViewScreenState();
}

class _ImageViewScreenState extends State<ImageViewScreen>
    with WidgetsBindingObserver {
  late int _commentCount;
  bool _isBlocked = false;
  bool _viewRecorded = false;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();
  bool _isDeleting = false;

  BannerAd? _bannerAd;
  bool _isAdLoaded = false;

  double _averageRating = 0.0;
  int _totalRatingsCount = 0;
  double? _userRating;
  bool _isLoadingRatings = true;
  late RealtimeChannel _postChannel;
  late RealtimeChannel _commentsChannel;
  late RealtimeChannel _repliesChannel;

  // Reaction emoji of the post (default ❤️)
  String _reactionEmoji = '❤️';

  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = false;
  bool _isMuted = false;
  final VideoManager _videoManager = VideoManager();

  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;
  bool _isProfileVideoMuted = true;

  late List<Map<String, dynamic>> _localRatings;
  VideoEditResult? _editResult;

  final List<String> reportReasons = [
    'I just don\'t like it',
    'Discriminatory content',
    'Bullying or harassment',
    'Violence or hate speech',
    'Selling prohibited items',
    'Pornography or nudity',
    'Scam or fraudulent activity',
    'Spam',
    'Misinformation',
  ];

  bool get _isVideo {
    final url = widget.imageUrl.toLowerCase();
    return url.endsWith('.mp4') ||
        url.endsWith('.mov') ||
        url.endsWith('.avi') ||
        url.endsWith('.mkv') ||
        url.contains('video');
  }

  bool get _isProfileVideo {
    final url = widget.profImage.toLowerCase();
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

  bool get _isCurrentUserOwner {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    return user != null && user.uid == widget.userId;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _localRatings = [];
    _commentCount = 0;

    if (widget.videoEditMetadata != null) {
      try {
        _editResult =
            VideoEditResult.fromJson(widget.videoEditMetadata!, File(''));
      } catch (_) {}
    }

    _fetchPostReactionEmoji();
    _fetchCommentsCount();
    _checkBlockStatus();
    _setupRealtime();
    _setupCommentsRealtime();
    _fetchInitialRatings();
    _loadBannerAd();
    _recordView();

    if (_isVideo) {
      _initializeVideoPlayer();
    }

    if (_isProfileVideo) {
      _initializeProfileVideo();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseVideo();
      _pauseProfileVideo();
    }
  }

  // ── Fetch reaction emoji from posts table ─────────────────────────────────
  Future<void> _fetchPostReactionEmoji() async {
    try {
      final response = await Supabase.instance.client
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', widget.postId)
          .maybeSingle();
      if (mounted && response != null) {
        final emoji = response['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() => _reactionEmoji = emoji);
        }
      }
    } catch (_) {
      // keep default emoji
    }
  }

  // ── Profile video (unchanged) ─────────────────────────────────────────────
  Future<void> _initializeProfileVideo() async {
    if (_profileVideoController != null) {
      await _profileVideoController!.dispose();
      setState(() {
        _profileVideoController = null;
        _isProfileVideoInitialized = false;
      });
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.profImage),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      await controller.initialize();
      await controller.setVolume(0.0);
      await controller.setLooping(true);
      await controller.play();

      if (mounted) {
        setState(() {
          _profileVideoController = controller;
          _isProfileVideoInitialized = true;
          _isProfileVideoMuted = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProfileVideoInitialized = false);
      }
    }
  }

  Widget _buildProfileVideoPlayer(_ImageViewColorSet colors) {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.avatarBackgroundColor,
        ),
        child: Center(
          child:
              CircularProgressIndicator(color: colors.progressIndicatorColor),
        ),
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

  void _pauseProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.pause();
      } catch (e) {}
    }
  }

  void _resumeProfileVideo() {
    if (_profileVideoController != null && _isProfileVideoInitialized) {
      try {
        _profileVideoController!.play();
      } catch (e) {}
    }
  }

  // ── Comments realtime ─────────────────────────────────────────────────────
  void _setupCommentsRealtime() {
    _commentsChannel =
        Supabase.instance.client.channel('comments_${widget.postId}');
    _commentsChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'comments',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'postid',
        value: widget.postId,
      ),
      callback: (payload) => _fetchCommentsCount(),
    );

    _repliesChannel =
        Supabase.instance.client.channel('replies_${widget.postId}');
    _repliesChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'replies',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'postid',
        value: widget.postId,
      ),
      callback: (payload) => _fetchCommentsCount(),
    );

    _commentsChannel.subscribe();
    _repliesChannel.subscribe();
  }

  Future<void> _recordView() async {
    if (_viewRecorded) return;
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user != null) {
      await _postsMethods.recordPostView(widget.postId, user.uid);
      if (mounted) setState(() => _viewRecorded = true);
    }
  }

  // ── Ratings realtime (updated to not use _showSlider) ─────────────────────
  void _setupRealtime() {
    _postChannel = Supabase.instance.client.channel('post_${widget.postId}');
    _postChannel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'post_rating',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'postid',
        value: widget.postId,
      ),
      callback: (payload) => _handleRatingUpdate(payload),
    );
    _postChannel.subscribe();
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

  Future<void> _fetchInitialRatings() async {
    setState(() => _isLoadingRatings = true);
    try {
      final countResponse = await Supabase.instance.client
          .from('post_rating')
          .select()
          .eq('postid', widget.postId);

      final avgResponse = await Supabase.instance.client
          .from('post_rating')
          .select('rating')
          .eq('postid', widget.postId);

      final user = Provider.of<UserProvider>(context, listen: false).user;
      dynamic userRatingRes;
      if (user != null) {
        userRatingRes = await Supabase.instance.client
            .from('post_rating')
            .select('rating')
            .eq('postid', widget.postId)
            .eq('userid', user.uid)
            .maybeSingle();
      }

      final allRatings = await Supabase.instance.client
          .from('post_rating')
          .select()
          .eq('postid', widget.postId);

      if (mounted) {
        setState(() {
          _totalRatingsCount = countResponse.length;

          if (avgResponse.isNotEmpty) {
            final ratings = avgResponse
                .map<double>((r) => (r['rating'] as num).toDouble())
                .toList();
            _averageRating = ratings.reduce((a, b) => a + b) / ratings.length;
          } else {
            _averageRating = 0.0;
          }

          if (userRatingRes != null) {
            _userRating = (userRatingRes['rating'] as num).toDouble();
          } else {
            _userRating = null;
          }

          _localRatings = (allRatings as List<dynamic>)
              .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
              .toList();

          _isLoadingRatings = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingRatings = false);
    }
  }

  // ── Rating submission (no _showSlider, no _handleEditRating) ──────────────
  void _handleRatingSubmitted(double rating) async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;

    final double? oldUserRating = _userRating;
    final bool isUpdatingExistingRating = oldUserRating != null;

    setState(() {
      _userRating = rating;
      final currentTotalRating = _averageRating * _totalRatingsCount;
      if (isUpdatingExistingRating) {
        final newTotal = currentTotalRating - oldUserRating! + rating;
        _averageRating = newTotal / _totalRatingsCount;
      } else {
        final newTotal = currentTotalRating + rating;
        _totalRatingsCount++;
        _averageRating = newTotal / _totalRatingsCount;
      }
      final userRatingIndex =
          _localRatings.indexWhere((r) => r['userid'] == user.uid);
      if (userRatingIndex != -1) {
        _localRatings[userRatingIndex]['rating'] = rating;
        _localRatings[userRatingIndex]['timestamp'] =
            DateTime.now().toIso8601String();
      } else {
        _localRatings.add({
          'userid': user.uid,
          'postid': widget.postId,
          'rating': rating,
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    });

    try {
      final success =
          await _postsMethods.ratePost(widget.postId, user.uid, rating);
      if (success != 'success' && mounted) _fetchInitialRatings();
    } catch (e) {
      if (mounted) _fetchInitialRatings();
    }
  }

  // ── Main video player (unchanged, only fixed null-safe check) ─────────────
  void _initializeVideoPlayer() async {
    if (_isVideoLoading || _isVideoInitialized) return;
    setState(() => _isVideoLoading = true);
    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(widget.imageUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      _videoController!.addListener(_videoListener);
      await _videoController!.initialize();
      _videoController!.setLooping(true);
      if (mounted) {
        setState(() {
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        _playVideo();
      }
    } catch (e) {
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  void _videoListener() {
    if (!mounted) return;
    final wasPlaying = _isVideoPlaying;
    final isNowPlaying = _videoController?.value.isPlaying ?? false;
    if (wasPlaying != isNowPlaying) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
      });
    }
    // Check safely without using ! on nullable value
    final controller = _videoController;
    if (controller != null &&
        controller.value.position == controller.value.duration &&
        controller.value.duration != Duration.zero) {
      controller.seekTo(Duration.zero);
      if (!_isVideoPlaying) _playVideo();
    }
  }

  void _toggleVideoPlayback() {
    if (_isVideoPlaying) {
      _pauseVideo();
    } else {
      _playVideo();
    }
  }

  void _playVideo() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      _videoManager.playVideo(_videoController!, widget.postId);
    }
  }

  void _pauseVideo() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      _videoManager.pauseVideo(_videoController!);
    }
  }

  void _toggleMute() {
    if (_videoController != null && _isVideoInitialized) {
      setState(() {
        _isMuted = !_isMuted;
        _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      });
    }
  }

  void _disposeVideoController() {
    if (_videoController != null) {
      _videoController!.removeListener(_videoListener);
      _videoManager.disposeController(_videoController!, widget.postId);
      _videoController = null;
    }
    _isVideoInitialized = false;
  }

  void _disposeProfileVideoController() {
    if (_profileVideoController != null) {
      _profileVideoController!.dispose();
      _profileVideoController = null;
    }
    _isProfileVideoInitialized = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeVideoController();
    _disposeProfileVideoController();
    _bannerAd?.dispose();
    _postChannel.unsubscribe();
    _commentsChannel.unsubscribe();
    _repliesChannel.unsubscribe();
    super.dispose();
  }

  void _loadBannerAd() {
    BannerAd(
      adUnitId: AdHelper.imagescreenAdUnitId,
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          setState(() {
            _bannerAd = ad as BannerAd;
            _isAdLoaded = true;
          });
        },
        onAdFailedToLoad: (ad, err) => ad.dispose(),
      ),
    ).load();
  }

  _ImageViewColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _ImageViewDarkColors() : _ImageViewLightColors();
  }

  DateTime? _parseDate(dynamic date) {
    if (date == null) return null;
    if (date is DateTime) return date;
    if (date is String) return DateTime.tryParse(date);
    return null;
  }

  int _countItems(dynamic value) {
    try {
      if (value == null) return 0;
      if (value is List) return value.length;
      if (value is Iterable) return value.length;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _fetchCommentsCount() async {
    try {
      final commentsResponse = await Supabase.instance.client
          .from('comments')
          .select('id')
          .eq('postid', widget.postId);
      final repliesResponse = await Supabase.instance.client
          .from('replies')
          .select('id')
          .eq('postid', widget.postId);
      final int total =
          _countItems(commentsResponse) + _countItems(repliesResponse);
      if (mounted) setState(() => _commentCount = total);
    } catch (err) {
      if (mounted) setState(() => _commentCount = 0);
    }
  }

  Future<void> _checkBlockStatus() async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;
    final isBlocked =
        await SupabaseBlockMethods().isMutuallyBlocked(user.uid, widget.userId);
    if (mounted) setState(() => _isBlocked = isBlocked);
  }

  void deletePost(String postId) async {
    Navigator.of(context).pop();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        final colors =
            _getColors(Provider.of<ThemeProvider>(context, listen: false));
        return WillPopScope(
          onWillPop: () async => false,
          child: Dialog(
            backgroundColor: colors.dialogBackgroundColor,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                      color: colors.progressIndicatorColor),
                  const SizedBox(height: 16),
                  Text('Deleting post...',
                      style: TextStyle(
                          color: colors.dialogTextColor, fontSize: 16)),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      await _postsMethods.deletePost(postId);
      if (mounted) {
        Navigator.of(context).pop();
        widget.onPostDeleted?.call();
        Navigator.of(context).pop();
      }
    } catch (err) {
      if (mounted) {
        Navigator.of(context).pop();
        showSnackBar(context, 'Failed to delete post: $err');
      }
    }
  }

  void _showReportDialog(_ImageViewColorSet colors) {
    String? selectedReason;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: colors.dialogBackgroundColor,
              title: Text('Report Post',
                  style: TextStyle(color: colors.dialogTextColor)),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Thank you for helping keep our community safe.\n\nPlease let us know the reason for reporting this content. Your report is anonymous, and our moderators will review it as soon as possible.\n\nIf you prefer not to see this user\'s posts, you can choose to block them.',
                      style: TextStyle(
                          color: colors.dialogTextColor, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    Text('Select a reason:\n',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colors.dialogTextColor)),
                    ...reportReasons.map((reason) {
                      return RadioListTile<String>(
                        title: Text(reason,
                            style: TextStyle(color: colors.dialogTextColor)),
                        value: reason,
                        groupValue: selectedReason,
                        activeColor: colors.radioActiveColor,
                        onChanged: (value) =>
                            setState(() => selectedReason = value),
                      );
                    }).toList(),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Cancel',
                      style: TextStyle(color: colors.dialogTextColor)),
                ),
                TextButton(
                  onPressed: selectedReason != null
                      ? () {
                          _postsMethods
                              .reportPost(widget.postId, selectedReason!)
                              .then((res) {
                            Navigator.pop(context);
                            if (res == 'success') {
                              showSnackBar(
                                  context, 'Report submitted. Thank you!');
                            } else {
                              showSnackBar(context,
                                  'Something went wrong, please try again later or contact us at ratedly9@gmail.com');
                            }
                          });
                        }
                      : null,
                  child: Text('Submit',
                      style: TextStyle(color: colors.dialogTextColor)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCommentButton(_ImageViewColorSet colors) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        IconButton(
          icon: Icon(Icons.comment_outlined, color: colors.iconColor, size: 28),
          onPressed: () => _navigateToComments(colors),
        ),
        if (_commentCount > 0)
          Positioned(
            top: -6,
            left: -6,
            child: Container(
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              decoration: BoxDecoration(
                color: colors.badgeBackgroundColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _commentCount.toString(),
                  style: TextStyle(
                      color: colors.badgeTextColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMediaContent(_ImageViewColorSet colors) {
    if (_isVideo) {
      return _buildVideoPlayer(colors);
    } else {
      return _buildImage(colors);
    }
  }

  // ── Video player with filter/rotation/text overlays (unchanged) ──────────
  Widget _buildVideoPlayer(_ImageViewColorSet colors) {
    final VideoEditResult? er = _editResult;

    final List<double> matrix = er != null
        ? er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix)
        : [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

    final int quarters = er?.rotationQuarters ?? 0;

    return AspectRatio(
      aspectRatio:
          _isVideoInitialized ? _videoController!.value.aspectRatio : 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 600),
        child: GestureDetector(
          onTap: _toggleVideoPlayback,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black),
              if (_isVideoInitialized)
                ColorFiltered(
                  colorFilter: ColorFilter.matrix(matrix),
                  child: Transform.rotate(
                    angle: quarters * math.pi / 2,
                    child: VideoPlayer(_videoController!),
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
                      child: Icon(Icons.videocam,
                          color: Colors.grey[300]!, size: 24),
                    ),
                  ),
                )
              else
                Container(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.videocam,
                            size: 50, color: colors.errorIconColor),
                        const SizedBox(height: 8),
                        Text('Video not available',
                            style: TextStyle(color: colors.errorIconColor)),
                      ],
                    ),
                  ),
                ),
              if (er != null && er.strokes.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: DrawingPainter(
                        strokes: er.strokes,
                        currentStroke: null,
                      ),
                    ),
                  ),
                ),
              if (er != null && er.overlays.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final double w = constraints.maxWidth;
                        final double h = constraints.maxHeight;
                        return Stack(
                          children: er.overlays.map((o) {
                            return Positioned(
                              left: (o.position.dx * w).clamp(0.0, w - 10),
                              top: (o.position.dy * h).clamp(0.0, h - 10),
                              child: Stack(clipBehavior: Clip.none, children: [
                                Text(o.text, style: overlayShadowStyle(o)),
                                Text(o.text, style: overlayTextStyle(o)),
                              ]),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ),
                ),
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
                      child: Icon(_isMuted ? Icons.volume_off : Icons.volume_up,
                          size: 20, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(_ImageViewColorSet colors) {
    return AspectRatio(
      aspectRatio: 1,
      child: InteractiveViewer(
        panEnabled: true,
        scaleEnabled: true,
        minScale: 1.0,
        maxScale: 4.0,
        child: Image.network(
          widget.imageUrl,
          fit: BoxFit.cover,
          width: double.infinity,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: double.infinity,
              height: 250,
              child: Center(
                  child: Container(
                      color: colors.backgroundColor.withOpacity(0.1))),
            );
          },
          errorBuilder: (context, error, stackTrace) => SizedBox(
            width: double.infinity,
            height: 250,
            child: Center(
                child: Icon(Icons.broken_image,
                    color: colors.errorIconColor, size: 48)),
          ),
        ),
      ),
    );
  }

  void _navigateToComments(_ImageViewColorSet colors) {
    _pauseVideo();
    _pauseProfileVideo();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CommentsBottomSheet(
        postId: widget.postId,
        postImage: widget.imageUrl,
        isVideo: _isVideo,
        onClose: () => _resumeProfileVideo(),
        videoController: _videoController,
      ),
    ).then((_) => _fetchCommentsCount());
  }

  // ── UPDATED: Show only voter count (no average rating) ────────────────────
  Widget _buildRatingSummary(_ImageViewColorSet colors) {
    final containerContent = Container(
      decoration: BoxDecoration(
        color: colors.buttonBackgroundColor,
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: _isLoadingRatings
          ? Container(
              width: 80,
              height: 20,
              color: colors.backgroundColor.withOpacity(0.3),
            )
          : _totalRatingsCount == 0
              ? Text(
                  'Be the first to react',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.textColor,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : Text(
                  '$_totalRatingsCount ${_totalRatingsCount == 1 ? 'voter' : 'voters'}',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.textColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
    );

    if (_isCurrentUserOwner) {
      return InkWell(
        onTap: () {
          _pauseVideo();
          _pauseProfileVideo();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => RatingListScreen(postId: widget.postId),
            ),
          );
        },
        child: containerContent,
      );
    } else {
      return containerContent;
    }
  }

  Widget _buildProfilePicture(_ImageViewColorSet colors) {
    final isDefault = widget.profImage.isEmpty || widget.profImage == 'default';
    final isVideo = !isDefault && _isProfileVideo;

    if (isDefault) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: colors.avatarBackgroundColor,
        child:
            Icon(Icons.account_circle, size: 42, color: colors.errorIconColor),
      );
    }

    if (isVideo) return _buildProfileVideoPlayer(colors);

    return CircleAvatar(
      radius: 21,
      backgroundColor: colors.avatarBackgroundColor,
      backgroundImage: NetworkImage(widget.profImage),
      child: (widget.profImage.isEmpty || widget.profImage == 'default')
          ? Icon(Icons.account_circle, size: 42, color: colors.errorIconColor)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final user = Provider.of<UserProvider>(context).user;

    final datePublished = _parseDate(widget.datePublished);
    final timeagoText =
        datePublished != null ? timeago.format(datePublished) : '';

    if (user == null) {
      return Scaffold(
        body: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }

    if (_isBlocked) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: colors.appBarBackgroundColor,
          iconTheme: IconThemeData(color: colors.appBarIconColor),
        ),
        body: const BlockedContentMessage(
            message: 'Post unavailable due to blocking'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.appBarIconColor),
        backgroundColor: colors.appBarBackgroundColor,
        title: VerifiedUsernameWidget(
          username: widget.username,
          uid: widget.userId,
          style:
              TextStyle(fontWeight: FontWeight.bold, color: colors.textColor),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.appBarIconColor),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.more_vert, color: colors.appBarIconColor),
            onPressed: () {
              if (_isCurrentUserOwner) {
                showDialog(
                  context: context,
                  builder: (context) => Dialog(
                    backgroundColor: colors.dialogBackgroundColor,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shrinkWrap: true,
                      children: [
                        if (_isDeleting)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                vertical: 16, horizontal: 16),
                            child: Row(
                              children: [
                                CircularProgressIndicator(
                                    color: colors.progressIndicatorColor,
                                    strokeWidth: 2),
                                const SizedBox(width: 16),
                                Text('Deleting...',
                                    style: TextStyle(
                                        color: colors.dialogTextColor)),
                              ],
                            ),
                          )
                        else
                          InkWell(
                            onTap: () => deletePost(widget.postId),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12, horizontal: 16),
                              child: Text('Delete',
                                  style:
                                      TextStyle(color: colors.dialogTextColor)),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              } else {
                _showReportDialog(colors);
              }
            },
          ),
        ],
      ),
      backgroundColor: colors.backgroundColor,
      body: SingleChildScrollView(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16)
                  .copyWith(right: 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      _pauseVideo();
                      _pauseProfileVideo();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) =>
                                ProfileScreen(uid: widget.userId)),
                      );
                    },
                    child: _buildAvatarWithFollow(
                      avatar: _buildProfilePicture(colors),
                      avatarDiameter: 42.0,
                      ownerUid: widget.userId,
                      currentUserId: user.uid,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: () {
                              _pauseVideo();
                              _pauseProfileVideo();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        ProfileScreen(uid: widget.userId)),
                              );
                            },
                            child: VerifiedUsernameWidget(
                              username: widget.username,
                              uid: widget.userId,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: colors.textColor),
                            ),
                          ),
                          if (timeagoText.isNotEmpty)
                            Text(
                              timeagoText,
                              style: TextStyle(
                                  color: colors.textColor.withOpacity(0.6),
                                  fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildMediaContent(colors),
            if (widget.description.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.description,
                    style: TextStyle(
                        color: colors.textColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── RatingBar with the post's reaction emoji ──────────────
                  RatingBar(
                    averageRating: _averageRating,
                    reactionEmoji: _reactionEmoji,
                    initialThumbPosition:
                        _userRating == null ? 5.0 : _averageRating,
                    onRatingEnd: _handleRatingSubmitted,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        _buildCommentButton(colors),
                        IconButton(
                          icon: Icon(Icons.send, color: colors.iconColor),
                          onPressed: () {
                            _pauseVideo();
                            _pauseProfileVideo();
                            showDialog(
                              context: context,
                              builder: (context) => PostShare(
                                currentUserId: user.uid,
                                postId: widget.postId,
                              ),
                            );
                          },
                        ),
                        const Spacer(),
                        _buildRatingSummary(colors),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
