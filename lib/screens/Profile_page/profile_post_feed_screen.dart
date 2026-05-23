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
import 'package:timeago/timeago.dart' as timeago;

// ─────────────────────────────────────────────────────────────────────────────
// Callback type: caller provides a function that loads the next batch of posts
// starting after [currentCount] already-loaded posts.
// ─────────────────────────────────────────────────────────────────────────────
typedef _LoadMore = Future<List<Map<String, dynamic>>> Function(
    int currentCount);

// ─────────────────────────────────────────────────────────────────────────────
// ProfilePostFeedScreen
// ─────────────────────────────────────────────────────────────────────────────
class ProfilePostFeedScreen extends StatefulWidget {
  /// The posts already shown in the profile grid — we start here.
  final List<Map<String, dynamic>> initialPosts;

  /// Which post to open first (0-based index into [initialPosts]).
  final int initialIndex;

  /// Profile owner's data (uid, username, photoUrl, isVerified, country, …).
  final Map<String, dynamic> userData;

  /// Called when the feed is within 3 posts of its end; must return the next
  /// batch. Return an empty list to signal no more posts.
  final _LoadMore onLoadMore;

  /// Whether there are more posts to load beyond [initialPosts].
  final bool initialHasMore;

  /// Provide this only for the logged-in user's own profile. When non-null, a
  /// delete option is shown and the callback is invoked after deletion so the
  /// caller can refresh its grid.
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

  @override
  void initState() {
    super.initState();
    _posts = List.from(widget.initialPosts);
    _hasMore = widget.initialHasMore;
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  // ── Fires on every scroll tick; uses integer page to avoid redundant work ─
  void _onPageScroll() {
    final page = _pageController.page?.round() ?? _currentIndex;
    if (page == _currentIndex) return;
    setState(() => _currentIndex = page);
    // Start loading more when 3 pages from the end.
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
          // Caller returns fewer than the batch size → no more posts.
          _hasMore = batch.isNotEmpty;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ── Remove a deleted post from the local list and adjust current index ────
  void _onPostDeleted(int index) {
    widget.onPostDeleted?.call();
    if (!mounted) return;
    setState(() {
      _posts.removeAt(index);
      // If we deleted the last post, step back one page.
      if (_currentIndex >= _posts.length && _currentIndex > 0) {
        _currentIndex = _posts.length - 1;
        // PageController page cannot be set directly after rebuild; animate.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController.jumpToPage(_currentIndex);
          }
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;

    // Total item count: posts + optional trailing spinner.
    final itemCount = _posts.length + (_hasMore || _loadingMore ? 1 : 0);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: VerifiedUsernameWidget(
          username: widget.userData['username']?.toString() ?? '',
          uid: widget.userData['uid']?.toString() ?? '',
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: itemCount,
        itemBuilder: (context, index) {
          // Trailing loading indicator page.
          if (index >= _posts.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: CircularProgressIndicator(color: textColor),
              ),
            );
          }
          return _FeedPostPage(
            // ValueKey on postId prevents Flutter from reusing a page widget
            // for a different post when items are removed from the list.
            key: ValueKey(_posts[index]['postId']),
            post: _posts[index],
            userData: widget.userData,
            isActive: index == _currentIndex,
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
// _FeedPostPage  — one post card inside the vertical PageView
// ─────────────────────────────────────────────────────────────────────────────
class _FeedPostPage extends StatefulWidget {
  final Map<String, dynamic> post;
  final Map<String, dynamic> userData;
  final bool isActive;
  final VoidCallback? onPostDeleted;

  const _FeedPostPage({
    Key? key,
    required this.post,
    required this.userData,
    required this.isActive,
    this.onPostDeleted,
  }) : super(key: key);

  @override
  State<_FeedPostPage> createState() => _FeedPostPageState();
}

class _FeedPostPageState extends State<_FeedPostPage>
    with AutomaticKeepAliveClientMixin {
  // ── keepAlive: visited pages stay alive so ratings/comments don't vanish
  //    when the user swipes back. Memory cost is acceptable for typical profile
  //    sizes (≤ ~100 posts); Flutter still disposes widgets far off-screen.
  @override
  bool get wantKeepAlive => true;

  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();

  // ── Video ──────────────────────────────────────────────────────────────────
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = false;
  bool _isMuted = false;

  // ── Ratings ────────────────────────────────────────────────────────────────
  double _averageRating = 0.0;
  int _totalRatingsCount = 0;
  double? _userRating;
  bool _isLoadingRatings = true;
  String _reactionEmoji = '❤️';
  int _commentCount = 0;

  // ── Edit metadata ──────────────────────────────────────────────────────────
  VideoEditResult? _editResult;

  // Guards so data is fetched only once per page lifetime.
  bool _dataFetched = false;

  // ── Helpers ────────────────────────────────────────────────────────────────
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

  @override
  void initState() {
    super.initState();
    _parseEditMetadata();

    // Fetch data eagerly — keeps the UI snappy when arriving via swipe.
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
    _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  // ── Activation / deactivation ──────────────────────────────────────────────
  void _onBecomeActive() {
    if (_isVideo) {
      if (_isVideoInitialized) {
        _videoController?.play();
      } else if (!_isVideoLoading) {
        _initVideo();
      }
    }
  }

  void _onBecomeInactive() {
    _videoController?.pause();
  }

  // ── Edit metadata ──────────────────────────────────────────────────────────
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

  // ── Data fetching ──────────────────────────────────────────────────────────
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
    } catch (_) {
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

  // ── Video initialization ───────────────────────────────────────────────────
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
      if (mounted) {
        setState(() {
          _videoController = controller;
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        if (widget.isActive) controller.play();
      } else {
        controller.dispose();
      }
    } catch (_) {
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

  // ── Rating submission (optimistic update) ─────────────────────────────────
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

  // ── Colour matrix from edit metadata ─────────────────────────────────────
  List<double> _buildColorMatrix() {
    if (_editResult == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return _editResult!.adjustments
        .combinedMatrix(kFilters[_editResult!.filterIndex].matrix);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin

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

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Profile header row ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildAvatar(
                    photoUrl, uid, user?.uid ?? '', cardColor, textColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VerifiedUsernameWidget(
                        username: widget.userData['username']?.toString() ?? '',
                        uid: uid,
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: textColor),
                      ),
                      if (timeStr.isNotEmpty)
                        Text(timeStr,
                            style: TextStyle(
                                color: textColor.withOpacity(0.6),
                                fontSize: 12)),
                    ],
                  ),
                ),
                // ── Options menu (delete for owner) ─────────────────────────
                if (isOwner && widget.onPostDeleted != null)
                  IconButton(
                    icon: Icon(Icons.more_vert, color: iconColor),
                    onPressed: () =>
                        _showOptionsMenu(context, bgColor, textColor),
                  ),
              ],
            ),
          ),

          // ── Media (image or video) ───────────────────────────────────────
          _buildMedia(matrix, quarters, cardColor, textColor),

          // ── Description ─────────────────────────────────────────────────
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(description,
                  style: TextStyle(color: textColor, fontSize: 15)),
            ),

          // ── Rating bar ───────────────────────────────────────────────────
          if (!_isLoadingRatings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: RatingBar(
                averageRating: _averageRating,
                reactionEmoji: _reactionEmoji,
                initialThumbPosition:
                    _userRating == null ? 5.0 : _averageRating,
                onRatingEnd: _handleRatingSubmitted,
              ),
            )
          else
            const SizedBox(height: 48),

          // ── Action row ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                // Comment button with badge
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
                // Share button
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
                // Voter count — tappable for post owner to see the list
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

          // Extra breathing room at the bottom so actions aren't clipped.
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Avatar (static image; profile-video avatars shown as still image here) ─
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

  // ── Media widget: image or video with filters, rotation & text overlays ───
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
              Center(child: Icon(Icons.videocam, color: textColor, size: 48)),
            // Drawing strokes overlay
            if (_editResult != null && _editResult!.strokes.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: DrawingPainter(
                        strokes: _editResult!.strokes, currentStroke: null),
                  ),
                ),
              ),
            // Text overlays
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
            // Mute button
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
                        size: 18, color: Colors.white),
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
                    child: Icon(Icons.broken_image, color: textColor, size: 48),
                  ),
                ),
              ),
            ),
          ),
          // Drawing strokes overlay
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

  // ── Comments bottom sheet ─────────────────────────────────────────────────
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

  // ── Delete / options menu ─────────────────────────────────────────────────
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
