import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/services/analytics_service.dart'; // ✅ screen tracking
import 'package:provider/provider.dart';                   // ✅ for Provider.of
import 'package:Ratedly/providers/user_provider.dart';      // ✅ for UserProvider

// ============================================================================
// Video utilities
// ============================================================================
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

// ============================================================================
// Read-only reaction display (track + emoji thumb)
// ============================================================================
class ReadOnlyRatingDisplay extends StatelessWidget {
  final double rating;
  final String reactionEmoji;
  final double width;
  final double trackHeight;
  final double emojiSize;

  const ReadOnlyRatingDisplay({
    Key? key,
    required this.rating,
    required this.reactionEmoji,
    this.width = 80.0,
    this.trackHeight = 3.0,
    this.emojiSize = 20.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    const Color trackColor = Colors.white24;
    const Color activeTrackColor = Colors.white70;
    final double normalized = (rating - 1.0) / 9.0;
    final double thumbHalf = emojiSize / 2;
    final double trackWidth = width - emojiSize;
    final double thumbLeft = thumbHalf + normalized * trackWidth;

    return SizedBox(
      width: width,
      height: emojiSize + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: thumbHalf,
            top: (emojiSize / 2) - (trackHeight / 2),
            right: thumbHalf,
            child: Container(
              height: trackHeight,
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(trackHeight / 2),
              ),
            ),
          ),
          Positioned(
            left: thumbHalf,
            top: (emojiSize / 2) - (trackHeight / 2),
            width: thumbLeft - thumbHalf,
            child: Container(
              height: trackHeight,
              decoration: BoxDecoration(
                color: activeTrackColor,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(trackHeight / 2),
                ),
              ),
            ),
          ),
          Positioned(
            left: thumbLeft - (emojiSize / 2),
            top: 0,
            child: SizedBox(
              width: emojiSize,
              height: emojiSize,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  reactionEmoji,
                  style: const TextStyle(fontSize: 100),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// RatingListScreen (PRIVATE CONSTRUCTOR – must be opened via .show())
// ============================================================================
class RatingListScreen extends StatefulWidget {
  final String postId;
  final bool isVideo;
  final VideoPlayerController? videoController;
  final VoidCallback? onClose;

  // 🔒 PRIVATE CONSTRUCTOR – prevents direct instantiation
  const RatingListScreen._({
    super.key,
    required this.postId,
    this.isVideo = false,
    this.videoController,
    this.onClose,
  });

  // ✅ ONLY correct way to open this screen: as a transparent modal bottom sheet
  static Future<T?> show<T>(
    BuildContext context, {
    required String postId,
    bool isVideo = false,
    VideoPlayerController? videoController,
    VoidCallback? onClose,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RatingListScreen._(
        postId: postId,
        isVideo: isVideo,
        videoController: videoController,
        onClose: onClose,
      ),
    );
  }

  @override
  State<RatingListScreen> createState() => _RatingListScreenState();
}

class _RatingListScreenState extends State<RatingListScreen> {
  late final RealtimeChannel _ratingsChannel;
  List<Map<String, dynamic>> _ratings = [];
  int _page = 0;
  final int _limit = 20;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();
  final Map<String, Map<String, dynamic>> _userCache = {};

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  String _reactionEmoji = '❤️';
  bool _emojiLoaded = false;
  bool _shouldResumeVideo = false;

  // ✅ screen tracking: store current user ID for exit
  String? _currentUserId;

  static const Color _textColor = Colors.white;

  @override
  void initState() {
    super.initState();

    // ✅ screen tracking: retrieve user ID and enter screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      final user = userProvider.user;
      if (user != null) {
        _currentUserId = user.uid;
        AnalyticsService.screenEnter('reactions');
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = ModalRoute.of(context);
      if (route is! ModalBottomSheetRoute) {
        if (kDebugMode) {
          ScaffoldMessenger.of(context).showMaterialBanner(
            MaterialBanner(
              content: const Text(
                  '⚠️ RatingListScreen opened incorrectly – use RatingListScreen.show()'),
              backgroundColor: Colors.red,
              actions: [
                TextButton(
                  onPressed: () =>
                      ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
                  child: const Text('DISMISS',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        }
      }
    });

    if (widget.isVideo && widget.videoController != null) {
      _shouldResumeVideo = widget.videoController!.value.isPlaying;
      if (_shouldResumeVideo) widget.videoController!.pause();
    }

    _setupRealtime();
    _fetchReactionEmoji();
    _fetchInitialRatings();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 100) {
        _loadMoreRatings();
      }
    });
  }

  @override
  void dispose() {
    // ✅ screen tracking: exit reactions screen
    if (_currentUserId != null && _currentUserId!.isNotEmpty) {
      AnalyticsService.screenExit(
        screenName: 'reactions',
        uid: _currentUserId!,
      );
    }

    _ratingsChannel.unsubscribe();
    _scrollController.dispose();
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();

    if (widget.isVideo &&
        widget.videoController != null &&
        _shouldResumeVideo) {
      widget.videoController!.play();
    }

    widget.onClose?.call();
    super.dispose();
  }

  void _setupRealtime() {
    _ratingsChannel =
        Supabase.instance.client.channel('post_ratings_${widget.postId}');
    _ratingsChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'post_rating',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'postid',
            value: widget.postId,
          ),
          callback: _handleRealtimeUpdate,
        )
        .subscribe();
  }

  Future<void> _fetchReactionEmoji() async {
    try {
      final response = await Supabase.instance.client
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', widget.postId)
          .maybeSingle();
      if (mounted && response != null) {
        final emoji = response['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() {
            _reactionEmoji = emoji;
            _emojiLoaded = true;
          });
          return;
        }
      }
    } catch (e) {
      // ignore
    }
    if (mounted) setState(() => _emojiLoaded = true);
  }

  Future<void> _initializeVideoController(
      String userId, String videoUrl) async {
    if (_videoControllers.containsKey(userId) ||
        _videoControllersInitialized[userId] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _videoControllers[userId] = controller;
      _videoControllersInitialized[userId] = false;
      await controller.initialize();
      await controller.setVolume(0.0);
      await controller.setLooping(true);
      await controller.play();
      _videoControllersInitialized[userId] = true;
      if (mounted) setState(() {});
    } catch (e) {
      _videoControllers.remove(userId)?.dispose();
      _videoControllersInitialized.remove(userId);
    }
  }

  Future<void> _fetchInitialRatings() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final response = await Supabase.instance.client
          .from('post_rating')
          .select('*, users!userid (username, photoUrl)')
          .eq('postid', widget.postId)
          .order('timestamp', ascending: false)
          .range(0, _limit - 1);

      if (mounted) {
        final rows = (response as List)
            .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
            .toList();

        setState(() {
          _ratings = rows;
          _isLoading = false;
          _page = 1;
          _hasMore = _ratings.length == _limit;
          _cacheUsers(_ratings);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMoreRatings() async {
    if (!_hasMore || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final start = _page * _limit;
      final response = await Supabase.instance.client
          .from('post_rating')
          .select('*, users!userid(username, photoUrl)')
          .eq('postid', widget.postId)
          .order('timestamp', ascending: false)
          .range(start, start + _limit - 1);

      if (mounted) {
        setState(() {
          final newRatings = (response as List)
              .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
              .toList();
          _ratings.addAll(newRatings);
          _isLoadingMore = false;
          _page++;
          _hasMore = newRatings.length == _limit;
          _cacheUsers(newRatings);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _cacheUsers(List<Map<String, dynamic>> rows) {
    for (final rating in rows) {
      final userId = rating['userid'] as String?;
      if (userId == null) continue;
      final userData = rating['users'] as Map<String, dynamic>?;
      if (userData == null) continue;
      _userCache[userId] = userData;
      final photoUrl = userData['photoUrl'] ?? '';
      if (VideoUtils.isVideoFile(photoUrl)) {
        _initializeVideoController(userId, photoUrl);
      }
    }
  }

  void _handleRealtimeUpdate(PostgresChangePayload payload) {
    final newRecord = payload.newRecord;
    final oldRecord = payload.oldRecord;
    setState(() {
      switch (payload.eventType) {
        case PostgresChangeEvent.insert:
          if (newRecord != null) {
            _ratings.insert(0, newRecord);
            _cacheUsers([newRecord]);
          }
          break;
        case PostgresChangeEvent.update:
          if (oldRecord != null && newRecord != null) {
            final idx =
                _ratings.indexWhere((r) => r['userid'] == oldRecord['userid']);
            if (idx != -1) _ratings[idx] = newRecord;
            _cacheUsers([newRecord]);
          }
          break;
        case PostgresChangeEvent.delete:
          if (oldRecord != null) {
            _ratings.removeWhere((r) => r['userid'] == oldRecord['userid']);
            final uid = oldRecord['userid'] as String?;
            if (uid != null) {
              _videoControllers[uid]?.dispose();
              _videoControllers.remove(uid);
              _videoControllersInitialized.remove(uid);
            }
          }
          break;
        default:
          break;
      }
    });
  }

  Widget _buildUserAvatar(String userId, String photoUrl) {
    final hasValid =
        photoUrl.isNotEmpty && photoUrl != 'default' && photoUrl != 'null';
    if (!hasValid) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: Colors.black.withOpacity(0.4),
        child: Icon(Icons.account_circle,
            size: 42, color: _textColor.withOpacity(0.8)),
      );
    }
    if (VideoUtils.isVideoFile(photoUrl)) {
      final ctrl = _videoControllers[userId];
      final ready = _videoControllersInitialized[userId] == true;
      if (!ready || ctrl == null) {
        return Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              shape: BoxShape.circle, color: Colors.black.withOpacity(0.4)),
          child: Center(
              child: CircularProgressIndicator(
                  color: _textColor.withOpacity(0.6), strokeWidth: 2.0)),
        );
      }
      return ClipOval(
        child: SizedBox(
          width: 42,
          height: 42,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: ctrl.value.size.width,
              height: ctrl.value.size.height,
              child: VideoPlayer(ctrl),
            ),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: 21,
      backgroundColor: Colors.black.withOpacity(0.4),
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  Widget _buildRatingItem(Map<String, dynamic> rating) {
    final userId = rating['userid'] as String? ?? '';
    final userRating = (rating['rating'] as num?)?.toDouble() ?? 0.0;
    final timestampStr = rating['timestamp'] as String?;
    final timestamp = timestampStr != null
        ? DateTime.tryParse(timestampStr) ?? DateTime.now()
        : DateTime.now();
    final timeText = timeago.format(timestamp);

    final userData = _userCache[userId] ?? {};
    final photoUrl = userData['photoUrl'] as String? ?? '';
    final username = userData['username'] as String? ?? 'Deleted user';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: GestureDetector(
        onTap: username == 'Deleted user'
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ProfileScreen(uid: userId)),
                ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: Colors.white.withOpacity(0.05), width: 0.3),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: username == 'Deleted user'
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ProfileScreen(uid: userId)),
                        ),
                child: _buildUserAvatar(userId, photoUrl),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    VerifiedUsernameWidget(
                      username: username,
                      uid: userId,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _textColor,
                        shadows: [
                          Shadow(
                            color: Colors.black87,
                            blurRadius: 4,
                            offset: Offset(1, 1),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      timeText,
                      style: TextStyle(
                        color: _textColor.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_emojiLoaded)
                ReadOnlyRatingDisplay(
                  rating: userRating,
                  reactionEmoji: _reactionEmoji,
                  width: 80,
                  emojiSize: 24,
                  trackHeight: 3,
                )
              else
                SizedBox(
                  width: 80,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: _textColor.withOpacity(0.6),
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRatingsContent() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.transparent,
            Colors.transparent,
          ],
          stops: [0.0, 0.3, 0.7, 1.0],
        ),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // Header
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.7),
                  Colors.black.withOpacity(0.3),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Reactions',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: Colors.black.withOpacity(0.8),
                        blurRadius: 4,
                        offset: const Offset(1, 1),
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.6),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),

          // List
          Expanded(
            child: Container(
              color: Colors.transparent,
              child: _isLoading && _ratings.isEmpty
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        backgroundColor: Colors.transparent,
                      ),
                    )
                  : _ratings.isEmpty
                      ? Center(
                          child: Text(
                            'No reactions yet',
                            style: TextStyle(
                              color: _textColor,
                              fontSize: 16,
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: _scrollController,
                          key: PageStorageKey('ratings_${widget.postId}'),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _ratings.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, __) => Divider(
                            color: Colors.white.withOpacity(0.06),
                            height: 1,
                          ),
                          itemBuilder: (ctx, index) {
                            if (index < _ratings.length) {
                              return _buildRatingItem(_ratings[index]);
                            }
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: _isLoadingMore
                                    ? const CircularProgressIndicator(
                                        color: Colors.white,
                                        backgroundColor: Colors.transparent,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final topH = screenH * 0.3;
    final panelH = screenH * 0.7;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () {
          FocusScope.of(context).unfocus();
          Navigator.of(context).pop();
        },
        child: Container(
          height: screenH,
          child: Stack(
            children: [
              // Top 30% — transparent tap-to-close
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topH,
                child: GestureDetector(
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    Navigator.of(context).pop();
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),

              // Bottom 70% — ratings panel
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: panelH,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black12,
                        Colors.black26,
                      ],
                      stops: [0.0, 0.2, 1.0],
                    ),
                  ),
                  child: _buildRatingsContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
