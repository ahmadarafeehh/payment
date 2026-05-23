import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:video_player/video_player.dart';

class ExpandableText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color expandColor;
  final int maxLength;

  const ExpandableText({
    Key? key,
    required this.text,
    required this.style,
    required this.expandColor,
    this.maxLength = 115,
  }) : super(key: key);

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
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

// ── TikTok-style follow badge — same design & behaviour as PostCard ──────────
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
        // Optimistic: show tick immediately
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

// Stacks avatar + TikTok badge: badge centre sits on bottom edge of avatar
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

class CommentCard extends StatefulWidget {
  final dynamic snap;
  final String currentUserId;
  final String postId;
  final VoidCallback onReply;
  final Function(String, String)? onNestedReply;
  final int initialRepliesToShow;
  final Function(int)? onRepliesExpanded;
  final bool isReplying;
  final bool isLiked;
  final int likeCount;
  final Function(String, bool, int)? onLikeChanged;
  final bool forcedTransparent;

  const CommentCard({
    super.key,
    required this.snap,
    required this.currentUserId,
    required this.postId,
    required this.onReply,
    this.onNestedReply,
    this.initialRepliesToShow = 2,
    this.onRepliesExpanded,
    required this.isReplying,
    this.isLiked = false,
    this.likeCount = 0,
    this.onLikeChanged,
    this.forcedTransparent = false,
  });

  @override
  State<CommentCard> createState() => _CommentCardState();
}

class _CommentCardState extends State<CommentCard> {
  final List<String> _reportReasons = const [
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

  final Map<String, bool> _replyLikes = {};
  final Map<String, int> _replyLikeCounts = {};

  bool _isLiked = false;
  int _likeCount = 0;
  late int _repliesToShow;

  StreamSubscription<List<Map<String, dynamic>>>? _repliesSub;
  List<Map<String, dynamic>> _replies = [];

  @override
  void initState() {
    super.initState();
    _repliesToShow = widget.initialRepliesToShow;
    _isLiked = widget.isLiked;
    _likeCount = widget.likeCount;
    _subscribeToReplies();
  }

  @override
  void dispose() {
    _repliesSub?.cancel();
    super.dispose();
  }

  Color _getTextColor() => const Color(0xFFd9d9d9);
  Color _getCardColor() =>
      widget.forcedTransparent ? Colors.transparent : const Color(0xFF121212);
  Color _getTransparentCardColor() => Colors.black.withOpacity(0.15);
  Color _getIconColor() => const Color(0xFFd9d9d9);

  Widget _buildUserAvatar(
      String photoUrl, double radius, bool forcedTransparent) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    final isVideo = !isDefault && VideoUtils.isVideoFile(photoUrl);
    final textColor = _getTextColor();
    final cardColor =
        forcedTransparent ? _getTransparentCardColor() : _getCardColor();

    if (isDefault) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: cardColor,
        child: Icon(Icons.account_circle,
            size: radius * 2, color: textColor.withOpacity(0.8)),
      );
    }
    if (isVideo) {
      return VideoProfileAvatar(
        videoUrl: photoUrl,
        radius: radius,
        backgroundColor: cardColor,
        iconColor: _getIconColor(),
        forcedTransparent: forcedTransparent,
      );
    }
    return CircleAvatar(
        radius: radius,
        backgroundColor: cardColor,
        backgroundImage: NetworkImage(photoUrl));
  }

  Future<void> _fetchLikeStatus() async {
    try {
      final likeCheck = await Supabase.instance.client
          .from('comment_likes')
          .select()
          .eq(
              'comment_id',
              widget.snap['commentId'] ??
                  widget.snap['commentid'] ??
                  widget.snap.id)
          .eq('uid', widget.currentUserId)
          .maybeSingle();
      setState(() => _isLiked = likeCheck != null);
    } catch (e) {
      if (kDebugMode) print('Error fetching like status: $e');
      setState(() => _isLiked = false);
    }
  }

  Future<void> _deleteComment(BuildContext context) async {
    final textColor = _getTextColor();
    final cardColor = _getCardColor();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: cardColor,
        title: Text('Delete Comment', style: TextStyle(color: textColor)),
        content: Text('Are you sure you want to delete this comment?',
            style: TextStyle(color: textColor.withOpacity(0.8))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: textColor))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete', style: TextStyle(color: Colors.red[400]))),
        ],
      ),
    );
    if (confirmed ?? false) {
      try {
        await SupabasePostsMethods().deleteComment(
          widget.postId,
          widget.snap['commentId'] ??
              widget.snap['commentid'] ??
              widget.snap.id,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Comment deleted')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Something went wrong, please try again later or contact us at ratedly9@gmail.com')));
      }
    }
  }

  void _showReportDialog(BuildContext context, {String? replyId}) {
    String? selectedReason;
    final textColor = _getTextColor();
    final cardColor = _getCardColor();
    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: cardColor,
          title: Text('Report Comment', style: TextStyle(color: textColor)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Why are you reporting this ${replyId != null ? "reply" : "comment"}?',
                    style: TextStyle(color: textColor.withOpacity(0.8))),
                const SizedBox(height: 12),
                ..._reportReasons.map((reason) => RadioListTile<String>(
                      title: Text(reason, style: TextStyle(color: textColor)),
                      value: reason,
                      groupValue: selectedReason,
                      activeColor: textColor,
                      onChanged: (v) => setState(() => selectedReason = v),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel', style: TextStyle(color: textColor))),
            TextButton(
              onPressed: selectedReason == null
                  ? null
                  : () async {
                      Navigator.pop(context);
                      final idToReport = replyId ??
                          widget.snap['commentId'] ??
                          widget.snap['commentid'] ??
                          widget.snap.id;
                      try {
                        final res = await SupabasePostsMethods().reportComment(
                          postId: widget.postId,
                          commentId: idToReport,
                          reason: selectedReason!,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(res == 'success'
                                ? 'Report submitted. Thank you!'
                                : 'Error submitting report.')));
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Error submitting report.')));
                      }
                    },
              child: Text('Submit', style: TextStyle(color: textColor)),
            ),
          ],
        ),
      ),
    );
  }

  void _expandReplies() {
    final newCount = _repliesToShow + 1;
    setState(() => _repliesToShow = newCount);
    widget.onRepliesExpanded?.call(newCount);
  }

  Future<Map<String, dynamic>?> _fetchUser(String uid) async {
    try {
      final res = await Supabase.instance.client
          .from('users')
          .select()
          .eq('uid', uid)
          .maybeSingle();
      if (res == null) return null;
      if (res is Map) {
        if (res.containsKey('data')) {
          final d = res['data'];
          if (d is Map) return Map<String, dynamic>.from(d);
          if (d is List && d.isNotEmpty) return Map<String, dynamic>.from(d[0]);
        } else {
          return Map<String, dynamic>.from(res);
        }
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('fetchUser error: $e');
    }
    return null;
  }

  Future<void> _fetchReplyLikesStatus() async {
    try {
      final replyIds = _replies.map((r) => r['id'].toString()).toList();
      if (replyIds.isEmpty) return;
      setState(() {
        for (var id in replyIds) _replyLikes[id] = false;
      });
      final res = await Supabase.instance.client
          .from('reply_likes')
          .select('reply_id')
          .eq('uid', widget.currentUserId)
          .inFilter('reply_id', replyIds);
      setState(() {
        for (var like in res) _replyLikes[like['reply_id']] = true;
      });
    } catch (e) {
      if (kDebugMode) print('Error fetching reply likes: $e');
    }
  }

  void _subscribeToReplies() {
    final commentId =
        widget.snap['commentId'] ?? widget.snap['commentid'] ?? widget.snap.id;
    _repliesSub = Supabase.instance.client
        .from('replies')
        .stream(primaryKey: ['id'])
        .eq('commentid', commentId)
        .listen((List<Map<String, dynamic>> data) async {
          if (mounted) {
            setState(() {
              _replies = data;
              for (var reply in _replies) {
                final replyId = reply['id'].toString();
                final dynamic rawCount = reply['like_count'] ?? 0;
                _replyLikeCounts[replyId] = (rawCount is num)
                    ? rawCount.toInt()
                    : int.tryParse(rawCount.toString()) ?? 0;
              }
            });
            await _fetchReplyLikesStatus();
          }
        });
  }

  Future<List<Map<String, dynamic>>> _fetchReplies(String commentId) async {
    try {
      dynamic res;
      try {
        res = await Supabase.instance.client
            .from('replies')
            .select()
            .eq('commentid', commentId)
            .order('like_count', ascending: false);
      } catch (_) {
        res = await Supabase.instance.client
            .from('replies')
            .select()
            .eq('commentid', commentId);
      }
      if (res == null) return [];
      dynamic raw = res;
      if (raw is Map && raw.containsKey('data')) raw = raw['data'];
      if (raw is List) {
        final list = raw
            .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map))
            .toList();
        list.sort((a, b) {
          final na = a['like_count'] ?? 0;
          final nb = b['like_count'] ?? 0;
          final ia =
              (na is num) ? na.toInt() : int.tryParse(na.toString()) ?? 0;
          final ib =
              (nb is num) ? nb.toInt() : int.tryParse(nb.toString()) ?? 0;
          return ib.compareTo(ia);
        });
        return list;
      }
    } catch (e) {
      if (kDebugMode) print('fetchReplies exception: $e');
    }
    return [];
  }

  Widget _buildRepliesList() {
    if (_replies.isEmpty) return const SizedBox.shrink();
    final visibleReplies = _replies.take(_repliesToShow).toList();
    final textColor = _getTextColor();
    return Column(
      children: [
        ...visibleReplies.map((data) => _buildReplyItem(data)),
        if (_replies.length > _repliesToShow)
          GestureDetector(
            onTap: _expandReplies,
            child: Padding(
              padding: const EdgeInsets.only(left: 40, top: 8),
              child: Row(
                children: [
                  Icon(Icons.keyboard_arrow_down,
                      size: 16, color: textColor.withOpacity(0.6)),
                  const SizedBox(width: 4),
                  Text('Show more',
                      style: TextStyle(
                          fontSize: 12, color: textColor.withOpacity(0.6))),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildReplyItem(Map<String, dynamic> data) {
    final String replyId = (data['id'] ?? '').toString();
    final String replyUid = (data['uid'] ?? '').toString();
    final String replyName = (data['name'] ?? 'User').toString();
    final String replyText =
        (data['reply_text'] ?? data['text'] ?? '').toString();

    final dynamic rawReplyLikeCount = data['like_count'] ?? 0;
    final int initialReplyLikeCount = (rawReplyLikeCount is num)
        ? rawReplyLikeCount.toInt()
        : int.tryParse(rawReplyLikeCount.toString()) ?? 0;
    final bool isReplyLiked = _replyLikes[replyId] ?? false;
    final int replyLikeCount =
        _replyLikeCounts[replyId] ?? initialReplyLikeCount;

    final dynamic rawDate = data['date_published'] ?? data['datepublished'];
    DateTime replyDate;
    if (rawDate == null) {
      replyDate = DateTime.now();
    } else if (rawDate is String) {
      replyDate = DateTime.tryParse(rawDate) ?? DateTime.now();
    } else {
      try {
        replyDate = (rawDate as dynamic).toDate();
      } catch (_) {
        replyDate = DateTime.now();
      }
    }

    final textColor = _getTextColor();
    final cardColor =
        widget.forcedTransparent ? _getTransparentCardColor() : _getCardColor();

    return Padding(
      padding: const EdgeInsets.only(left: 40, top: 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(8),
          border: widget.forcedTransparent
              ? Border.all(color: Colors.white.withOpacity(0.05), width: 0.3)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // ── Reply avatar + TikTok follow badge ───────────────────
                FutureBuilder<Map<String, dynamic>?>(
                  future: _fetchUser(replyUid),
                  builder: (ctx, userSnap) {
                    final user = userSnap.data ?? <String, dynamic>{};
                    final photoUrl = user['photoUrl'] ?? '';
                    const double replyAvatarRadius = 12.0;
                    const double replyAvatarDiameter = replyAvatarRadius * 2;

                    final avatar = GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => ProfileScreen(uid: replyUid))),
                      child: _buildUserAvatar(photoUrl, replyAvatarRadius,
                          widget.forcedTransparent),
                    );

                    return _buildAvatarWithFollow(
                      avatar: avatar,
                      avatarDiameter: replyAvatarDiameter,
                      ownerUid: replyUid,
                      currentUserId: widget.currentUserId,
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ProfileScreen(uid: replyUid))),
                        child: VerifiedUsernameWidget(
                            username: replyName,
                            uid: replyUid,
                            style: TextStyle(
                                fontWeight: FontWeight.bold, color: textColor)),
                      ),
                      const SizedBox(height: 2),
                      ExpandableText(
                          text: replyText,
                          style: TextStyle(color: textColor.withOpacity(0.9)),
                          expandColor: textColor.withOpacity(0.8)),
                    ],
                  ),
                ),
                Column(
                  children: [
                    IconButton(
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () async {
                        final bool prevLike = _replyLikes[replyId] ?? false;
                        final int prevCount = _replyLikeCounts[replyId] ?? 0;
                        setState(() {
                          _replyLikes[replyId] = !prevLike;
                          _replyLikeCounts[replyId] =
                              prevCount + (prevLike ? -1 : 1);
                        });
                        try {
                          final result = await SupabasePostsMethods().likeReply(
                            postId: widget.postId,
                            commentId: widget.snap['commentId'] ??
                                widget.snap['commentid'] ??
                                widget.snap.id,
                            replyId: replyId,
                            uid: widget.currentUserId,
                          );
                          if (result['action'] == 'error') {
                            setState(() {
                              _replyLikes[replyId] = prevLike;
                              _replyLikeCounts[replyId] = prevCount;
                            });
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    'Failed to like reply: ${result['error']}')));
                          }
                        } catch (e) {
                          setState(() {
                            _replyLikes[replyId] = prevLike;
                            _replyLikeCounts[replyId] = prevCount;
                          });
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Failed to like reply: ${e.toString()}')));
                        }
                      },
                      icon: Icon(
                          isReplyLiked ? Icons.favorite : Icons.favorite_border,
                          color: isReplyLiked
                              ? Colors.red[400]
                              : textColor.withOpacity(0.6),
                          size: 16),
                    ),
                    Text(replyLikeCount.toString(),
                        style: TextStyle(
                            fontSize: 12, color: textColor.withOpacity(0.8))),
                  ],
                ),
                const SizedBox(width: 4),
                if (!widget.isReplying) ...[
                  PopupMenuButton<String>(
                    constraints: const BoxConstraints(minWidth: 140),
                    icon: Icon(Icons.more_vert,
                        size: 16, color: textColor.withOpacity(0.8)),
                    color: widget.forcedTransparent
                        ? Colors.black.withOpacity(0.6)
                        : cardColor,
                    onSelected: (choice) async {
                      if (choice == 'delete') {
                        try {
                          final res = await SupabasePostsMethods().deleteReply(
                            postId: widget.postId,
                            commentId: widget.snap['commentId'] ??
                                widget.snap['commentid'] ??
                                widget.snap.id,
                            replyId: replyId,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(res == 'success'
                                  ? 'Reply deleted'
                                  : 'Error deleting reply')));
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Error deleting reply: ${e.toString()}')));
                        }
                      } else {
                        _showReportDialog(context, replyId: replyId);
                      }
                    },
                    itemBuilder: (ctx) {
                      if (replyUid == widget.currentUserId) {
                        return [
                          PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete Reply',
                                  style: TextStyle(color: _getTextColor())))
                        ];
                      } else {
                        return [
                          PopupMenuItem(
                              value: 'report',
                              child: Text('Report Reply',
                                  style: TextStyle(color: _getTextColor())))
                        ];
                      }
                    },
                  )
                ] else ...[
                  const SizedBox(width: 44),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(DateFormat.yMMMd().format(replyDate),
                    style: TextStyle(
                        fontSize: 10, color: textColor.withOpacity(0.6))),
                TextButton(
                  onPressed: () => widget.onNestedReply?.call(
                    data['commentId'] ??
                        widget.snap['commentId'] ??
                        widget.snap['commentid'] ??
                        widget.snap.id,
                    data['name'] ?? replyName,
                  ),
                  style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(40, 20),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: Text('Reply',
                      style: TextStyle(
                          fontSize: 10, color: textColor.withOpacity(0.8))),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final likesDynamic = widget.snap['likes'] ?? widget.snap['Likes'] ?? [];
    final List<String> likes = (likesDynamic is String)
        ? (likesDynamic.isEmpty
            ? <String>[]
            : List<String>.from(jsonDecode(likesDynamic) as List))
        : List<String>.from(likesDynamic as List<dynamic>);

    final dynamic rawLikeCount =
        widget.snap['like_count'] ?? widget.snap['likecount'] ?? 0;
    final int likeCount = (rawLikeCount is num)
        ? rawLikeCount.toInt()
        : int.tryParse(rawLikeCount.toString()) ?? 0;

    final textColor = _getTextColor();
    final cardColor =
        widget.forcedTransparent ? _getTransparentCardColor() : _getCardColor();
    final String commentText =
        (widget.snap['comment_text'] ?? widget.snap['text'] ?? '').toString();
    final String ownerUid = (widget.snap['uid'] ?? '').toString();

    return FutureBuilder<bool>(
      future: SupabaseBlockMethods()
          .isMutuallyBlocked(widget.currentUserId, ownerUid),
      builder: (context, blockSnapshot) {
        if (blockSnapshot.data ?? false) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius:
                widget.forcedTransparent ? BorderRadius.circular(12) : null,
            border: widget.forcedTransparent
                ? Border.all(color: Colors.white.withOpacity(0.05), width: 0.3)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Avatar + TikTok follow badge ─────────────────────────
                  FutureBuilder<Map<String, dynamic>?>(
                    future: _fetchUser(ownerUid),
                    builder: (context, userSnapshot) {
                      final userData = userSnapshot.data ?? <String, dynamic>{};
                      final photoUrl = userData['photoUrl'] ?? '';

                      const double avatarDiameter = 42.0; // radius 21 × 2

                      final avatar = GestureDetector(
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (context) =>
                                    ProfileScreen(uid: ownerUid))),
                        child: _buildUserAvatar(
                            photoUrl, 21, widget.forcedTransparent),
                      );

                      return _buildAvatarWithFollow(
                        avatar: avatar,
                        avatarDiameter: avatarDiameter,
                        ownerUid: ownerUid,
                        currentUserId: widget.currentUserId,
                      );
                    },
                  ),
                  // ── Comment content ──────────────────────────────────────
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) =>
                                        ProfileScreen(uid: ownerUid))),
                            child: VerifiedUsernameWidget(
                              username: widget.snap['name'] ?? 'User',
                              uid: ownerUid,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: textColor),
                            ),
                          ),
                          const SizedBox(height: 2),
                          ExpandableText(
                            text: commentText,
                            style: TextStyle(color: textColor.withOpacity(0.9)),
                            expandColor: textColor.withOpacity(0.8),
                          ),
                          if (commentText.length >= 250)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('${commentText.length}/250',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: textColor.withOpacity(0.6))),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Builder(builder: (ctx) {
                                  final dynamic rawDate =
                                      widget.snap['date_published'] ??
                                          widget.snap['datepublished'];
                                  DateTime date;
                                  if (rawDate == null) {
                                    date = DateTime.now();
                                  } else if (rawDate is String) {
                                    date = DateTime.tryParse(rawDate) ??
                                        DateTime.now();
                                  } else {
                                    try {
                                      date = (rawDate as dynamic).toDate();
                                    } catch (_) {
                                      date = DateTime.now();
                                    }
                                  }
                                  return Text(DateFormat.yMMMd().format(date),
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w400,
                                          color: textColor.withOpacity(0.6)));
                                }),
                                TextButton(
                                  onPressed: widget.onReply,
                                  style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(50, 20),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap),
                                  child: Text('Reply',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: textColor.withOpacity(0.8))),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!widget.isReplying) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: PopupMenuButton<String>(
                        constraints: const BoxConstraints(minWidth: 140),
                        icon: Icon(Icons.more_vert,
                            size: 16, color: textColor.withOpacity(0.8)),
                        color: widget.forcedTransparent
                            ? Colors.black.withOpacity(0.6)
                            : cardColor,
                        onSelected: (choice) {
                          if (choice == 'delete') {
                            _deleteComment(context);
                          } else if (choice == 'report') {
                            _showReportDialog(context);
                          }
                        },
                        itemBuilder: (ctx) {
                          if (widget.snap['uid'] == widget.currentUserId) {
                            return [
                              PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete',
                                      style: TextStyle(color: _getTextColor())))
                            ];
                          } else {
                            return [
                              PopupMenuItem(
                                  value: 'report',
                                  child: Text('Report',
                                      style: TextStyle(color: _getTextColor())))
                            ];
                          }
                        },
                      ),
                    ),
                  ] else ...[
                    const SizedBox(width: 40),
                  ],
                  Column(
                    children: [
                      IconButton(
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () async {
                          final bool prevLike = _isLiked;
                          final int prevCount = _likeCount;
                          setState(() {
                            _isLiked = !_isLiked;
                            _likeCount += _isLiked ? 1 : -1;
                          });
                          if (widget.onLikeChanged != null) {
                            widget.onLikeChanged!(
                              widget.snap['commentId'] ??
                                  widget.snap['commentid'] ??
                                  widget.snap.id,
                              _isLiked,
                              _likeCount,
                            );
                          }
                          try {
                            await SupabasePostsMethods().likeComment(
                              widget.postId,
                              widget.snap['commentId'] ??
                                  widget.snap['commentid'] ??
                                  widget.snap.id,
                              widget.currentUserId,
                            );
                          } catch (e) {
                            setState(() {
                              _isLiked = prevLike;
                              _likeCount = prevCount;
                            });
                            if (widget.onLikeChanged != null) {
                              widget.onLikeChanged!(
                                widget.snap['commentId'] ??
                                    widget.snap['commentid'] ??
                                    widget.snap.id,
                                prevLike,
                                prevCount,
                              );
                            }
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Failed to like comment. Please try again.')));
                          }
                        },
                        icon: Icon(
                          _isLiked ? Icons.favorite : Icons.favorite_border,
                          color: _isLiked
                              ? Colors.red[400]
                              : textColor.withOpacity(0.6),
                          size: 16,
                        ),
                      ),
                      Text(_likeCount.toString(),
                          style: TextStyle(
                              fontSize: 12, color: textColor.withOpacity(0.8))),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _buildRepliesList(),
              ),
            ],
          ),
        );
      },
    );
  }
}
