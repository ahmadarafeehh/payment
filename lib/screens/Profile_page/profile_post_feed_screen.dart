import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/widgets/postshare.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/widgets/rating_list_screen_postcard.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart'; // added for navigation
import 'package:timeago/timeago.dart' as timeago;

typedef _LoadMore = Future<List<Map<String, dynamic>>> Function(
    int currentCount);

// ─────────────────────────────────────────────────────────────────────────────
// Supabase logger — fire-and-forget insert into `vertical`
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _log(Map<String, dynamic> payload) async {
  try {
    await Supabase.instance.client.from('vertical').insert(payload);
  } catch (_) {
    // never crash the UI because of a logging failure
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProfilePostFeedScreen
// ─────────────────────────────────────────────────────────────────────────────
class ProfilePostFeedScreen extends StatefulWidget {
  final List<Map<String, dynamic>> initialPosts;
  final int initialIndex;
  final Map<String, dynamic> userData;
  final _LoadMore onLoadMore;
  final bool initialHasMore;
  final VoidCallback? onPostDeleted;

  const ProfilePostFeedScreen({
    Key? key,
    required this.initialPosts,
    required this.initialIndex,
    required this.userData,
    required this.onLoadMore,
    required this.initialHasMore,
    this.onPostDeleted,
  }) : super(key: key);

  @override
  State<ProfilePostFeedScreen> createState() => _ProfilePostFeedScreenState();
}

class _ProfilePostFeedScreenState extends State<ProfilePostFeedScreen> {
  late List<Map<String, dynamic>> _posts;
  late PageController _pageController;
  late int _currentIndex;
  bool _hasMore = false;
  bool _loadingMore = false;

  // One session ID per screen open so you can group rows in the DB.
  final String _sessionId =
      DateTime.now().microsecondsSinceEpoch.toString();

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
    _posts = List.from(widget.initialPosts);
    _hasMore = widget.initialHasMore;
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);

    // Log every post in the initial list so we know what types loaded.
    for (int i = 0; i < _posts.length; i++) {
      final url = _posts[i]['postUrl']?.toString() ?? '';
      _log({
        'session_id': _sessionId,
        'event_type': 'feed_init_post',
        'post_id': _posts[i]['postId']?.toString(),
        'is_video': _isVideoUrl(url),
        'post_url': url,
        'page_index': i,
        'total_posts': _posts.length,
        'extra': {
          'initial_index': widget.initialIndex,
          'has_more': _hasMore,
        },
      });
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final rawPage = _pageController.page ?? _currentIndex.toDouble();
    final page = rawPage.round();

    // Log every page-change event. If you never see these rows for a video
    // post, the PageView is not receiving the gesture at all — the inner
    // SingleChildScrollView is consuming it.
    if (page != _currentIndex) {
      _log({
        'session_id': _sessionId,
        'event_type': 'page_changed',
        'page_index': page,
        'raw_page': rawPage,
        'total_posts': _posts.length,
        'extra': {
          'from_index': _currentIndex,
          'to_index': page,
        },
      });
      setState(() => _currentIndex = page);
    }

    if (page >= _posts.length - 3 && _hasMore && !_loadingMore) {
      _log({
        'session_id': _sessionId,
        'event_type': 'load_more_triggered',
        'page_index': page,
        'total_posts': _posts.length,
      });
      _triggerLoadMore();
    }
  }

  Future<void> _triggerLoadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final batch = await widget.onLoadMore(_posts.length);
      _log({
        'session_id': _sessionId,
        'event_type': 'load_more_result',
        'total_posts': _posts.length + batch.length,
        'extra': {
          'batch_size': batch.length,
          'has_more_after': batch.isNotEmpty,
        },
      });
      if (mounted) {
        setState(() {
          _posts.addAll(batch);
          _hasMore = batch.isNotEmpty;
          _loadingMore = false;
        });
      }
    } catch (e) {
      _log({
        'session_id': _sessionId,
        'event_type': 'load_more_error',
        'extra': {'error': e.toString()},
      });
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onPostDeleted(int index) {
    _log({
      'session_id': _sessionId,
      'event_type': 'post_deleted',
      'post_id': _posts[index]['postId']?.toString(),
      'page_index': index,
    });
    widget.onPostDeleted?.call();
    if (!mounted) return;
    setState(() {
      _posts.removeAt(index);
      if (_currentIndex >= _posts.length && _currentIndex > 0) {
        _currentIndex = _posts.length - 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(_currentIndex);
          }
        });
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // NEW: Navigate to profile (same as PostCard)
  // ─────────────────────────────────────────────────────────────────────────
  void _goToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileScreen(uid: widget.userData['uid']?.toString() ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;

    final itemCount = _posts.length + (_hasMore || _loadingMore ? 1 : 0);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: GestureDetector(
          onTap: _goToProfile,
          child: VerifiedUsernameWidget(
            username: widget.userData['username']?.toString() ?? '',
            uid: widget.userData['uid']?.toString() ?? '',
            style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
          ),
        ),
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
          return _FeedPostPage(
            key: ValueKey(_posts[index]['postId']),
            post: _posts[index],
            userData: widget.userData,
            isActive: index == _currentIndex,
            sessionId: _sessionId,
            onPostDeleted: widget.onPostDeleted != null
                ? () => _onPostDeleted(index)
                : null,
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FeedPostPage
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
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();

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

  // Convenience wrapper that pre-fills the fields common to every row.
  void _sendLog(String eventType, {Map<String, dynamic>? extra}) {
    _log({
      'session_id': widget.sessionId,
      'event_type': eventType,
      'post_id': _postId,
      'is_video': _isVideo,
      'is_active': widget.isActive,
      'post_url': _postUrl,
      'is_video_init': _isVideoInitialized,
      'is_video_loading': _isVideoLoading,
      if (extra != null) 'extra': extra,
    });
  }

  @override
  void initState() {
    super.initState();
    _parseEditMetadata();
    _fetchAllData();

    _sendLog('page_init', extra: {
      'has_edit_metadata': widget.post['video_edit_metadata'] != null,
    });

    if (widget.isActive) _onBecomeActive();
  }

  @override
  void didUpdateWidget(_FeedPostPage old) {
    super.didUpdateWidget(old);
    if (widget.isActive != old.isActive) {
      _sendLog('active_state_changed', extra: {
        'from': old.isActive,
        'to': widget.isActive,
      });
    }
    if (widget.isActive && !old.isActive) {
      _onBecomeActive();
    } else if (!widget.isActive && old.isActive) {
      _onBecomeInactive();
    }
  }

  @override
  void dispose() {
    _sendLog('page_dispose');
    _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  void _onBecomeActive() {
    _sendLog('become_active');
    if (_isVideo) {
      if (_isVideoInitialized) {
        _videoController?.play();
        _sendLog('video_play_resumed');
      } else if (!_isVideoLoading) {
        _initVideo();
      }
    }
  }

  void _onBecomeInactive() {
    _sendLog('become_inactive');
    _videoController?.pause();
  }

  void _parseEditMetadata() {
    final raw = widget.post['video_edit_metadata'];
    if (raw == null) return;
    try {
      final map = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      _editResult = VideoEditResult.fromJson(map, File(''));
    } catch (e) {
      _sendLog('edit_metadata_parse_error', extra: {'error': e.toString()});
    }
  }

  Future<void> _fetchAllData() async {
    if (_dataFetched) return;
    _dataFetched = true;
    await Future.wait(
        [_fetchRatings(), _fetchReactionEmoji(), _fetchCommentsCount()]);
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
      _sendLog('fetch_ratings_error', extra: {'error': e.toString()});
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
    } catch (e) {
      _sendLog('fetch_emoji_error', extra: {'error': e.toString()});
    }
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
    } catch (e) {
      _sendLog('fetch_comments_error', extra: {'error': e.toString()});
    }
  }

  Future<void> _initVideo() async {
    if (_isVideoLoading || _isVideoInitialized || _postUrl.isEmpty) {
      _sendLog('video_init_skipped', extra: {
        'reason': _isVideoLoading
            ? 'already_loading'
            : _isVideoInitialized
                ? 'already_initialized'
                : 'empty_url',
      });
      return;
    }

    _sendLog('video_init_start');
    setState(() => _isVideoLoading = true);

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(_postUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      await controller.initialize();

      final ar = controller.value.aspectRatio;
      final size = controller.value.size;

      // ── This is the key diagnostic row ──────────────────────────────────
      // After initialization we know the true aspect ratio. If the video is
      // portrait (ar < 1) the AspectRatio widget will be TALLER than the
      // screen, causing SingleChildScrollView to become scrollable and steal
      // all vertical PageView swipes. Check content_taller_than_screen in
      // the vertical table — if it's true, that's the bug.
      _log({
        'session_id': widget.sessionId,
        'event_type': 'video_init_complete',
        'post_id': _postId,
        'is_video': true,
        'is_active': widget.isActive,
        'post_url': _postUrl,
        'aspect_ratio': ar,
        'is_video_init': true,
        'is_video_loading': false,
        // These two are populated in build() where we have MediaQuery,
        // but we log what we know here.
        'extra': {
          'video_width': size.width,
          'video_height': size.height,
          'duration_seconds': controller.value.duration.inSeconds,
          'note': 'Check content_taller_than_screen in the build log row',
        },
      });

      controller.setLooping(true);
      if (mounted) {
        setState(() {
          _videoController = controller;
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        if (widget.isActive) {
          controller.play();
          _sendLog('video_autoplay_after_init');
        }
      } else {
        controller.dispose();
        _sendLog('video_init_unmounted_before_setState');
      }
    } catch (e) {
      _sendLog('video_init_error', extra: {'error': e.toString()});
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  void _togglePlayback() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      if (_videoController!.value.isPlaying) {
        _videoController!.pause();
      } else {
        _videoController!.play();
      }
    });
  }

  void _toggleMute() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      _isMuted = !_isMuted;
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
    });
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
            (currentTotal - oldRating + rating) / _totalRatingsCount;
      } else {
        _totalRatingsCount++;
        _averageRating = (currentTotal + rating) / _totalRatingsCount;
      }
    });

    try {
      final res = await _postsMethods.ratePost(_postId, user.uid, rating);
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

  // ─────────────────────────────────────────────────────────────────────────
  // Navigate to profile (same as PostCard)
  // ─────────────────────────────────────────────────────────────────────────
  void _goToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileScreen(uid: widget.userData['uid']?.toString() ?? ''),
      ),
    );
  }

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

    // ── Log build context so we can see whether the content will overflow ──
    // This is the most important diagnostic: if content_taller_than_screen
    // is true on a video post, SingleChildScrollView is stealing the swipe.
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    if (_isVideo && _isVideoInitialized && _videoController != null) {
      final ar = _videoController!.value.aspectRatio;
      final videoWidgetHeight = screenWidth / ar;
      final contentTaller = videoWidgetHeight > screenHeight;
      _log({
        'session_id': widget.sessionId,
        'event_type': 'build_video_layout',
        'post_id': _postId,
        'is_video': true,
        'is_active': widget.isActive,
        'aspect_ratio': ar,
        'screen_height': screenHeight,
        'screen_width': screenWidth,
        'content_taller_than_screen': contentTaller,
        'is_video_init': _isVideoInitialized,
        'is_video_loading': _isVideoLoading,
        'extra': {
          'video_widget_height': videoWidgetHeight,
          'swipe_likely_broken': contentTaller,
        },
      });
    }

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // ─────────────────────────────────────────────────────────
                // Avatar now has a GestureDetector for navigation
                // ─────────────────────────────────────────────────────────
                GestureDetector(
                  onTap: _goToProfile,
                  child: _buildAvatar(photoUrl, uid, user?.uid ?? '', cardColor, textColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Username also wrapped with GestureDetector
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
                                color: textColor.withOpacity(0.6),
                                fontSize: 12)),
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

          _buildMedia(matrix, quarters, cardColor, textColor),

          if (description.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(description,
                  style: TextStyle(color: textColor, fontSize: 15)),
            ),

          if (!_isLoadingRatings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: RatingBar(
                averageRating: _averageRating,
                reactionEmoji: _reactionEmoji,
                initialThumbPosition:
                    _userRating == null ? 5.0 : _averageRating,
                onRatingEnd: _handleRatingSubmitted,
                hasUserRated: _userRating != null,
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
                          constraints: const BoxConstraints(
                              minWidth: 20, minHeight: 20),
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
                        builder: (_) => PostShare(
                            currentUserId: user.uid, postId: _postId),
                      );
                    }
                  },
                ),
                const Spacer(),
                GestureDetector(
                  onTap: isOwner
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    RatingListScreen(postId: _postId)),
                          )
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(4)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
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
      ),
    );
  }

  Widget _buildAvatar(String photoUrl, String uid, String currentUserId,
      Color cardColor, Color textColor) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    return CircleAvatar(
      radius: 20,
      backgroundColor: cardColor,
      backgroundImage: !isDefault ? NetworkImage(photoUrl) : null,
      child: isDefault
          ? Icon(Icons.account_circle, size: 40, color: textColor)
          : null,
    );
  }

  Widget _buildMedia(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    if (_isVideo)
      return _buildVideoPlayer(matrix, quarters, cardColor, textColor);
    return _buildImage(matrix, quarters, cardColor, textColor);
  }

  Widget _buildVideoPlayer(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    final double aspect = (_isVideoInitialized && _videoController != null)
        ? _videoController!.value.aspectRatio
        : 1.0;

    return AspectRatio(
      aspectRatio: aspect,
      child: GestureDetector(
        onTap: _togglePlayback,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            if (_isVideoInitialized && _videoController != null)
              ColorFiltered(
                colorFilter: ColorFilter.matrix(matrix),
                child: Transform.rotate(
                  angle: quarters * math.pi / 2,
                  child: VideoPlayer(_videoController!),
                ),
              )
            else if (_isVideoLoading)
              Center(child: CircularProgressIndicator(color: textColor))
            else
              Center(
                  child: Icon(Icons.videocam, color: textColor, size: 48)),
            if (_editResult != null && _editResult!.strokes.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: DrawingPainter(
                        strokes: _editResult!.strokes, currentStroke: null),
                  ),
                ),
              ),
            if (_editResult != null && _editResult!.overlays.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (_, constraints) => Stack(
                      children: _editResult!.overlays.map((o) {
                        return Positioned(
                          left: (o.position.dx * constraints.maxWidth)
                              .clamp(0.0, constraints.maxWidth - 10),
                          top: (o.position.dy * constraints.maxHeight)
                              .clamp(0.0, constraints.maxHeight - 10),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Text(o.text, style: overlayShadowStyle(o)),
                            Text(o.text, style: overlayTextStyle(o)),
                          ]),
                        );
                      }).toList(),
                    ),
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
                    child: Icon(
                        _isMuted ? Icons.volume_off : Icons.volume_up,
                        size: 18,
                        color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    return AspectRatio(
      aspectRatio: 1,
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
                child: Image.network(
                  _postUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => Container(
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
                  builder: (_, constraints) => Stack(
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
                          left: (o.position.dx * constraints.maxWidth)
                              .clamp(0.0, constraints.maxWidth - 10),
                          top: (o.position.dy * constraints.maxHeight)
                              .clamp(0.0, constraints.maxHeight - 10),
                          child: Stack(clipBehavior: Clip.none, children: [
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
    );
  }

  void _showComments(BuildContext context) {
    _videoController?.pause();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsBottomSheet(
        postId: _postId,
        postImage: _postUrl,
        isVideo: _isVideo,
        onClose: () {
          if (widget.isActive) _videoController?.play();
        },
        videoController: _videoController,
      ),
    ).then((_) => _fetchCommentsCount());
  }

  void _showOptionsMenu(
      BuildContext context, Color bgColor, Color textColor) {
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
                padding: const EdgeInsets.symmetric(
                    vertical: 14, horizontal: 16),
                child: Text('Delete',
                    style:
                        TextStyle(color: Colors.red[400], fontSize: 15)),
              ),
            ),
            InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: 14, horizontal: 16),
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
