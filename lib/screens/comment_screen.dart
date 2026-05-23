import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/models/user.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/comment_card.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';

/// TikTok/Reels Style Comments Bottom Sheet with Transparent Background - ALWAYS DARK MODE
class CommentsBottomSheet extends StatefulWidget {
  final String postId;
  final String postImage;
  final bool isVideo;
  final VoidCallback onClose;
  final VideoPlayerController? videoController;

  const CommentsBottomSheet({
    Key? key,
    required this.postId,
    required this.postImage,
    required this.isVideo,
    required this.onClose,
    this.videoController,
  }) : super(key: key);

  @override
  CommentsBottomSheetState createState() => CommentsBottomSheetState();
}

class CommentsBottomSheetState extends State<CommentsBottomSheet> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _replyFocusNode = FocusNode();

  final Map<String, bool> _commentLikes = {};
  final Map<String, int> _commentLikeCounts = {};

  bool _shouldResumeVideo = false;

  // reply state
  String? replyingToCommentId;
  final ValueNotifier<String?> replyingToUsernameNotifier = ValueNotifier(null);
  final TextEditingController commentEditingController =
      TextEditingController();
  final Map<String, int> _expandedReplies = {};

  // Supabase methods
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();
  final SupabaseClient _supabase = Supabase.instance.client;

  // local comments list (each is Map with DB row fields)
  final List<Map<String, dynamic>> _comments = [];

  // OPTIMISTIC COMMENTS: Add optimistic comments list
  final List<Map<String, dynamic>> _optimisticComments = [];

  // Banned words detection
  static const List<String> _bannedWords = [
    'hang yourself',
    'kill yourself',
    'kys',
    'fuck you',
    'fuck off',
    'bitch',
    'whore',
    'cunt',
    'nigger',
    'nigga',
    'die',
    'suicide',
    'slut',
    'retard',
  ];
  bool _containsBannedWords = false;

  // Loading states
  bool _isLoadingComments = false;
  bool _isPostingComment = false;

  @override
  void initState() {
    super.initState();

    // Store video state before opening comments
    if (widget.isVideo && widget.videoController != null) {
      _shouldResumeVideo = widget.videoController!.value.isPlaying;
      if (_shouldResumeVideo) {
        widget.videoController!.pause();
      }
    }

    commentEditingController.addListener(_checkForBannedWords);
    _replyFocusNode.addListener(_onReplyFocusChange);
    _loadComments();
  }

  void _onReplyFocusChange() {
    if (_replyFocusNode.hasFocus) {
      // Scroll to bottom when keyboard appears
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _replyFocusNode.dispose();
    _scrollController.dispose();
    commentEditingController.removeListener(_checkForBannedWords);
    commentEditingController.dispose();
    replyingToUsernameNotifier.dispose();

    // Resume video if it was playing before comments opened
    if (widget.isVideo &&
        widget.videoController != null &&
        _shouldResumeVideo) {
      widget.videoController!.play();
    }

    widget.onClose();
    super.dispose();
  }

  // Helper to normalise different client return shapes
  dynamic _unwrap(dynamic res) {
    try {
      if (res == null) return null;
      if (res is Map && res.containsKey('data')) return res['data'];
    } catch (_) {}
    return res;
  }

  Future<void> _fetchAllLikeStatuses(String userId) async {
    try {
      final commentIds =
          _comments.map((c) => c['id']?.toString() ?? '').toList();

      if (commentIds.isEmpty) return;

      final res = await _supabase
          .from('comment_likes')
          .select()
          .eq('uid', userId)
          .inFilter('comment_id', commentIds);

      final likedComments = List<Map<String, dynamic>>.from(res ?? []);

      setState(() {
        // Reset all likes to false first
        for (var commentId in commentIds) {
          _commentLikes[commentId] = false;
        }

        // Set liked comments to true
        for (var like in likedComments) {
          final commentId = like['comment_id']?.toString() ?? '';
          _commentLikes[commentId] = true;
        }
      });
    } catch (e) {}
  }

  // Add a method to update like status - OPTIMISTIC UPDATE
  void _updateCommentLike(String commentId, bool isLiked, int likeCount) {
    setState(() {
      _commentLikes[commentId] = isLiked;
      _commentLikeCounts[commentId] = likeCount;
    });
  }

  void _checkForBannedWords() {
    final text = commentEditingController.text.toLowerCase();
    final containsBanned = _bannedWords.any((word) => text.contains(word));
    if (containsBanned != _containsBannedWords) {
      setState(() {
        _containsBannedWords = containsBanned;
      });
    }
  }

  bool get isReplying => replyingToCommentId != null;

  void startReply(String commentId, String username) {
    replyingToCommentId = commentId;
    replyingToUsernameNotifier.value = username;
    commentEditingController.clear();

    // Clear focus and request focus for reply
    FocusScope.of(context).requestFocus(FocusNode());
    _replyFocusNode.requestFocus();
  }

  // Helper method to check if timestamps are close enough to be considered the same comment
  bool _areTimestampsClose(DateTime? timestamp1, DateTime? timestamp2) {
    if (timestamp1 == null || timestamp2 == null) return false;

    final difference = timestamp1.difference(timestamp2).abs();
    // Consider comments within 30 seconds as the same
    return difference.inSeconds < 30;
  }

  DateTime? _parseTimestamp(dynamic timestamp) {
    if (timestamp == null) return null;

    try {
      if (timestamp is DateTime) {
        return timestamp;
      } else if (timestamp is String) {
        return DateTime.parse(timestamp);
      } else if (timestamp is int) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
    } catch (e) {
      // Silent error handling
    }
    return null;
  }

  Future<void> _loadComments() async {
    try {
      setState(() => _isLoadingComments = true);

      // Get user from provider
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      final user = userProvider.user;

      if (user == null) return;

      // Fetch comments
      final res = await _supabase
          .from('comments')
          .select()
          .eq('postid', widget.postId)
          .order('like_count', ascending: false)
          .order('date_published', ascending: false);

      final rows = _unwrap(res) ?? res;

      if (rows is List) {
        // Update comments and like counts
        setState(() {
          _comments.clear();
          _comments.addAll(List<Map<String, dynamic>>.from(rows));

          // Remove any optimistic comments that have been confirmed by the server
          if (_optimisticComments.isNotEmpty) {
            _optimisticComments.removeWhere((optimisticComment) {
              return _comments.any((serverComment) {
                return serverComment['comment_text'] ==
                        optimisticComment['comment_text'] &&
                    serverComment['uid'] == optimisticComment['uid'] &&
                    _areTimestampsClose(
                        _parseTimestamp(serverComment['date_published']),
                        optimisticComment['timestamp']);
              });
            });
          }

          // Initialize like counts
          for (var comment in _comments) {
            final commentId = comment['id']?.toString() ?? '';
            _commentLikeCounts[commentId] = (comment['like_count'] ?? 0) as int;
          }
        });

        // Then fetch like status for all comments
        await _fetchAllLikeStatuses(user.uid);
      }
    } catch (e) {
      if (mounted) showSnackBar(context, 'Failed to load comments: $e');
    } finally {
      if (mounted) setState(() => _isLoadingComments = false);
    }
  }

  Future<void> postComment(String uid, String name, String profilePic) async {
    final text = commentEditingController.text.trim();
    final maxCommentLength = 250;

    // Check character limit first
    if (text.length > maxCommentLength) {
      if (!mounted) return;
      showSnackBar(context,
          "Comments cannot exceed $maxCommentLength characters. Your comment is ${text.length} characters.");
      return;
    }

    // Prevent posting if banned words are present
    if (_containsBannedWords) {
      if (!mounted) return;
      showSnackBar(context, "Comment contains banned words");
      return;
    }

    if (text.isEmpty) {
      if (!mounted) return;
      showSnackBar(context, "Comment cannot be empty");
      return;
    }

    // OPTIMISTIC UPDATE: Create and add optimistic comment immediately
    final Map<String, dynamic> optimisticComment = {
      'id':
          'optimistic_${DateTime.now().millisecondsSinceEpoch}', // Temporary ID
      'comment_text': text,
      'uid': uid,
      'name': name,
      'profilePic': profilePic,
      'timestamp': DateTime.now(), // Client timestamp
      'like_count': 0,
      'likes': [],
      'isOptimistic': true, // Mark as optimistic
    };

    if (replyingToCommentId != null) {
      optimisticComment['parent_comment_id'] = replyingToCommentId!;
    }

    setState(() {
      _optimisticComments.add(optimisticComment);
      commentEditingController.clear();
    });

    // Keep focus on text field
    _replyFocusNode.requestFocus();

    // Scroll to show new comment immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && mounted) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    try {
      String res;
      if (replyingToCommentId != null) {
        // Post reply
        res = await _postsMethods.postReply(
          postId: widget.postId,
          commentId: replyingToCommentId!,
          uid: uid,
          name: name,
          profilePic: profilePic,
          text: text,
        );

        if (res != 'success') {
          // If the reply failed to send, remove the optimistic comment
          if (mounted) {
            setState(() {
              _optimisticComments.removeWhere(
                  (comment) => comment['id'] == optimisticComment['id']);
            });
            showSnackBar(context, "Could not post reply: $res");
          }
        }
      } else {
        // Post top-level comment
        res = await _postsMethods.postComment(
          widget.postId,
          text,
          uid,
          name,
          profilePic,
        );

        if (res != 'success') {
          // If the comment failed to send, remove the optimistic comment
          if (mounted) {
            setState(() {
              _optimisticComments.removeWhere(
                  (comment) => comment['id'] == optimisticComment['id']);
            });
            showSnackBar(context, "Could not post comment: $res");
          }
        }
      }

      if (!mounted) return;

      // Refresh comments after posting
      if (res == 'success') {
        replyingToCommentId = null;
        replyingToUsernameNotifier.value = null;
        await _loadComments(); // Reload comments to show the new one
      }

      // Scroll again after comment is sent to ensure visibility
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && mounted) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (err) {
      // Remove optimistic comment on error
      if (mounted) {
        setState(() {
          _optimisticComments.removeWhere(
              (comment) => comment['id'] == optimisticComment['id']);
        });
        showSnackBar(context,
            'Please try again later or contact us at ratedly9@gmail.com');
      }
    }
  }

  Widget _buildCommentsContent(AppUser user) {
    final safeUsername = user.username ?? 'Someone';
    final safePhotoUrl = user.photoUrl ?? '';

    // COMBINE: Merge server comments with optimistic comments
    List<Map<String, dynamic>> allComments = [..._comments];

    // Add optimistic comments that aren't yet confirmed by the server
    for (final optimisticComment in _optimisticComments) {
      // Check if this optimistic comment has been confirmed by the server
      final isConfirmed = _comments.any((serverComment) {
        return serverComment['comment_text'] ==
                optimisticComment['comment_text'] &&
            serverComment['uid'] == optimisticComment['uid'] &&
            _areTimestampsClose(
                _parseTimestamp(serverComment['date_published']),
                optimisticComment['timestamp']);
      });

      if (!isConfirmed) {
        allComments.add(optimisticComment);
      }
    }

    // Sort all comments by timestamp
    allComments.sort((a, b) {
      try {
        DateTime? timeA =
            _parseTimestamp(a['date_published'] ?? a['timestamp']);
        DateTime? timeB =
            _parseTimestamp(b['date_published'] ?? b['timestamp']);

        if (timeA == null || timeB == null) return 0;

        return timeA.compareTo(timeB);
      } catch (e) {
        return 0;
      }
    });

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
          // Drag handle bar - transparent with minimal indicator
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

          // Header - completely transparent
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
                  'Comments',
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
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.of(context).pop();
                    },
                  ),
                ),
              ],
            ),
          ),

          // Comments list - COMPLETELY TRANSPARENT
          Expanded(
            child: Container(
              color: Colors.transparent,
              child: _isLoadingComments && _comments.isEmpty
                  ? Center(
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        backgroundColor: Colors.transparent,
                      ),
                    )
                  : allComments.isEmpty
                      ? Center(
                          child: Text(
                            'No comments yet, be the first to comment!',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ) // KEPT ORIGINAL STYLE HERE
                      : ListView.builder(
                          controller: _scrollController,
                          key: PageStorageKey('comments_${widget.postId}'),
                          itemCount: allComments.length,
                          itemBuilder: (ctx, index) {
                            final row = allComments[index];
                            final snap =
                                SupabaseSnap(row['id']?.toString() ?? '', row);

                            // Extract name safely with proper type handling
                            final nameValue = snap['name'];
                            final String userName = nameValue is String
                                ? nameValue
                                : nameValue?.toString() ?? 'Unknown User';

                            return Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: CommentCard(
                                snap: snap,
                                currentUserId: user.uid,
                                postId: widget.postId,
                                onReply: () => startReply(snap.id, userName),
                                onNestedReply:
                                    (String commentId, String username) =>
                                        startReply(commentId, username),
                                initialRepliesToShow:
                                    _expandedReplies[snap.id] ?? 2,
                                onRepliesExpanded: (newCount) {
                                  _expandedReplies[snap.id] = newCount;
                                },
                                isReplying: isReplying,
                                isLiked: _commentLikes[snap.id] ?? false,
                                likeCount: _commentLikeCounts[snap.id] ?? 0,
                                onLikeChanged: _updateCommentLike,
                                forcedTransparent: true,
                              ),
                            );
                          },
                        ),
            ),
          ),

          // Bottom input bar - semi-transparent
          _buildBottomInputBar(safeUsername, safePhotoUrl),
        ],
      ),
    );
  }

  Widget _buildBottomInputBar(String safeUsername, String safePhotoUrl) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.only(
          left: 16,
          right: 8,
          top: 12,
          bottom: 12,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.9),
              Colors.black.withOpacity(0.6),
              Colors.transparent,
            ],
            stops: const [0.0, 0.6, 1.0],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_containsBannedWords)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Warning: Using such words will get you banned!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.5),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.transparent,
                    backgroundImage:
                        (safePhotoUrl.isNotEmpty && safePhotoUrl != "default")
                            ? NetworkImage(safePhotoUrl)
                            : null,
                    child: (safePhotoUrl.isEmpty || safePhotoUrl == "default")
                        ? Icon(Icons.account_circle,
                            size: 36, color: Colors.white.withOpacity(0.8))
                        : null,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: ValueListenableBuilder<String?>(
                      valueListenable: replyingToUsernameNotifier,
                      builder: (context, replyingToUsername, _) {
                        return TextField(
                          focusNode: _replyFocusNode,
                          controller: commentEditingController,
                          style: TextStyle(
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 2,
                                offset: const Offset(1, 1),
                              ),
                            ],
                          ),
                          enabled: true,
                          maxLength: 250,
                          decoration: InputDecoration(
                            hintText: replyingToUsername != null
                                ? 'Replying to @$replyingToUsername'
                                : 'Comment as $safeUsername',
                            hintStyle:
                                TextStyle(color: Colors.white.withOpacity(0.8)),
                            border: InputBorder.none,
                            counterStyle:
                                TextStyle(color: Colors.white.withOpacity(0.6)),
                            filled: true,
                            fillColor: Colors.black.withOpacity(0.4),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(25),
                              borderSide: BorderSide(
                                color: Colors.white.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(25),
                              borderSide: BorderSide(
                                color: Colors.white.withOpacity(0.6),
                                width: 1.5,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Consumer<UserProvider>(
                  builder: (context, userProvider, _) {
                    final user = userProvider.user;
                    if (user == null) {
                      return const SizedBox.shrink();
                    }
                    return InkWell(
                      onTap: _containsBannedWords
                          ? null
                          : () =>
                              postComment(user.uid, safeUsername, safePhotoUrl),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 10, horizontal: 16),
                        decoration: BoxDecoration(
                          gradient: _containsBannedWords
                              ? null
                              : LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white.withOpacity(0.9),
                                    Colors.white.withOpacity(0.7),
                                  ],
                                ),
                          color: _containsBannedWords
                              ? Colors.grey.withOpacity(0.3)
                              : null,
                          borderRadius: BorderRadius.circular(25),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.3),
                            width: 1,
                          ),
                          boxShadow: _containsBannedWords
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: Text(
                          'Post',
                          style: TextStyle(
                            color: _containsBannedWords
                                ? Colors.white.withOpacity(0.4)
                                : Colors.black,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    );
                  },
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
    final UserProvider userProvider = Provider.of<UserProvider>(context);
    final AppUser? user = userProvider.user;

    if (user == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
            child: CircularProgressIndicator(
          color: Colors.white,
          backgroundColor: Colors.transparent,
        )),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () {
          // Close comments when tapping on transparent areas
          FocusScope.of(context).unfocus();
          Navigator.of(context).pop();
        },
        child: Container(
          height: MediaQuery.of(context).size.height,
          child: Stack(
            children: [
              // Top area - tap to close (completely transparent)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: MediaQuery.of(context).size.height * 0.3,
                child: GestureDetector(
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    Navigator.of(context).pop();
                  },
                  child: Container(
                    color: Colors.transparent,
                  ),
                ),
              ),

              // Comments Panel - Bottom area with transparency
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  height: MediaQuery.of(context).size.height * 0.7,
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
                  child: _buildCommentsContent(user),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Tiny shim so existing CommentCard code that uses `snap.id` and `snap['field']` keeps working.
class SupabaseSnap {
  final String id;
  final Map<String, dynamic> data;
  SupabaseSnap(this.id, this.data);
  operator [](String key) => data[key];
}
