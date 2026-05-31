import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/screens/Profile_page/image_screen.dart';
import 'package:Ratedly/utils/global_variable.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/services/notification_service.dart';

import 'package:Ratedly/screens/first_time/number_particle.dart';
import 'package:Ratedly/screens/first_time/falling_number_painter.dart';
import 'dart:math';

class VideoUtils {
  static bool isVideoFile(String url) {
    if (url.isEmpty) return false;
    final lowerUrl = url.toLowerCase();
    return url.isNotEmpty &&
        url != 'default' &&
        (lowerUrl.endsWith('.mp4') ||
            lowerUrl.endsWith('.mov') ||
            lowerUrl.endsWith('.avi') ||
            lowerUrl.endsWith('.mkv') ||
            lowerUrl.contains('video'));
  }
}

class VideoProfileAvatar extends StatefulWidget {
  final String videoUrl;
  final double radius;
  final Color backgroundColor;
  final Color iconColor;
  final bool forcedTransparent;

  const VideoProfileAvatar({
    Key? key,
    required this.videoUrl,
    required this.radius,
    required this.backgroundColor,
    required this.iconColor,
    this.forcedTransparent = false,
  }) : super(key: key);

  @override
  State<VideoProfileAvatar> createState() => _VideoProfileAvatarState();
}

class _VideoProfileAvatarState extends State<VideoProfileAvatar> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoMuted = true;

  @override
  void initState() {
    super.initState();
    if (VideoUtils.isVideoFile(widget.videoUrl)) _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await _videoController!.initialize();
      await _videoController!.setVolume(0.0);
      await _videoController!.setLooping(true);
      await _videoController!.play();
      if (mounted)
        setState(() {
          _isVideoInitialized = true;
          _isVideoMuted = true;
        });
    } catch (e) {
      if (mounted) setState(() => _isVideoInitialized = false);
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVideoInitialized || _videoController == null) {
      return Container(
        width: widget.radius * 2,
        height: widget.radius * 2,
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: widget.backgroundColor),
        child: Center(
            child: CircularProgressIndicator(
                color: widget.iconColor, strokeWidth: 2.0)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _videoController!.value.size.width,
            height: _videoController!.value.size.height,
            child: VideoPlayer(_videoController!),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// TikTok-style follow badge (FIXED to avoid duplicate notifications)
// =============================================================================
class _FollowBadge extends StatefulWidget {
  final String ownerUid;
  final String currentUserId;

  /// The type of the parent notification (e.g. 'post_rating', 'comment').
  /// Used to decide which contextual push body to send after a follow.
  /// Any other type (or null) sends the normal "started following you" push.
  final String? notificationType;

  const _FollowBadge({
    Key? key,
    required this.ownerUid,
    required this.currentUserId,
    this.notificationType,
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

  final _supabase = Supabase.instance.client;

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
      final following = await _supabase
          .from('user_following')
          .select()
          .eq('user_id', widget.currentUserId)
          .eq('following_id', widget.ownerUid)
          .maybeSingle();
      final pending = await _supabase
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

  // ── Contextual push after follow from a post_rating notification ──────────
  Future<void> _sendRatingFollowNotification() async {
    try {
      // Fetch follower's username + test flag in one query
      final followerRow = await _supabase
          .from('users')
          .select('username, test')
          .eq('uid', widget.currentUserId)
          .maybeSingle();

      final followerUsername =
          followerRow?['username']?.toString() ?? 'Someone';
      final bool isTestGroup = followerRow?['test'] ?? false;

      // CHANGED: type is now 'follow_from_rating' instead of 'follow'
      await _supabase.from('notifications').insert({
        'target_user_id': widget.ownerUid,
        'type': 'follow_from_rating',
        'custom_data': {
          'followerId': widget.currentUserId,
          'context': 'post_rating',
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      // A/B test body — only fires when follow badge tapped on a rating notification
      final body = isTestGroup
          ? '@$followerUsername followed you after your reaction.'
          : '@$followerUsername followed you after you reacted to their post.';

      NotificationService().triggerServerNotification(
        type: 'follow',
        targetUserId: widget.ownerUid,
        title: 'New Follower',
        body: body,
        customData: {
          'followerId': widget.currentUserId,
          'context': 'post_rating',
        },
      );
    } catch (_) {}
  }

  // ── Contextual push after follow from a comment notification ─────────────
  Future<void> _sendCommentFollowNotification() async {
    try {
      // Fetch follower's username + test flag in one query
      final followerRow = await _supabase
          .from('users')
          .select('username, test')
          .eq('uid', widget.currentUserId)
          .maybeSingle();

      final followerUsername =
          followerRow?['username']?.toString() ?? 'Someone';
      final bool isTestGroup = followerRow?['test'] ?? false;

      // CHANGED: type is now 'follow_from_comment' instead of 'follow'
      await _supabase.from('notifications').insert({
        'target_user_id': widget.ownerUid,
        'type': 'follow_from_comment',
        'custom_data': {
          'followerId': widget.currentUserId,
          'context': 'comment',
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      // A/B test body — only fires when follow badge tapped on a comment notification
      final body = isTestGroup
          ? '@$followerUsername followed you after your comment.'
          : '@$followerUsername followed you after you commented on their post.';

      NotificationService().triggerServerNotification(
        type: 'follow',
        targetUserId: widget.ownerUid,
        title: 'New Follower',
        body: body,
        customData: {
          'followerId': widget.currentUserId,
          'context': 'comment',
        },
      );
    } catch (_) {}
  }

  // ========================================================================
  // FIXED: _handleTap – no longer calls any generic method; relies on
  // followUser's sendNotification flag to decide whether to create the
  // generic notification. For contextual follows (comment/rating) we
  // suppress followUser's generic and then send the contextual one.
  // ========================================================================
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
        // Optimistic UI
        setState(() => _isFollowing = true);
        _tickController.forward(from: 0.0).then((_) {
          if (mounted) {
            _scaleController.reverse().then((_) {
              if (mounted) setState(() => _showBadge = false);
            });
          }
        });

        // Determine if we need a contextual notification
        final bool hasContextualNotification =
            widget.notificationType == 'post_rating' ||
                widget.notificationType == 'comment';

        // Call followUser – suppress generic notification when contextual will be sent
        await SupabaseProfileMethods().followUser(
          widget.currentUserId,
          widget.ownerUid,
          sendNotification: !hasContextualNotification,
        );

        // After follow, check if it turned into a pending request (private account)
        final pending = await _supabase
            .from('user_follow_request')
            .select()
            .eq('user_id', widget.ownerUid)
            .eq('requester_id', widget.currentUserId)
            .maybeSingle();

        if (mounted && pending != null) {
          // Private account → became a follow request, no notification at all
          setState(() {
            _isFollowing = false;
            _hasPendingRequest = true;
            _showBadge = true;
          });
          _scaleController.forward(from: 0.0);
        } else {
          // Public account follow succeeded – send contextual notification if needed
          if (widget.notificationType == 'post_rating') {
            await _sendRatingFollowNotification();
          } else if (widget.notificationType == 'comment') {
            await _sendCommentFollowNotification();
          }
          // Generic case: followUser already sent the notification because
          // sendNotification was true (hasContextualNotification == false)
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isFollowing = false;
          _showBadge = true;
        });
        _tickController.reset();
        _scaleController.forward(from: 0.0);
      }
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

// Stacks avatar + follow badge (unchanged)
Widget _buildAvatarWithFollow({
  required Widget avatar,
  required double avatarDiameter,
  required String ownerUid,
  required String currentUserId,
  String? notificationType,
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
          child: _FollowBadge(
            ownerUid: ownerUid,
            currentUserId: currentUserId,
            notificationType: notificationType,
          ),
        ),
      ],
    ),
  );
}

class _NotificationColorSet {
  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color progressIndicatorColor;
  final Color cardColor;
  final Color subtitleTextColor;
  final Color dividerColor;

  _NotificationColorSet({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.progressIndicatorColor,
    required this.cardColor,
    required this.subtitleTextColor,
    required this.dividerColor,
  });
}

class _NotificationDarkColors extends _NotificationColorSet {
  _NotificationDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          textColor: const Color(0xFFd9d9d9),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          cardColor: const Color(0xFF333333),
          subtitleTextColor: const Color(0xFF999999),
          dividerColor: const Color(0xFF333333),
        );
}

class _NotificationLightColors extends _NotificationColorSet {
  _NotificationLightColors()
      : super(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
          progressIndicatorColor: Colors.black,
          cardColor: Colors.grey[100]!,
          subtitleTextColor: Colors.grey[700]!,
          dividerColor: Colors.grey[300]!,
        );
}

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({Key? key}) : super(key: key);

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  final List<NumberParticle> _particles = [];
  final Random _random = Random();
  double _screenHeight = 0;

  _NotificationColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _NotificationDarkColors() : _NotificationLightColors();
  }

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  void _initializeParticles(_NotificationColorSet colors) {
    _particles.clear();
    _particles.addAll(List.generate(
        15,
        (_) => NumberParticle(
              x: _random.nextDouble(),
              y: -_random.nextDouble() * 0.5,
              speed: 0.3 + _random.nextDouble() * 0.4,
              rotation: _random.nextDouble() * 2 * pi,
              rotationSpeed: _random.nextDouble() * 0.003,
              opacity: 0.3 + _random.nextDouble() * 0.3,
              number: _random.nextInt(10) + 1,
              fontSize: 12 + _random.nextDouble() * 10,
              sway: 0.0,
              swaySpeed: _random.nextDouble() * 0.003,
              color: colors.textColor.withOpacity(0.3),
            )));
  }

  void _updateParticles() {
    if (_screenHeight == 0) return;
    for (final particle in _particles) {
      particle.y += particle.speed * 0.012;
      particle.rotation += particle.rotationSpeed;
      particle.sway += particle.swaySpeed;
      if (particle.y * _screenHeight > _screenHeight * 1.2) {
        particle.y = -_random.nextDouble() * 0.5;
        particle.x = _random.nextDouble();
        particle.opacity = 0.3 + _random.nextDouble() * 0.3;
        particle.fontSize = 12 + _random.nextDouble() * 10;
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final userProvider = Provider.of<UserProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (userProvider.user == null) {
      return Scaffold(
        body: Stack(
          children: [
            _FallingNumbersBackground(
              animationController: _animationController,
              onInit: (screenHeight) {
                _screenHeight = screenHeight;
                _initializeParticles(colors);
              },
              onUpdate: _updateParticles,
              particles: _particles,
            ),
            Center(
                child: CircularProgressIndicator(
                    color: colors.progressIndicatorColor)),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: width > webScreenSize
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              toolbarHeight: 100,
              automaticallyImplyLeading: false,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              title: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Reactly',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: colors.appBarIconColor),
                ),
              ),
              iconTheme: IconThemeData(color: colors.appBarIconColor),
            ),
      body: Stack(
        children: [
          _FallingNumbersBackground(
            animationController: _animationController,
            onInit: (screenHeight) {
              _screenHeight = screenHeight;
              _initializeParticles(colors);
            },
            onUpdate: _updateParticles,
            particles: _particles,
          ),
          _FastNotificationList(
            currentUserId: userProvider.user!.uid,
            colors: colors,
          ),
        ],
      ),
    );
  }
}

class _FastNotificationList extends StatefulWidget {
  final String currentUserId;
  final _NotificationColorSet colors;

  const _FastNotificationList({
    required this.currentUserId,
    required this.colors,
  });

  @override
  State<_FastNotificationList> createState() => _FastNotificationListState();
}

class _FastNotificationListState extends State<_FastNotificationList> {
  final List<Map<String, dynamic>> _notifications = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();
  final int _limit = 20;
  int _page = 0;

  final Map<String, Map<String, dynamic>> _userCache = {};
  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadNotifications();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 300 &&
        !_isLoadingMore &&
        _hasMore) {
      _loadMoreNotifications();
    }
  }

  Future<void> _loadNotifications() async {
    try {
      final response = await _supabase
          .from('notifications')
          .select('id, type, created_at, custom_data, is_read')
          .eq('target_user_id', widget.currentUserId)
          .neq('type', 'message')
          .order('created_at', ascending: false)
          .limit(_limit);

      if (response.isNotEmpty) {
        _notifications.addAll(List<Map<String, dynamic>>.from(response));
        await _bulkFetchUsers();
        setState(() {
          _page = 1;
          _hasMore = response.length == _limit;
        });
      } else {
        setState(() => _hasMore = false);
      }
    } catch (e) {
      setState(() => _hasMore = false);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMoreNotifications() async {
    if (!_hasMore || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final offset = _page * _limit;
      final response = await _supabase
          .from('notifications')
          .select('id, type, created_at, custom_data, is_read')
          .eq('target_user_id', widget.currentUserId)
          .neq('type', 'message')
          .order('created_at', ascending: false)
          .range(offset, offset + _limit - 1);

      if (response.isNotEmpty) {
        _notifications.addAll(List<Map<String, dynamic>>.from(response));
        await _bulkFetchUsers();
        setState(() {
          _page++;
          _hasMore = response.length == _limit;
        });
      } else {
        setState(() => _hasMore = false);
      }
    } catch (e) {
      setState(() => _hasMore = false);
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _bulkFetchUsers() async {
    final Set<String> userIds = {};
    for (final notification in _notifications) {
      final userId = _extractUserIdFromNotification(notification);
      if (userId != null &&
          userId.isNotEmpty &&
          !_userCache.containsKey(userId)) {
        userIds.add(userId);
      }
    }
    if (userIds.isEmpty) return;
    try {
      final response = await _supabase
          .from('users')
          .select('uid, username, photoUrl')
          .inFilter('uid', userIds.toList());
      if (response.isNotEmpty) {
        for (final user in response) {
          final userMap = Map<String, dynamic>.from(user);
          _userCache[userMap['uid']] = userMap;
        }
        setState(() {});
      }
    } catch (e) {}
  }

  String? _extractUserIdFromNotification(Map<String, dynamic> notification) {
    final type = notification['type'] as String?;
    final customData = notification['custom_data'] ?? {};
    switch (type) {
      case 'comment':
        return customData['commenterUid'] ?? customData['commenter_uid'];
      case 'post_rating':
        return customData['raterUid'] ?? customData['rater_uid'];
      case 'follow_request':
        return customData['requesterId'] ?? customData['requester_id'];
      case 'follow_request_accepted':
        return customData['approverId'] ?? customData['approver_id'];
      case 'comment_like':
        return customData['likerUid'] ?? customData['liker_uid'];
      case 'follow':
        return customData['followerId'] ?? customData['follower_id'];
      // ADDED: two new contextual follow types
      case 'follow_from_rating':
      case 'follow_from_comment':
        return customData['followerId'] ?? customData['follower_id'];
      case 'reply':
        return customData['replierUid'] ?? customData['replier_uid'];
      case 'reply_like':
        return customData['likerUid'] ?? customData['liker_uid'];
      default:
        return null;
    }
  }

  void refreshNotifications() {
    setState(() {
      _notifications.clear();
      _page = 0;
      _hasMore = true;
      _isLoading = true;
      _userCache.clear();
    });
    _loadNotifications();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildSkeletonLoader() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 16),
      itemCount: 10,
      itemBuilder: (context, index) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
          decoration: BoxDecoration(
              color: widget.colors.cardColor,
              borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.colors.cardColor.withOpacity(0.7)),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    height: 14,
                    width: 180,
                    decoration: BoxDecoration(
                        color: widget.colors.cardColor.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(4))),
                const SizedBox(height: 6),
                Container(
                    height: 12,
                    width: 120,
                    decoration: BoxDecoration(
                        color: widget.colors.cardColor.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(4))),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notifications_none,
              size: 80, color: widget.colors.textColor.withOpacity(0.5)),
          const SizedBox(height: 20),
          Text('No notifications yet',
              style: TextStyle(
                  fontSize: 18,
                  color: widget.colors.textColor.withOpacity(0.7))),
          const SizedBox(height: 10),
          Text('Notifications will appear here',
              style: TextStyle(
                  fontSize: 14, color: widget.colors.subtitleTextColor)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: RefreshIndicator(
        onRefresh: () async => refreshNotifications(),
        child: _isLoading
            ? _buildSkeletonLoader()
            : _notifications.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: _notifications.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _notifications.length) {
                        return _isLoadingMore
                            ? Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 20),
                                child: Center(
                                    child: CircularProgressIndicator(
                                        color: widget
                                            .colors.progressIndicatorColor)),
                              )
                            : const SizedBox.shrink();
                      }
                      final notification = _notifications[index];
                      return _FastNotificationItem(
                        notification: notification,
                        currentUserId: widget.currentUserId,
                        userCache: _userCache,
                        colors: widget.colors,
                        refreshNotifications: refreshNotifications,
                      );
                    },
                  ),
      ),
    );
  }
}

class _FastNotificationItem extends StatelessWidget {
  final Map<String, dynamic> notification;
  final String currentUserId;
  final Map<String, Map<String, dynamic>> userCache;
  final _NotificationColorSet colors;
  final VoidCallback? refreshNotifications;

  const _FastNotificationItem({
    required this.notification,
    required this.currentUserId,
    required this.userCache,
    required this.colors,
    this.refreshNotifications,
  });

  void _navigateToProfile(BuildContext context, String uid) {
    if (uid.isEmpty) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (context) => ProfileScreen(uid: uid)));
  }

  Future<void> _navigateToPost(BuildContext context, String postId) async {
    if (postId.isEmpty) return;
    try {
      final response = await Supabase.instance.client
          .from('posts')
          .select()
          .eq('postId', postId)
          .maybeSingle();
      if (response != null) {
        final postData = response as Map<String, dynamic>;
        Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ImageViewScreen(
                imageUrl: postData['postUrl']?.toString() ?? '',
                postId: postId,
                description: postData['description']?.toString() ?? '',
                userId: postData['uid']?.toString() ?? '',
                username: postData['username']?.toString() ?? '',
                profImage: postData['profImage']?.toString() ?? '',
                datePublished: postData['datePublished']?.toString() ?? '',
              ),
            ));
      }
    } catch (e) {}
  }

  String _extractUserId() {
    final type = notification['type'] as String?;
    final customData = notification['custom_data'] ?? {};
    switch (type) {
      case 'comment':
        return customData['commenterUid'] ?? customData['commenter_uid'] ?? '';
      case 'post_rating':
        return customData['raterUid'] ?? customData['rater_uid'] ?? '';
      case 'follow_request':
        return customData['requesterId'] ?? customData['requester_id'] ?? '';
      case 'follow_request_accepted':
        return customData['approverId'] ?? customData['approver_id'] ?? '';
      case 'comment_like':
        return customData['likerUid'] ?? customData['liker_uid'] ?? '';
      case 'follow':
        return customData['followerId'] ?? customData['follower_id'] ?? '';
      // ADDED: two new contextual follow types
      case 'follow_from_rating':
      case 'follow_from_comment':
        return customData['followerId'] ?? customData['follower_id'] ?? '';
      case 'reply':
        return customData['replierUid'] ?? customData['replier_uid'] ?? '';
      case 'reply_like':
        return customData['likerUid'] ?? customData['liker_uid'] ?? '';
      default:
        return '';
    }
  }

  String? _extractPostId() {
    final type = notification['type'] as String?;
    final customData = notification['custom_data'] ?? {};
    switch (type) {
      case 'comment':
      case 'post_rating':
      case 'comment_like':
      case 'reply':
      case 'reply_like':
        return customData['postId'] ?? customData['post_id'];
      default:
        return null;
    }
  }

  Future<void> _handleFollowRequest(
      BuildContext context, String requesterId, bool accept) async {
    final provider =
        Provider.of<SupabaseProfileMethods>(context, listen: false);
    try {
      if (accept) {
        await provider.acceptFollowRequest(currentUserId, requesterId);
      } else {
        await provider.declineFollowRequest(currentUserId, requesterId);
      }
      refreshNotifications?.call();
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    final type = notification['type'] as String?;
    final customData = notification['custom_data'] ?? {};

    final userId = _extractUserId();
    final user = userCache[userId] ?? {};
    final username = user['username'] ?? 'Someone';

    String title;
    String? subtitle;
    VoidCallback? onTap;
    List<Widget>? actions;

    switch (type) {
      case 'comment':
        title = '$username commented on your post';
        subtitle = customData['commentText'] ?? customData['comment_text'];
        final postId = _extractPostId();
        onTap = postId != null ? () => _navigateToPost(context, postId) : null;
        break;
      // ── CHANGED: removed rating variable and subtitle, updated title text ──
      case 'post_rating':
        title = '$username reacted to your post';
        final postId = _extractPostId();
        onTap = postId != null ? () => _navigateToPost(context, postId) : null;
        break;
      case 'follow_request':
        title = '$username wants to follow you';
        actions = [
          TextButton(
            onPressed: () => _handleFollowRequest(context, userId, true),
            child: Text('Accept', style: TextStyle(color: colors.textColor)),
          ),
          TextButton(
            onPressed: () => _handleFollowRequest(context, userId, false),
            child: Text('Decline', style: TextStyle(color: colors.textColor)),
          ),
        ];
        break;
      case 'follow_request_accepted':
        title = '$username approved your follow request';
        onTap = () => _navigateToProfile(context, userId);
        break;
      case 'comment_like':
        title = '$username liked your comment';
        subtitle = customData['commentText'] ?? customData['comment_text'];
        final postId = _extractPostId();
        onTap = postId != null ? () => _navigateToPost(context, postId) : null;
        break;
      case 'follow':
        // Generic direct follow — unchanged
        title = '$username started following you';
        onTap = () => _navigateToProfile(context, userId);
        break;
      // ADDED: contextual follow messages
      case 'follow_from_rating':
        title = '$username started following you after reacting to your post';
        onTap = () => _navigateToProfile(context, userId);
        break;
      case 'follow_from_comment':
        title = '$username started following you after commenting on your post';
        onTap = () => _navigateToProfile(context, userId);
        break;
      case 'reply':
        title = '$username replied to your comment';
        subtitle = customData['replyText'] ?? customData['reply_text'];
        final postId = _extractPostId();
        onTap = postId != null ? () => _navigateToPost(context, postId) : null;
        break;
      case 'reply_like':
        title = '$username liked your reply';
        subtitle = customData['replyText'] ?? customData['reply_text'];
        final postId = _extractPostId();
        onTap = postId != null ? () => _navigateToPost(context, postId) : null;
        break;
      default:
        title = 'New notification';
        subtitle = 'Unknown notification type: $type';
    }

    return _FastNotificationTemplate(
      userId: userId,
      currentUserId: currentUserId,
      notificationType: type, // forwarded so badge knows the context
      title: title,
      subtitle: subtitle,
      timestamp: notification['created_at'],
      onTap: onTap,
      actions: actions,
      userCache: userCache,
      colors: colors,
    );
  }
}

class _FastNotificationTemplate extends StatelessWidget {
  final String userId;
  final String currentUserId;
  final String? notificationType;
  final String title;
  final String? subtitle;
  final dynamic timestamp;
  final VoidCallback? onTap;
  final List<Widget>? actions;
  final Map<String, Map<String, dynamic>> userCache;
  final _NotificationColorSet colors;

  const _FastNotificationTemplate({
    required this.userId,
    required this.currentUserId,
    this.notificationType,
    required this.title,
    this.subtitle,
    required this.timestamp,
    this.onTap,
    this.actions,
    required this.userCache,
    required this.colors,
  });

  void _navigateToProfile(BuildContext context, String uid) {
    if (uid.isEmpty) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (context) => ProfileScreen(uid: uid)));
  }

  String _formatTimestamp(dynamic timestamp) {
    try {
      if (timestamp is DateTime) return timeago.format(timestamp);
      if (timestamp is String) return timeago.format(DateTime.parse(timestamp));
      return 'Just now';
    } catch (e) {
      return 'Just now';
    }
  }

  Widget _buildUserAvatar(String photoUrl, double radius) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    final isVideo = !isDefault && VideoUtils.isVideoFile(photoUrl);

    if (isDefault) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: colors.cardColor,
        child: Icon(Icons.account_circle,
            size: radius * 2, color: colors.iconColor.withOpacity(0.8)),
      );
    }
    if (isVideo) {
      return VideoProfileAvatar(
        videoUrl: photoUrl,
        radius: radius,
        backgroundColor: colors.cardColor,
        iconColor: colors.iconColor,
        forcedTransparent: false,
      );
    }
    return CircleAvatar(
        radius: radius,
        backgroundColor: colors.cardColor,
        backgroundImage: NetworkImage(photoUrl));
  }

  @override
  Widget build(BuildContext context) {
    final user = userCache[userId] ?? {};
    final profilePic = user['photoUrl']?.toString() ?? '';
    const double avatarDiameter = 42.0;

    final avatar = GestureDetector(
      onTap: () => _navigateToProfile(context, userId),
      child: _buildUserAvatar(profilePic, 21),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
          color: colors.cardColor, borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: _buildAvatarWithFollow(
          avatar: avatar,
          avatarDiameter: avatarDiameter,
          ownerUid: userId,
          currentUserId: currentUserId,
          notificationType: notificationType,
        ),
        title: Text(title,
            style: TextStyle(
                fontWeight: FontWeight.bold, color: colors.textColor)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle != null)
              Text(subtitle!,
                  style: TextStyle(color: colors.subtitleTextColor)),
            Text(_formatTimestamp(timestamp),
                style: TextStyle(color: colors.subtitleTextColor)),
            if (actions != null) ...actions!,
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _FallingNumbersBackground extends StatefulWidget {
  final AnimationController animationController;
  final Function(double) onInit;
  final VoidCallback onUpdate;
  final List<NumberParticle> particles;

  const _FallingNumbersBackground({
    required this.animationController,
    required this.onInit,
    required this.onUpdate,
    required this.particles,
  });

  @override
  __FallingNumbersBackgroundState createState() =>
      __FallingNumbersBackgroundState();
}

class __FallingNumbersBackgroundState extends State<_FallingNumbersBackground> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final screenHeight = MediaQuery.of(context).size.height;
      widget.onInit(screenHeight);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animationController,
      builder: (context, child) {
        widget.onUpdate();
        return CustomPaint(
          painter: FallingNumbersPainter(
              particles: widget.particles, repaint: widget.animationController),
          size: Size.infinite,
        );
      },
    );
  }
}
