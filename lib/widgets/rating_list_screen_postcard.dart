import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:video_player/video_player.dart';

// ============================================================================
// Video utilities (unchanged)
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
    if (VideoUtils.isVideoFile(widget.videoUrl)) {
      _initializeVideo();
    }
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
      if (mounted) {
        setState(() {
          _isVideoInitialized = true;
          _isVideoMuted = true;
        });
      }
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
          shape: BoxShape.circle,
          color: widget.backgroundColor,
        ),
        child: Center(
          child: CircularProgressIndicator(
            color: widget.iconColor,
            strokeWidth: 2.0,
          ),
        ),
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

// ============================================================================
// NEW: Read-only reaction display (track + emoji thumb)
// ============================================================================
class ReadOnlyRatingDisplay extends StatelessWidget {
  final double rating;          // 1.0 – 10.0
  final String reactionEmoji;   // e.g. '❤️', '🔥', etc.
  final double width;           // total width of the widget
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
    final themeProvider = Provider.of<ThemeProvider>(context);
    final bool isDark = themeProvider.themeMode == ThemeMode.dark;
    final Color trackColor = isDark ? Colors.grey[700]! : Colors.grey[400]!;
    final Color activeTrackColor = isDark ? Colors.white70 : Colors.black54;
    final double normalized = (rating - 1.0) / 9.0; // 0..1
    // Emoji thumb width ~ emojiSize, track has padding on both sides equal to half of thumb width
    final double thumbHalf = emojiSize / 2;
    final double trackWidth = width - emojiSize;
    final double thumbLeft = thumbHalf + normalized * trackWidth;

    return SizedBox(
      width: width,
      height: emojiSize + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Full track (inactive)
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
          // Active part of track (from start to thumb)
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
          // Emoji thumb
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
// Rating List Screen (updated to use ReadOnlyRatingDisplay)
// ============================================================================
class RatingListScreen extends StatefulWidget {
  final String postId;

  const RatingListScreen({
    super.key,
    required this.postId,
  });

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

  // Video controllers for profile pictures
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  // Cache for reaction emoji (per post, but same for all entries)
  String _reactionEmoji = '❤️';
  bool _emojiLoaded = false;

  // Helper methods for colors
  Color _getTextColor(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? const Color(0xFFd9d9d9)
        : Colors.black;
  }

  Color _getBackgroundColor(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? const Color(0xFF121212)
        : Colors.white;
  }

  Color _getCardColor(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? const Color(0xFF333333)
        : Colors.grey[200]!;
  }

  Color _getIconColor(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? const Color(0xFFd9d9d9)
        : Colors.grey[700]!;
  }

  @override
  void initState() {
    super.initState();
    _setupRealtime();
    _fetchReactionEmoji();
    _fetchInitialRatings();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels ==
          _scrollController.position.maxScrollExtent) {
        _loadMoreRatings();
      }
    });
  }

  @override
  void dispose() {
    _ratingsChannel.unsubscribe();
    _scrollController.dispose();
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
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
          callback: (payload) {
            _handleRealtimeUpdate(payload);
          },
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
        } else {
          setState(() => _emojiLoaded = true);
        }
      } else {
        setState(() => _emojiLoaded = true);
      }
    } catch (_) {
      if (mounted) setState(() => _emojiLoaded = true);
    }
  }

  Future<void> _initializeVideoController(
      String userId, String videoUrl) async {
    if (_videoControllers.containsKey(userId) ||
        _videoControllersInitialized[userId] == true) {
      return;
    }

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

      if (mounted) {
        setState(() {});
      }
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
          .select('''
            *,
            users!userid (username, photoUrl)
        ''')
          .eq('postid', widget.postId)
          .order('timestamp', ascending: false)
          .range(0, _limit - 1);

      if (mounted) {
        setState(() {
          _ratings = (response as List)
              .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
              .toList();

          _isLoading = false;
          _page = 1;
          _hasMore = _ratings.length == _limit;

          for (var rating in _ratings) {
            final userId = rating['userid'] as String?;
            if (userId != null) {
              final userData = rating['users'] as Map<String, dynamic>?;
              if (userData != null) {
                _userCache[userId] = userData;

                final photoUrl = userData['photoUrl'] ?? '';
                if (VideoUtils.isVideoFile(photoUrl)) {
                  _initializeVideoController(userId, photoUrl);
                }
              }
            }
          }
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
      final end = start + _limit - 1;

      final response = await Supabase.instance.client
          .from('post_rating')
          .select('''
          *,
          users!userid(username, photoUrl)
        ''')
          .eq('postid', widget.postId)
          .order('timestamp', ascending: false)
          .range(start, end);

      if (mounted) {
        setState(() {
          final newRatings = (response as List)
              .map<Map<String, dynamic>>((r) => r as Map<String, dynamic>)
              .toList();

          _ratings.addAll(newRatings);
          _isLoadingMore = false;
          _page++;
          _hasMore = newRatings.length == _limit;

          for (var rating in newRatings) {
            final userId = rating['userid'] as String?;
            if (userId != null) {
              final userData = rating['users'] as Map<String, dynamic>?;
              if (userData != null) {
                _userCache[userId] = userData;

                final photoUrl = userData['photoUrl'] ?? '';
                if (VideoUtils.isVideoFile(photoUrl)) {
                  _initializeVideoController(userId, photoUrl);
                }
              }
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  void _handleRealtimeUpdate(PostgresChangePayload payload) {
    final newRecord = payload.newRecord;
    final oldRecord = payload.oldRecord;
    final eventType = payload.eventType;

    setState(() {
      switch (eventType) {
        case PostgresChangeEvent.insert:
          if (newRecord != null) {
            _ratings.insert(0, newRecord);
            final userId = newRecord['userid'] as String?;
            if (userId != null) {
              final userData = newRecord['users'] as Map<String, dynamic>?;
              if (userData != null) {
                _userCache[userId] = userData;
                final photoUrl = userData['photoUrl'] ?? '';
                if (VideoUtils.isVideoFile(photoUrl)) {
                  _initializeVideoController(userId, photoUrl);
                }
              }
            }
          }
          break;
        case PostgresChangeEvent.update:
          if (oldRecord != null && newRecord != null) {
            final index = _ratings.indexWhere(
              (r) => r['userid'] == oldRecord['userid'],
            );
            if (index != -1) _ratings[index] = newRecord;

            final userId = newRecord['userid'] as String?;
            if (userId != null) {
              final userData = newRecord['users'] as Map<String, dynamic>?;
              if (userData != null) {
                _userCache[userId] = userData;
                final photoUrl = userData['photoUrl'] ?? '';
                if (VideoUtils.isVideoFile(photoUrl)) {
                  _initializeVideoController(userId, photoUrl);
                }
              }
            }
          }
          break;
        case PostgresChangeEvent.delete:
          if (oldRecord != null) {
            _ratings.removeWhere(
              (r) => r['userid'] == oldRecord['userid'],
            );
            final userId = oldRecord['userid'] as String?;
            if (userId != null && _videoControllers.containsKey(userId)) {
              _videoControllers[userId]?.dispose();
              _videoControllers.remove(userId);
              _videoControllersInitialized.remove(userId);
            }
          }
          break;
        default:
          break;
      }
    });
  }

  Widget _buildUserAvatar(
      String userId, String photoUrl, ThemeProvider themeProvider) {
    final iconColor = _getIconColor(themeProvider);
    final cardColor = _getCardColor(themeProvider);

    final hasValidPhoto =
        photoUrl.isNotEmpty && photoUrl != "default" && photoUrl != "null";
    final isVideo = hasValidPhoto && VideoUtils.isVideoFile(photoUrl);

    if (!hasValidPhoto) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: cardColor,
        child: Icon(
          Icons.account_circle,
          size: 42,
          color: iconColor,
        ),
      );
    }

    if (isVideo) {
      final controller = _videoControllers[userId];
      final isInitialized = _videoControllersInitialized[userId] == true;

      if (!isInitialized || controller == null) {
        return Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cardColor,
          ),
          child: Center(
            child: CircularProgressIndicator(
              color: iconColor,
              strokeWidth: 2.0,
            ),
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
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: 21,
      backgroundColor: cardColor,
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  Widget _buildRatingItem(
      Map<String, dynamic> rating, ThemeProvider themeProvider) {
    final textColor = _getTextColor(themeProvider);
    final cardColor = _getCardColor(themeProvider);
    final iconColor = _getIconColor(themeProvider);

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
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: _buildUserAvatar(userId, photoUrl, themeProvider),
        title: VerifiedUsernameWidget(
          username: username,
          uid: userId,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        subtitle: Text(
          timeText,
          style: TextStyle(color: textColor.withOpacity(0.6)),
        ),
        // Replace the numeric Chip with the read‑only reaction display
        trailing: _emojiLoaded
            ? ReadOnlyRatingDisplay(
                rating: userRating,
                reactionEmoji: _reactionEmoji,
                width: 80,
                emojiSize: 24,
                trackHeight: 3,
              )
            : const SizedBox(
                width: 80,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
        onTap: username == 'Deleted user'
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfileScreen(uid: userId),
                  ),
                ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final textColor = _getTextColor(themeProvider);
    final backgroundColor = _getBackgroundColor(themeProvider);
    final cardColor = _getCardColor(themeProvider);
    final progressIndicatorColor = _getIconColor(themeProvider);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text('Reactions', style: TextStyle(color: textColor)),
        backgroundColor: backgroundColor,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: _isLoading && _ratings.isEmpty
          ? Center(
              child: CircularProgressIndicator(color: progressIndicatorColor))
          : _ratings.isEmpty
              ? Center(
                  child: Text('No reactions yet',
                      style: TextStyle(color: textColor)))
              : ListView.separated(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _ratings.length + (_hasMore ? 1 : 0),
                  separatorBuilder: (context, index) =>
                      Divider(color: cardColor),
                  itemBuilder: (context, index) {
                    if (index < _ratings.length) {
                      return _buildRatingItem(_ratings[index], themeProvider);
                    } else {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: _isLoadingMore
                              ? CircularProgressIndicator(
                                  color: progressIndicatorColor)
                              : const SizedBox(),
                        ),
                      );
                    }
                  },
                ),
    );
  }
}
