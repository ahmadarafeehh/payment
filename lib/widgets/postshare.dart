import 'package:flutter/material.dart';
import 'package:Ratedly/resources/messages_firestore_methods.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:video_player/video_player.dart';

// VIDEO UTILS CLASS - Add this at the top
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

// VIDEO PROFILE AVATAR WIDGET - Add this after VideoUtils
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
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
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
      if (mounted) {
        setState(() {
          _isVideoInitialized = false;
        });
      }
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

// Define color schemes for both themes at top level
class _PostShareColorSet {
  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final Color primaryColor;
  final Color secondaryColor;
  final Color blueColor;
  final Color progressIndicatorColor;
  final Color checkboxColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color borderColor;
  final Color cardColor;
  final Color unreadBadgeColor;

  _PostShareColorSet({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.primaryColor,
    required this.secondaryColor,
    required this.blueColor,
    required this.progressIndicatorColor,
    required this.checkboxColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.borderColor,
    required this.cardColor,
    required this.unreadBadgeColor,
  });
}

class _PostShareDarkColors extends _PostShareColorSet {
  _PostShareDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          textColor: const Color(0xFFd9d9d9),
          iconColor: const Color(0xFFd9d9d9),
          primaryColor: const Color(0xFFd9d9d9),
          secondaryColor: const Color(0xFF333333),
          blueColor: const Color(0xFF0095f6),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          checkboxColor: const Color(0xFF333333),
          buttonBackgroundColor: const Color(0xFF0095f6),
          buttonTextColor: const Color(0xFFd9d9d9),
          borderColor: const Color(0xFF333333),
          cardColor: const Color(0xFF333333),
          unreadBadgeColor: const Color(0xFFd9d9d9).withOpacity(0.1),
        );
}

class _PostShareLightColors extends _PostShareColorSet {
  _PostShareLightColors()
      : super(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          iconColor: Colors.black,
          primaryColor: Colors.black,
          secondaryColor: Colors.grey[300]!,
          blueColor: const Color(0xFF0095f6),
          progressIndicatorColor: Colors.black,
          checkboxColor: Colors.grey[300]!,
          buttonBackgroundColor: const Color(0xFF0095f6),
          buttonTextColor: Colors.white,
          borderColor: Colors.grey[400]!,
          cardColor: Colors.grey[100]!,
          unreadBadgeColor: Colors.black.withOpacity(0.1),
        );
}

class PostShare extends StatefulWidget {
  final String currentUserId;
  final String postId;

  const PostShare({
    Key? key,
    required this.currentUserId,
    required this.postId,
  }) : super(key: key);

  @override
  _PostShareState createState() => _PostShareState();
}

class _PostShareState extends State<PostShare>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  final Set<String> selectedUsers = <String>{};
  bool _isSharing = false;
  final SupabaseClient _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _chatsWithUsers = [];
  List<String> _blockedUsers = [];
  final Map<String, Map<String, dynamic>> _userCache = {};

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  bool _isLoading = true;
  bool _loadingMore = false;
  bool _hasMoreChats = true;
  final ScrollController _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  _PostShareColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _PostShareDarkColors() : _PostShareLightColors();
  }

  bool _isProfileVideo(String url) {
    final lowerUrl = url.toLowerCase();
    return url.isNotEmpty &&
        url != 'default' &&
        (lowerUrl.endsWith('.mp4') ||
            lowerUrl.endsWith('.mov') ||
            lowerUrl.endsWith('.avi') ||
            lowerUrl.endsWith('.mkv') ||
            lowerUrl.contains('video'));
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
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
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

  void _disposeVideoController(String userId) {
    if (_videoControllers.containsKey(userId)) {
      _videoControllers[userId]?.dispose();
      _videoControllers.remove(userId);
      _videoControllersInitialized.remove(userId);
    }
  }

  void _disposeAllVideoControllers() {
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
  }

  void _pauseAllVideos() {
    for (final controller in _videoControllers.values) {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  DateTime? _parseDateTime(dynamic dateValue) {
    if (dateValue == null) return null;

    if (dateValue is DateTime) {
      return dateValue;
    }

    if (dateValue is String) {
      try {
        return DateTime.tryParse(dateValue);
      } catch (e) {
        return null;
      }
    }

    if (dateValue is int) {
      return DateTime.fromMillisecondsSinceEpoch(dateValue);
    }

    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _loadInitialData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _disposeAllVideoControllers();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels ==
        _scrollController.position.maxScrollExtent) {
      _loadMoreChats();
    }
  }

  Future<void> _loadInitialData() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await Future.wait([
        _loadBlockedUsers(),
        _loadChatsWithUsersMinimal(),
      ]);

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      _loadAdditionalDataInBackground();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadChatsWithUsersMinimal() async {
    try {
      final chats = await _supabase
          .from('chats')
          .select('id, participants, last_updated')
          .contains('participants', [widget.currentUserId])
          .order('last_updated', ascending: false)
          .limit(11);

      if (chats.isEmpty) {
        _chatsWithUsers = [];
        return;
      }

      final List<Map<String, dynamic>> validChats = [];
      for (final chat in chats) {
        final participants = List<String>.from(chat['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != widget.currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty && !_blockedUsers.contains(otherUserId)) {
          final chatCopy = Map<String, dynamic>.from(chat);

          if (chatCopy['last_updated'] != null) {
            chatCopy['last_updated'] = _parseDateTime(chatCopy['last_updated']);
          }

          validChats.add(chatCopy);
        }
      }

      if (mounted) {
        setState(() {
          _chatsWithUsers = validChats;
          _hasMoreChats = chats.length == 11;
        });
      }
    } catch (e) {
      // Error handling
    }
  }

  Future<void> _loadMoreChats() async {
    if (!_hasMoreChats) return;
    if (_loadingMore) return;

    setState(() {
      _loadingMore = true;
    });

    final start = _chatsWithUsers.length;
    final end = start + 10;

    try {
      final moreChats = await _supabase
          .from('chats')
          .select('id, participants, last_updated')
          .contains('participants', [widget.currentUserId])
          .order('last_updated', ascending: false)
          .range(start, end);

      if (moreChats.isEmpty) {
        setState(() {
          _hasMoreChats = false;
          _loadingMore = false;
        });
        return;
      }

      final List<Map<String, dynamic>> parsedChats = [];
      for (final chat in moreChats) {
        final participants = List<String>.from(chat['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != widget.currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty && !_blockedUsers.contains(otherUserId)) {
          final chatCopy = Map<String, dynamic>.from(chat);

          if (chatCopy['last_updated'] != null) {
            chatCopy['last_updated'] = _parseDateTime(chatCopy['last_updated']);
          }

          parsedChats.add(chatCopy);
        }
      }

      setState(() {
        _chatsWithUsers.addAll(parsedChats);
        _loadingMore = false;
        _hasMoreChats = moreChats.length == 11;
      });

      _loadUsersForNewChats(parsedChats);
    } catch (e) {
      setState(() {
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadAdditionalDataInBackground() async {
    if (_chatsWithUsers.isEmpty) return;

    final userIds = <String>[];
    for (final chat in _chatsWithUsers) {
      final participants = List<String>.from(chat['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != widget.currentUserId,
      );
      userIds.add(otherUserId);
    }

    await _loadUsersBatch(userIds);
  }

  Future<void> _loadUsersForNewChats(
      List<Map<String, dynamic>> newChats) async {
    final newUserIds = <String>{};

    for (final chat in newChats) {
      final participants = List<String>.from(chat['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != widget.currentUserId,
      );
      if (!_userCache.containsKey(otherUserId)) {
        newUserIds.add(otherUserId);
      }
    }

    if (newUserIds.isNotEmpty) {
      await _loadUsersBatch(newUserIds.toList());
    }
  }

  Future<void> _loadUsersBatch(List<String> userIds) async {
    if (userIds.isEmpty) return;

    try {
      final users = await _supabase
          .from('users')
          .select('uid, username, photoUrl, country')
          .inFilter('uid', userIds);

      for (final user in users) {
        _userCache[user['uid']] = user;

        final photoUrl = user['photoUrl'] ?? '';
        if (_isProfileVideo(photoUrl)) {
          _initializeVideoController(user['uid'], photoUrl);
        }
      }

      for (final userId in userIds) {
        if (!_userCache.containsKey(userId)) {
          _userCache[userId] = {
            'uid': userId,
            'username': 'User Not Found',
            'photoUrl': 'default',
            'country': null,
          };
        }
      }

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      // Error handling
    }
  }

  Future<void> _loadBlockedUsers() async {
    try {
      final blockedUsers =
          await SupabaseBlockMethods().getBlockedUsers(widget.currentUserId);

      if (mounted) {
        setState(() {
          _blockedUsers = blockedUsers;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _blockedUsers = [];
        });
      }
    }
  }

  Future<void> _sharePost() async {
    if (_isSharing || selectedUsers.isEmpty) {
      return;
    }

    setState(() => _isSharing = true);

    try {
      final postResponse = await _supabase
          .from('posts')
          .select()
          .eq('postId', widget.postId)
          .single();

      if (postResponse.isEmpty) {
        throw Exception('Post does not exist');
      }

      final Map<String, dynamic> postData = postResponse;
      final String postImageUrl = (postData['postUrl'] ?? '').toString();
      final String postCaption = (postData['description'] ?? '').toString();
      final String postOwnerId = (postData['uid'] ?? '').toString();

      final userResponse = await _supabase
          .from('users')
          .select()
          .eq('uid', postOwnerId)
          .single();

      final Map<String, dynamic> userData = userResponse;
      final String postOwnerUsername =
          (userData['username'] ?? 'Unknown User').toString();
      final String postOwnerPhotoUrl =
          (userData['photoUrl'] ?? '').toString().trim();

      for (final userId in selectedUsers) {
        final chatId = await SupabaseMessagesMethods()
            .getOrCreateChat(widget.currentUserId, userId);

        await SupabasePostsMethods().sharePostThroughChat(
          chatId: chatId,
          senderId: widget.currentUserId,
          receiverId: userId,
          postId: widget.postId,
          postImageUrl: postImageUrl,
          postCaption: postCaption,
          postOwnerId: postOwnerId,
          postOwnerUsername: postOwnerUsername,
          postOwnerPhotoUrl: postOwnerPhotoUrl,
        );
      }

      if (!mounted) {
        return;
      }

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Post shared with ${selectedUsers.length} user(s)'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Something went wrong, please try again later or contact us at ratedly9@gmail.com',
          ),
          duration: Duration(seconds: 2),
        ),
      );
    } finally {
      if (!mounted) {
        return;
      }
      setState(() => _isSharing = false);
    }
  }

  Widget _buildUserAvatar(
      String userId, String photoUrl, _PostShareColorSet colors) {
    final hasValidPhoto =
        photoUrl.isNotEmpty && photoUrl != "default" && photoUrl != "null";
    final isVideo = hasValidPhoto && _isProfileVideo(photoUrl);

    if (!hasValidPhoto) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: colors.cardColor,
        child: Icon(
          Icons.account_circle,
          size: 42,
          color: colors.iconColor,
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
            color: colors.cardColor,
          ),
          child: Center(
            child: CircularProgressIndicator(
              color: colors.progressIndicatorColor,
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
      backgroundColor: colors.cardColor,
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  Widget _buildLoadingIndicator(_PostShareColorSet colors) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: CircularProgressIndicator(
          color: colors.progressIndicatorColor,
        ),
      ),
    );
  }

  Widget _buildChatSkeleton(_PostShareColorSet colors) {
    return ListTile(
      leading: CircleAvatar(
        radius: 21,
        backgroundColor: colors.cardColor.withOpacity(0.5),
      ),
      title: Container(
        height: 16,
        width: 120,
        decoration: BoxDecoration(
          color: colors.cardColor.withOpacity(0.5),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      subtitle: Container(
        height: 14,
        width: 80,
        margin: const EdgeInsets.only(top: 4),
        decoration: BoxDecoration(
          color: colors.cardColor.withOpacity(0.4),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      trailing: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: colors.cardColor.withOpacity(0.4),
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Dialog(
      backgroundColor: colors.backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
        side: BorderSide(color: colors.borderColor),
      ),
      child: Container(
        padding: const EdgeInsets.all(16.0),
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Share Post',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colors.textColor,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _isLoading
                  ? ListView.builder(
                      itemCount: 3,
                      itemBuilder: (context, index) =>
                          _buildChatSkeleton(colors),
                    )
                  : _chatsWithUsers.isEmpty
                      ? _buildEmptyStateMessage(colors)
                      : _buildChatsList(colors),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed:
                    _isSharing || selectedUsers.isEmpty ? null : _sharePost,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.buttonBackgroundColor,
                  foregroundColor: colors.buttonTextColor,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isSharing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              colors.progressIndicatorColor),
                        ),
                      )
                    : const Text('Share Post'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateMessage(_PostShareColorSet colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_alt_outlined,
              size: 60,
              color: colors.iconColor.withOpacity(0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'No users to share with yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: colors.textColor.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start conversations with other users\nto share posts with them.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colors.textColor.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatsList(_PostShareColorSet colors) {
    final totalItemCount = _chatsWithUsers.length + (_hasMoreChats ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      itemCount: totalItemCount,
      itemBuilder: (context, index) {
        if (index >= _chatsWithUsers.length) {
          return _buildLoadingIndicator(colors);
        }

        final chat = _chatsWithUsers[index];
        final participants = List<String>.from(chat['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != widget.currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) {
          return const SizedBox.shrink();
        }

        if (_blockedUsers.contains(otherUserId)) {
          return const SizedBox.shrink();
        }

        final userData = _userCache[otherUserId];
        if (userData == null) {
          return _buildChatSkeleton(colors);
        }

        final username = userData['username'] ?? 'Unknown User';
        final photoUrl = userData['photoUrl'] ?? 'default';
        final countryCode = userData['country']?.toString();

        return Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.cardColor, width: 0.5),
            ),
          ),
          child: ListTile(
            leading: _buildUserAvatar(otherUserId, photoUrl, colors),
            title: Text(
              username,
              style: TextStyle(
                color: colors.textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: countryCode != null
                ? Text(
                    'From $countryCode',
                    style: TextStyle(
                      color: colors.textColor.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  )
                : null,
            trailing: Checkbox(
              value: selectedUsers.contains(otherUserId),
              checkColor: colors.primaryColor,
              fillColor: MaterialStateProperty.resolveWith<Color?>(
                (states) => colors.checkboxColor,
              ),
              onChanged: _isSharing
                  ? null
                  : (bool? selected) {
                      setState(() {
                        if (selected == true) {
                          selectedUsers.add(otherUserId);
                        } else {
                          selectedUsers.remove(otherUserId);
                        }
                      });
                    },
            ),
            onTap: _isSharing
                ? null
                : () {
                    setState(() {
                      if (selectedUsers.contains(otherUserId)) {
                        selectedUsers.remove(otherUserId);
                      } else {
                        selectedUsers.add(otherUserId);
                      }
                    });
                  },
          ),
        );
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadInitialData();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    }
  }
}
