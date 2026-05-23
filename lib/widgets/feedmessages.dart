import 'package:flutter/material.dart';
import 'package:Ratedly/screens/messaging_screen.dart';
import 'package:Ratedly/resources/messages_firestore_methods.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'dart:async';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/providers/user_provider.dart'; // Add this import

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
  bool _isVideoMuted = true; // Muted by default

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
      // Muted by default as requested
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

class _FeedMessagesColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color progressIndicatorColor;
  final Color unreadBadgeColor;

  _FeedMessagesColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.progressIndicatorColor,
    required this.unreadBadgeColor,
  });
}

class _FeedMessagesDarkColors extends _FeedMessagesColorSet {
  _FeedMessagesDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          unreadBadgeColor: const Color(0xFFd9d9d9).withOpacity(0.1),
        );
}

class _FeedMessagesLightColors extends _FeedMessagesColorSet {
  _FeedMessagesLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.white,
          cardColor: Colors.grey[100]!,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
          progressIndicatorColor: Colors.black,
          unreadBadgeColor: Colors.black.withOpacity(0.1),
        );
}

class FeedMessages extends StatefulWidget {
  // Remove the required currentUserId parameter since we'll get it from UserProvider
  const FeedMessages({Key? key}) : super(key: key); // Changed this line

  @override
  _FeedMessagesState createState() => _FeedMessagesState();
}

class _FeedMessagesState extends State<FeedMessages>
    with WidgetsBindingObserver, AutomaticKeepAliveClientMixin {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _existingChats = [];
  List<String> _blockedUsers = [];
  List<Map<String, dynamic>> _suggestedUsers = [];

  final Map<String, Map<String, dynamic>> _userCache = {};
  final Map<String, Map<String, dynamic>> _lastMessageCache = {};
  final Map<String, int> _unreadCountCache = {};

  // Video controllers for profile pictures
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  bool _isLoading = true;
  bool _showSuggestions = false;
  bool _loadingMore = false;
  bool _hasMoreChats = true;

  String? _currentUserId; // Add this variable

  @override
  bool get wantKeepAlive => true;

  _FeedMessagesColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _FeedMessagesDarkColors() : _FeedMessagesLightColors();
  }

  // Check if profile image URL is a video
  bool _isProfileVideo(String url) {
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

  // Initialize video controller for a profile picture
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
      // Muted by default as requested
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

  // Dispose video controller
  void _disposeVideoController(String userId) {
    if (_videoControllers.containsKey(userId)) {
      _videoControllers[userId]?.dispose();
      _videoControllers.remove(userId);
      _videoControllersInitialized.remove(userId);
    }
  }

  // Dispose all video controllers
  void _disposeAllVideoControllers() {
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
  }

  // Pause all video controllers
  void _pauseAllVideos() {
    for (final controller in _videoControllers.values) {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Don't load data here, wait for didChangeDependencies
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get the user ID from UserProvider
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && _currentUserId == null) {
      _currentUserId = userProvider.firebaseUid;
      _loadInitialData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        _currentUserId == null) {
      _currentUserId = userProvider.supabaseUid;
      _loadInitialData();
    } else if (_currentUserId == null) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadInitialData() async {
    if (!mounted || _currentUserId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await Future.wait([
        _loadBlockedUsers(),
        _loadChatsMinimal(),
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

  Future<void> _loadChatsMinimal() async {
    if (_currentUserId == null) return;

    try {
      final chats = await _supabase
          .from('chats')
          .select(
              'id, participants, last_message, last_updated, streak_count, streak_checked_at, last_mutual_exchange')
          .contains('participants', [_currentUserId!]) // Use _currentUserId!
          .order('last_updated', ascending: false)
          .limit(11);

      if (chats.isEmpty) {
        _existingChats = [];
        return;
      }

      final validChats = <Map<String, dynamic>>[];
      for (final chat in chats) {
        final participants = List<String>.from(chat['participants']);
        final otherUserId = participants.firstWhere(
          (id) => id != _currentUserId, // Use _currentUserId!
          orElse: () => '',
        );

        if (otherUserId.isNotEmpty && !_blockedUsers.contains(otherUserId)) {
          final chatCopy = Map<String, dynamic>.from(chat);

          chatCopy['last_mutual_exchange'] =
              _parseDateTime(chatCopy['last_mutual_exchange']);

          if (chatCopy['streak_checked_at'] != null) {
            chatCopy['streak_checked_at'] =
                _parseDateTime(chatCopy['streak_checked_at']);
          }

          if (chatCopy['last_updated'] != null) {
            chatCopy['last_updated'] = _parseDateTime(chatCopy['last_updated']);
          }

          validChats.add(chatCopy);
        }
      }

      if (mounted) {
        setState(() {
          _existingChats = validChats;
          _hasMoreChats = chats.length == 11;
        });
      }
    } catch (e) {}
  }

  Future<void> _loadAdditionalDataInBackground() async {
    if (_existingChats.isEmpty) return;

    final userIDs = <String>[];
    for (final chat in _existingChats) {
      final participants = List<String>.from(chat['participants']);
      final otherUserId = participants.firstWhere(
        (id) => id != _currentUserId, // Use _currentUserId!
      );
      userIDs.add(otherUserId);
    }

    await Future.wait([
      _loadUsersBatch(userIDs),
      _loadLastMessagesBatch(
          _existingChats.map((c) => c['id'] as String).toList()),
      _loadUnreadCountsBatch(_existingChats),
      _loadSuggestions(),
    ]);

    // Initialize video controllers for users with video profile pictures
    for (final userId in userIDs) {
      final userData = _userCache[userId];
      if (userData != null) {
        final photoUrl = userData['photoUrl'] ?? userData['photo_url'] ?? '';
        if (_isProfileVideo(photoUrl)) {
          _initializeVideoController(userId, photoUrl);
        }
      }
    }
  }

  Future<void> _loadUsersBatch(List<String> userIds) async {
    if (userIds.isEmpty) return;

    final users =
        await _supabase.from('users').select().inFilter('uid', userIds);

    for (final user in users) {
      _userCache[user['uid']] = user;
    }

    for (final userId in userIds) {
      if (!_userCache.containsKey(userId)) {
        _userCache[userId] = {
          'uid': userId,
          'username': 'Not Found',
          'photoUrl': 'default',
          'photo_url': 'default'
        };
      }
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadLastMessagesBatch(List<String> chatIds) async {
    if (chatIds.isEmpty) return;

    final messages = await _supabase
        .from('messages')
        .select()
        .inFilter('chat_id', chatIds)
        .order('timestamp', ascending: false);

    final messagesByChat = <String, Map<String, dynamic>>{};
    for (final message in messages) {
      final chatId = message['chat_id'] as String;
      if (!messagesByChat.containsKey(chatId)) {
        final messageCopy = Map<String, dynamic>.from(message);
        messageCopy['timestamp'] = _parseDateTime(message['timestamp']);
        messagesByChat[chatId] = messageCopy;
      }
    }
    _lastMessageCache.addAll(messagesByChat);

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadUnreadCountsBatch(List<Map<String, dynamic>> chats) async {
    for (final chat in chats) {
      final count = await SupabaseMessagesMethods()
          .getUnreadCount(chat['id'], _currentUserId!) // Use _currentUserId!
          .first;
      _unreadCountCache[chat['id']] = count;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadMoreChats() async {
    if (!_hasMoreChats) return;
    if (_loadingMore) return;

    setState(() {
      _loadingMore = true;
    });

    final start = _existingChats.length;
    final end = start + 10;

    final moreChats = await _supabase
        .from('chats')
        .select(
            'id, participants, last_message, last_updated, streak_count, streak_checked_at, last_mutual_exchange')
        .contains('participants', [_currentUserId!]) // Use _currentUserId!
        .order('last_updated', ascending: false)
        .range(start, end);

    if (moreChats.isEmpty) {
      setState(() {
        _hasMoreChats = false;
        _loadingMore = false;
      });
      return;
    }

    final parsedChats = <Map<String, dynamic>>[];
    for (final chat in moreChats) {
      final chatCopy = Map<String, dynamic>.from(chat);
      chatCopy['last_mutual_exchange'] =
          _parseDateTime(chatCopy['last_mutual_exchange']);
      if (chatCopy['streak_checked_at'] != null) {
        chatCopy['streak_checked_at'] =
            _parseDateTime(chatCopy['streak_checked_at']);
      }
      if (chatCopy['last_updated'] != null) {
        chatCopy['last_updated'] = _parseDateTime(chatCopy['last_updated']);
      }
      parsedChats.add(chatCopy);
    }

    setState(() {
      _existingChats.addAll(parsedChats);
      _loadingMore = false;
      _hasMoreChats = moreChats.length == 11;
    });

    _processNewChats(parsedChats);
  }

  void _processNewChats(List<Map<String, dynamic>> newChats) async {
    final newUserIds = <String>{};
    final newChatIds = <String>[];

    for (final chat in newChats) {
      final participants = List<String>.from(chat['participants']);
      final otherUserId = participants.firstWhere(
        (id) => id != _currentUserId, // Use _currentUserId!
      );
      if (!_userCache.containsKey(otherUserId)) {
        newUserIds.add(otherUserId);
      }
      newChatIds.add(chat['id'] as String);
    }

    if (newUserIds.isNotEmpty) {
      await _loadUsersBatch(newUserIds.toList());
    }

    if (newChatIds.isNotEmpty) {
      await _loadLastMessagesBatch(newChatIds);
    }

    await _loadUnreadCountsBatch(newChats);

    // Initialize video controllers for new users with video profile pictures
    for (final userId in newUserIds) {
      final userData = _userCache[userId];
      if (userData != null) {
        final photoUrl = userData['photoUrl'] ?? userData['photo_url'] ?? '';
        if (_isProfileVideo(photoUrl)) {
          _initializeVideoController(userId, photoUrl);
        }
      }
    }
  }

  void _refreshData() {
    _loadInitialData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshData();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    }
  }

  Future<void> _loadBlockedUsers() async {
    if (_currentUserId == null) return;

    try {
      final blockedUsers = await SupabaseBlockMethods()
          .getBlockedUsers(_currentUserId!); // Use _currentUserId!

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

  Future<void> _loadSuggestions() async {
    if (_existingChats.length >= 3 || _currentUserId == null) return;

    final suggestedUserIds =
        await _getSuggestedUsers(3 - _existingChats.length);

    if (suggestedUserIds.isNotEmpty) {
      final users = await _supabase
          .from('users')
          .select()
          .inFilter('uid', suggestedUserIds);

      if (mounted) {
        setState(() {
          _suggestedUsers = users.cast<Map<String, dynamic>>();
          _showSuggestions = users.isNotEmpty;
        });
      }

      // Initialize video controllers for suggested users with video profile pictures
      for (final user in users) {
        final userId = user['uid'] ?? '';
        final photoUrl = user['photoUrl'] ?? user['photo_url'] ?? '';
        if (_isProfileVideo(photoUrl)) {
          _initializeVideoController(userId, photoUrl);
        }
      }
    }
  }

  Future<List<String>> _getSuggestedUsers(int count) async {
    if (count <= 0 || _currentUserId == null) return [];

    final existingUserIds = _existingChats.map((chat) {
      final participants = List<String>.from(chat['participants']);
      return participants.firstWhere((id) => id != _currentUserId);
    }).toList();

    final followsData = await _supabase
        .from('follows')
        .select('follower_id, following_id')
        .or('follower_id.eq.${_currentUserId},following_id.eq.${_currentUserId}'); // Use _currentUserId!

    final following = <String>[];
    final followers = <String>[];

    for (final follow in followsData) {
      if (follow['follower_id'] == _currentUserId) {
        // Use _currentUserId!
        following.add(follow['following_id'] as String);
      }
      if (follow['following_id'] == _currentUserId) {
        // Use _currentUserId!
        followers.add(follow['follower_id'] as String);
      }
    }

    List<String> candidates = [...following, ...followers]
        .where((id) => id != _currentUserId) // Use _currentUserId!
        .where((id) => !existingUserIds.contains(id))
        .where((id) => !_blockedUsers.contains(id))
        .toSet()
        .toList();

    return candidates.take(count).toList();
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'Just now';

    try {
      final messageTimeUtc = timestamp.toUtc();
      final nowUtc = DateTime.now().toUtc();
      final difference = nowUtc.difference(messageTimeUtc);

      if (difference.isNegative) {
        if (difference.inSeconds.abs() < 30) {
          return 'Just now';
        }
        final localTime = timestamp.toLocal();
        return '${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}';
      }

      if (difference.inSeconds < 60) {
        return 'Just now';
      } else if (difference.inMinutes < 60) {
        final minutes = difference.inMinutes;
        return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago';
      } else if (difference.inHours < 24) {
        final hours = difference.inHours;
        return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
      } else if (difference.inDays < 7) {
        final days = difference.inDays;
        return '$days ${days == 1 ? 'day' : 'days'} ago';
      } else if (difference.inDays < 30) {
        final weeks = (difference.inDays / 7).floor();
        return '$weeks ${weeks == 1 ? 'week' : 'weeks'} ago';
      } else if (difference.inDays < 365) {
        final months = (difference.inDays / 30).floor();
        return '$months ${months == 1 ? 'month' : 'months'} ago';
      } else {
        final years = (difference.inDays / 365).floor();
        return '$years ${years == 1 ? 'year' : 'years'} ago';
      }
    } catch (e) {
      return 'Recently';
    }
  }

  Widget _buildBlockedMessageItem(_FeedMessagesColorSet colors) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: colors.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.block, color: Colors.red[400], size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This conversation is unavailable due to blocking',
              style: TextStyle(
                color: colors.textColor.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(
      String userId, String photoUrl, _FeedMessagesColorSet colors) {
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

    // Regular image
    return CircleAvatar(
      radius: 21,
      backgroundColor: colors.cardColor,
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  Widget _buildSuggestionItem(
      Map<String, dynamic> userData, _FeedMessagesColorSet colors) {
    final username = userData['username'] ?? 'Unknown';
    final photoUrl = userData['photoUrl'] ?? userData['photo_url'] ?? '';
    final userId = userData['uid'] ?? '';

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.cardColor, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: _buildUserAvatar(userId, photoUrl, colors),
        title: VerifiedUsernameWidget(
          username: username,
          uid: userId,
          style: TextStyle(color: colors.textColor),
        ),
        trailing: Icon(Icons.person_add_alt_1, color: colors.iconColor),
        onTap: () async {
          // Pause all videos before navigation
          _pauseAllVideos();
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MessagingScreen(
                recipientUid: userId,
                recipientUsername: username,
                recipientPhotoUrl: photoUrl,
              ),
            ),
          );

          if (result == true) {
            _refreshData();
          }
        },
      ),
    );
  }

  Widget _buildChatItem(
      Map<String, dynamic> chat, _FeedMessagesColorSet colors) {
    final participants = List<String>.from(chat['participants']);
    final otherUserId = participants.firstWhere(
      (id) => id != _currentUserId, // Use _currentUserId!
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
      return _buildDetailedChatSkeleton(colors);
    }

    final username = userData['username'] ?? 'Unknown User';
    final photoUrl = userData['photoUrl'] ?? userData['photo_url'] ?? '';
    final countryCode = userData['country']?.toString();
    final lastMessageData = _lastMessageCache[chat['id']];
    final streakCount = chat['streak_count'] ?? 0;
    final streakCheckedAt = chat['streak_checked_at'];

    final lastMutualExchange = _parseDateTime(chat['last_mutual_exchange']);

    String lastMessage = 'No messages yet';
    String timestampText = '';
    bool isCurrentUserSender = false;
    bool isMessageRead = false;

    if (lastMessageData != null) {
      isMessageRead = lastMessageData['is_read'] ?? false;
      lastMessage = lastMessageData['message'] ?? '';

      final timestamp = _parseDateTime(lastMessageData['timestamp']);
      timestampText = _formatTimestamp(timestamp);

      isCurrentUserSender =
          lastMessageData['sender_id'] == _currentUserId; // Use _currentUserId!
    }

    final unreadCount = _unreadCountCache[chat['id']] ?? 0;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.cardColor, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: _buildUserAvatar(otherUserId, photoUrl, colors),
        title: Row(
          children: [
            Expanded(
              child: VerifiedUsernameWidget(
                username: username,
                uid: otherUserId,
                countryCode: countryCode,
                style: TextStyle(color: colors.textColor),
              ),
            ),
            if (streakCount > 0)
              SafeStreakExpiryIndicator(
                streakCount: streakCount,
                streakCheckedAt: streakCheckedAt,
                lastMutualExchange: lastMutualExchange,
                colors: colors,
              ),
          ],
        ),
        subtitle: Row(
          children: [
            if (isCurrentUserSender)
              Icon(
                isMessageRead ? Icons.done_all : Icons.done,
                size: 16,
                color: colors.textColor.withOpacity(0.6),
              ),
            Expanded(
              child: Text(
                lastMessage,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.textColor.withOpacity(0.6)),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timestampText,
              style: TextStyle(
                color: colors.textColor.withOpacity(0.6),
                fontSize: 12,
              ),
            ),
          ],
        ),
        trailing: unreadCount > 0
            ? Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: colors.unreadBadgeColor,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  unreadCount.toString(),
                  style: TextStyle(color: colors.textColor, fontSize: 12),
                ),
              )
            : null,
        onTap: () async {
          // Pause all videos before navigation
          _pauseAllVideos();
          await SupabaseMessagesMethods().markMessagesAsRead(
              chat['id'], _currentUserId!); // Use _currentUserId!

          _unreadCountCache[chat['id']] = 0;
          setState(() {});

          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MessagingScreen(
                recipientUid: otherUserId,
                recipientUsername: username,
                recipientPhotoUrl: photoUrl,
              ),
            ),
          );

          if (result == true) {
            _refreshData();
          }
        },
      ),
    );
  }

  Widget _buildDetailedChatSkeleton(_FeedMessagesColorSet colors) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.cardColor, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 21,
          backgroundColor: colors.cardColor.withOpacity(0.5),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 14,
              width: 120,
              decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.5),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 12,
              width: 180,
              decoration: BoxDecoration(
                color: colors.cardColor.withOpacity(0.4),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
        trailing: Container(
          width: 40,
          height: 20,
          decoration: BoxDecoration(
            color: colors.cardColor.withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestionSkeleton(_FeedMessagesColorSet colors) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.cardColor, width: 0.5),
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 21,
          backgroundColor: colors.cardColor.withOpacity(0.5),
        ),
        title: Container(
          height: 16,
          width: 100,
          decoration: BoxDecoration(
            color: colors.cardColor.withOpacity(0.5),
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
      ),
    );
  }

  Widget _buildSectionHeaderSkeleton(_FeedMessagesColorSet colors) {
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Container(
          height: 18,
          width: 80,
          decoration: BoxDecoration(
            color: colors.cardColor.withOpacity(0.6),
            borderRadius: BorderRadius.circular(4),
          ),
        ));
  }

  Widget _buildEmptyStateMessage(_FeedMessagesColorSet colors) {
    return Center(
        child: Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 80,
            color: colors.textColor.withOpacity(0.4),
          ),
          const SizedBox(height: 24),
          Text(
            'No messages yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: colors.textColor.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Start a conversation with someone!\nYour messages will appear here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: colors.textColor.withOpacity(0.6),
              height: 1.4,
            ),
          ),
        ],
      ),
    ));
  }

  Widget _buildNotSignedInMessage(_FeedMessagesColorSet colors) {
    return Center(
        child: Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.person_off,
            size: 80,
            color: colors.textColor.withOpacity(0.4),
          ),
          const SizedBox(height: 24),
          Text(
            'Please sign in',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: colors.textColor.withOpacity(0.8),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'You need to be signed in to view messages',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: colors.textColor.withOpacity(0.6),
              height: 1.4,
            ),
          ),
        ],
      ),
    ));
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
  Widget build(BuildContext context) {
    super.build(context);

    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    // Get user ID from UserProvider if not already set
    if (_currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      if (userProvider.firebaseUid != null) {
        _currentUserId = userProvider.firebaseUid;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _loadInitialData();
          }
        });
      } else if (userProvider.supabaseUid != null) {
        _currentUserId = userProvider.supabaseUid;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _loadInitialData();
          }
        });
      }
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.appBarIconColor),
        backgroundColor: colors.appBarBackgroundColor,
        title: Text('Messages', style: TextStyle(color: colors.textColor)),
        elevation: 0,
      ),
      body: _currentUserId == null && !_isLoading
          ? _buildNotSignedInMessage(colors)
          : _isLoading
              ? _buildEnhancedSkeletonLoading(colors)
              : _buildContent(colors),
    );
  }

  Widget _buildEnhancedSkeletonLoading(_FeedMessagesColorSet colors) {
    return ListView(
      children: [
        _buildSectionHeaderSkeleton(colors),
        _buildDetailedChatSkeleton(colors),
        _buildDetailedChatSkeleton(colors),
        _buildDetailedChatSkeleton(colors),
        _buildSectionHeaderSkeleton(colors),
        _buildSuggestionSkeleton(colors),
        _buildSuggestionSkeleton(colors),
        _buildDetailedChatSkeleton(colors),
        _buildDetailedChatSkeleton(colors),
      ],
    );
  }

  Widget _buildContent(_FeedMessagesColorSet colors) {
    if (_currentUserId == null) {
      return _buildNotSignedInMessage(colors);
    }

    final hasChats = _existingChats.isNotEmpty;
    final hasSuggestions = _showSuggestions && _suggestedUsers.isNotEmpty;

    if (!hasChats && !hasSuggestions) {
      return _buildEmptyStateMessage(colors);
    }

    final totalItemCount = _existingChats.length +
        _suggestedUsers.length +
        (_hasMoreChats ? 1 : 0);

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollNotification) {
        if (scrollNotification is ScrollEndNotification) {
          final metrics = scrollNotification.metrics;
          if (metrics.extentAfter < 500) {
            _loadMoreChats();
          }
        }
        return false;
      },
      child: ListView.builder(
        itemCount: totalItemCount,
        itemBuilder: (context, index) {
          if (index < _existingChats.length) {
            final chat = _existingChats[index];
            return _buildChatItem(chat, colors);
          } else if (index < _existingChats.length + _suggestedUsers.length) {
            final suggestionIndex = index - _existingChats.length;
            final userData = _suggestedUsers[suggestionIndex];
            return _buildSuggestionItem(userData, colors);
          } else {
            return _buildLoadingIndicator(colors);
          }
        },
      ),
    );
  }

  Widget _buildLoadingIndicator(_FeedMessagesColorSet colors) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: CircularProgressIndicator(
          color: colors.progressIndicatorColor,
        ),
      ),
    );
  }
}

class SafeStreakExpiryIndicator extends StatefulWidget {
  final int streakCount;
  final dynamic streakCheckedAt;
  final dynamic lastMutualExchange;
  final _FeedMessagesColorSet colors;

  const SafeStreakExpiryIndicator({
    Key? key,
    required this.streakCount,
    required this.streakCheckedAt,
    required this.lastMutualExchange,
    required this.colors,
  }) : super(key: key);

  @override
  _SafeStreakExpiryIndicatorState createState() =>
      _SafeStreakExpiryIndicatorState();
}

class _SafeStreakExpiryIndicatorState extends State<SafeStreakExpiryIndicator> {
  late Timer _timer;
  bool _isAboutToExpire = false;
  String _timeLeftText = '';
  bool _hasExpired = false;
  DateTime? _parsedLastMutualExchange;

  @override
  void initState() {
    super.initState();
    _parseDateTime();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _updateExpiryStatus();
    });
    _updateExpiryStatus();
  }

  void _parseDateTime() {
    DateTime? parseDynamicDateTime(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      if (value is String) {
        try {
          return DateTime.tryParse(value);
        } catch (e) {
          return null;
        }
      }
      if (value is int) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
      return null;
    }

    _parsedLastMutualExchange = parseDynamicDateTime(widget.lastMutualExchange);
  }

  void _updateExpiryStatus() {
    if (widget.streakCount > 0 && _parsedLastMutualExchange != null) {
      final streakExpiryTime =
          _parsedLastMutualExchange!.add(const Duration(hours: 24));
      final now = DateTime.now().toUtc();
      final timeLeft = streakExpiryTime.difference(now);

      final newIsAboutToExpire = timeLeft.inHours <= 5 && timeLeft.inHours > 0;
      final newHasExpired = timeLeft.isNegative;
      String newTimeLeftText = '';

      if (newIsAboutToExpire) {
        if (timeLeft.inHours > 0) {
          newTimeLeftText = '${timeLeft.inHours}h ${timeLeft.inMinutes % 60}m';
        } else {
          newTimeLeftText = '${timeLeft.inMinutes}m';
        }
      } else if (newHasExpired) {
        newTimeLeftText = 'Expired';
      }

      if (newIsAboutToExpire != _isAboutToExpire ||
          newHasExpired != _hasExpired ||
          newTimeLeftText != _timeLeftText) {
        if (mounted) {
          setState(() {
            _isAboutToExpire = newIsAboutToExpire;
            _hasExpired = newHasExpired;
            _timeLeftText = newTimeLeftText;
          });
        }
      }
    } else if (_isAboutToExpire || _hasExpired || _timeLeftText.isNotEmpty) {
      if (mounted) {
        setState(() {
          _isAboutToExpire = false;
          _hasExpired = false;
          _timeLeftText = '';
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant SafeStreakExpiryIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lastMutualExchange != widget.lastMutualExchange) {
      _parseDateTime();
      _updateExpiryStatus();
    }
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.streakCount == 0) return const SizedBox.shrink();

    String emoji = '🔥'; // Active streak (not expiring soon)
    if (_hasExpired) {
      emoji = '💀'; // CHANGED: From 💥 to 💀 (skull emoji)
    } else if (_isAboutToExpire) {
      emoji = '⏳'; // CHANGED: From 🔥 to ⏳ (hourglass emoji)
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _hasExpired
            ? Colors.grey.withOpacity(0.1)
            : _isAboutToExpire
                ? Colors.orange.withOpacity(0.1)
                : Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _hasExpired
              ? Colors.grey.withOpacity(0.3)
              : _isAboutToExpire
                  ? Colors.orange.withOpacity(0.3)
                  : Colors.red.withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            emoji,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 4),
          Text(
            '${widget.streakCount}',
            style: TextStyle(
              color: _hasExpired ? Colors.grey : widget.colors.textColor,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (_timeLeftText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '($_timeLeftText)',
                style: TextStyle(
                  color: _hasExpired ? Colors.grey : Colors.orange,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
