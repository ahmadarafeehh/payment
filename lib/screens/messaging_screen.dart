import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/resources/messages_firestore_methods.dart';
import 'package:Ratedly/screens/Profile_page/image_screen.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/first_time/number_particle.dart';
import 'package:Ratedly/screens/first_time/falling_number_painter.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/providers/user_provider.dart'; // Add this import

class _MessagingColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color currentUserMessageColor;
  final Color otherUserMessageColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color progressIndicatorColor;
  final Color buttonColor;
  final Color buttonTextColor;

  _MessagingColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.currentUserMessageColor,
    required this.otherUserMessageColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.progressIndicatorColor,
    required this.buttonColor,
    required this.buttonTextColor,
  });
}

class _MessagingDarkColors extends _MessagingColorSet {
  _MessagingDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          currentUserMessageColor: const Color(0xFF333333),
          otherUserMessageColor: const Color(0xFF404040),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          buttonColor: const Color(0xFF333333),
          buttonTextColor: const Color(0xFFd9d9d9),
        );
}

class _MessagingLightColors extends _MessagingColorSet {
  _MessagingLightColors()
      : super(
          textColor: Colors.black87,
          backgroundColor: Colors.white,
          currentUserMessageColor: Color(0xFFF0F0F0),
          otherUserMessageColor: Color(0xFFE0E0E0),
          iconColor: Colors.black87,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black87,
          progressIndicatorColor: Colors.blue,
          buttonColor: Colors.grey[300]!,
          buttonTextColor: Colors.black87,
        );
}

class MessagingScreen extends StatefulWidget {
  final String recipientUid;
  final String recipientUsername;
  final String recipientPhotoUrl;

  const MessagingScreen({
    Key? key,
    required this.recipientUid,
    required this.recipientUsername,
    required this.recipientPhotoUrl,
  }) : super(key: key);

  @override
  _MessagingScreenState createState() => _MessagingScreenState();
}

class _MessagingScreenState extends State<MessagingScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();
  String? currentUserId; // Changed from final to nullable
  final SupabaseBlockMethods _blockMethods = SupabaseBlockMethods();
  final SupabaseClient _supabase = Supabase.instance.client;
  String? chatId;
  bool _isMutuallyBlocked = false;
  bool _hasInitialScroll = false;
  final ScrollController _scrollController = ScrollController();
  bool _isInitializing = true;
  bool _hasMarkedAsRead = false;
  final FocusNode _focusNode = FocusNode();

  final List<Map<String, dynamic>> _optimisticMessages = [];

  // Pagination variables
  int _currentPage = 0;
  final int _messagesPerPage = 10;
  bool _isLoadingMore = false;
  bool _hasMoreMessages = true;
  List<Map<String, dynamic>> _cachedMessages = [];
  DateTime? _oldestMessageTimestamp;

  Map<String, dynamic>? _replyingToMessage;
  bool _isReplying = false;

  final Map<String, double> _swipeOffsets = {};
  final Map<String, bool> _isSwiping = {};
  double _maxSwipeDistance = 60.0;
  bool _swipeEnabled = true;

  late AnimationController _animationController;
  final List<NumberParticle> _particles = [];
  final Random _random = Random();
  double _screenHeight = 0;

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  // ========== VIDEO PLAYER CONTROLLER FOR PROFILE PICTURE ==========
  VideoPlayerController? _recipientProfileVideoController;
  bool _isRecipientProfileVideoInitialized = false;
  bool _isRecipientProfileVideoMuted = true; // Muted by default as requested
  // ================================================================

  _MessagingColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _MessagingDarkColors() : _MessagingLightColors();
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _initializeFallingNumbers();

    // Setup scroll listener for pagination
    _scrollController.addListener(_scrollListener);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkInitialKeyboard();
    });

    // Initialize recipient profile video if needed
    if (_isProfileVideo(widget.recipientPhotoUrl)) {
      _initializeRecipientProfileVideo();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Get the user ID from UserProvider if not already set
    if (currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);

      if (userProvider.firebaseUid != null) {
        currentUserId = userProvider.firebaseUid;
        _initializeChat();
      } else if (userProvider.supabaseUid != null) {
        currentUserId = userProvider.supabaseUid;
        _initializeChat();
      } else {
        setState(() {
          _isInitializing = false;
        });
      }
    }

    // Mark messages as read if conditions are met
    if (chatId != null && !_hasMarkedAsRead && !_isInitializing) {
      _markMessagesAsRead();
    }
  }

  // Check if profile image URL is a video
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

  // ========== RECIPIENT PROFILE VIDEO HANDLING ==========
  Future<void> _initializeRecipientProfileVideo() async {
    if (_recipientProfileVideoController != null ||
        _isRecipientProfileVideoInitialized) {
      return;
    }

    try {
      final videoUrl = widget.recipientPhotoUrl;
      if (videoUrl.isEmpty) {
        throw Exception('Empty profile video URL');
      }

      _recipientProfileVideoController = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      await _recipientProfileVideoController!.initialize();
      // Muted by default as requested
      await _recipientProfileVideoController!.setVolume(0.0);
      await _recipientProfileVideoController!.setLooping(true);
      await _recipientProfileVideoController!.play();

      if (mounted) {
        setState(() {
          _isRecipientProfileVideoInitialized = true;
          _isRecipientProfileVideoMuted = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecipientProfileVideoInitialized = false;
        });
      }
    }
  }

  Widget _buildRecipientProfileVideoPlayer(_MessagingColorSet colors) {
    if (_recipientProfileVideoController == null ||
        !_isRecipientProfileVideoInitialized) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.otherUserMessageColor,
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
            width: _recipientProfileVideoController!.value.size.width,
            height: _recipientProfileVideoController!.value.size.height,
            child: VideoPlayer(_recipientProfileVideoController!),
          ),
        ),
      ),
    );
  }

  void _pauseRecipientProfileVideo() {
    if (_recipientProfileVideoController != null &&
        _isRecipientProfileVideoInitialized) {
      _recipientProfileVideoController!.pause();
    }
  }

  void _resumeRecipientProfileVideo() {
    if (_recipientProfileVideoController != null &&
        _isRecipientProfileVideoInitialized) {
      _recipientProfileVideoController!.play();
    }
  }

  void _disposeRecipientProfileVideoController() {
    if (_recipientProfileVideoController != null) {
      _recipientProfileVideoController!.dispose();
      _recipientProfileVideoController = null;
    }
    _isRecipientProfileVideoInitialized = false;
  }
  // ======================================================

  void _scrollListener() {
    // Load more messages when user scrolls near the top
    if (_scrollController.offset <= 100 &&
        !_isLoadingMore &&
        _hasMoreMessages &&
        chatId != null &&
        !_isInitializing) {
      _loadMoreMessages();
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages || chatId == null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final olderMessages =
          await SupabaseMessagesMethods().getMessagesPaginated(
        chatId!,
        page: _currentPage + 1,
        limit: _messagesPerPage,
      );

      if (olderMessages.isEmpty) {
        setState(() {
          _hasMoreMessages = false;
          _isLoadingMore = false;
        });
        return;
      }

      // Update oldest timestamp for next pagination
      if (olderMessages.isNotEmpty) {
        final oldest = _parseTimestamp(olderMessages.last['timestamp']);
        if (oldest != null) {
          _oldestMessageTimestamp = oldest;
        }
      }

      setState(() {
        _cachedMessages.insertAll(0, olderMessages);
        _currentPage++;
        _isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Pause all videos when app goes to background
      _pauseAllVideos();
      _pauseRecipientProfileVideo();
    }
  }

  @override
  void didChangeMetrics() {
    final bottomInset = WidgetsBinding.instance.window.viewInsets.bottom;
    if (bottomInset > 100.0) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _scrollToBottom(immediate: false);
        }
      });
    }
  }

  void _checkInitialKeyboard() {
    final bottomInset = WidgetsBinding.instance.window.viewInsets.bottom;
    if (bottomInset > 0) {
      _scrollToBottom(immediate: true);
    }
  }

  void _initializeFallingNumbers() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  void _initializeParticles(_MessagingColorSet colors) {
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

  void _scrollToBottom({bool immediate = false}) {
    if (!_scrollController.hasClients || !mounted) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    if ((maxScroll - currentScroll) > 50.0) {
      if (immediate) {
        _scrollController.jumpTo(maxScroll);
      } else {
        _scrollController.animateTo(
          maxScroll,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    }
  }

  bool get _isKeyboardVisible {
    return WidgetsBinding.instance.window.viewInsets.bottom > 100.0;
  }

  void _initializeChat() async {
    try {
      if (currentUserId == null) {
        setState(() {
          _isInitializing = false;
        });
        return;
      }

      _isMutuallyBlocked = await _blockMethods.isMutuallyBlocked(
        currentUserId!,
        widget.recipientUid,
      );

      if (_isMutuallyBlocked) {
        if (mounted) {
          setState(() {
            _isInitializing = false;
          });
        }
        return;
      }

      final id = await SupabaseMessagesMethods().getOrCreateChat(
        currentUserId!,
        widget.recipientUid,
      );

      if (mounted) {
        setState(() {
          chatId = id;
        });

        // Load initial page of messages
        await _loadInitialMessages();

        setState(() {
          _isInitializing = false;
        });
        _markMessagesAsRead();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Something went wrong, please try again later or contact us at ratedly9@gmail.com')),
        );
      }
    }
  }

  Future<void> _loadInitialMessages() async {
    if (chatId == null) return;

    try {
      final initialMessages =
          await SupabaseMessagesMethods().getMessagesPaginated(
        chatId!,
        page: 0,
        limit: _messagesPerPage,
      );

      // Process messages to ensure proper structure
      final processedMessages = initialMessages.map((msg) {
        return _processServerMessage(msg);
      }).toList();

      if (processedMessages.isNotEmpty) {
        final oldest = _parseTimestamp(processedMessages.last['timestamp']);
        if (oldest != null) {
          _oldestMessageTimestamp = oldest;
        }
      }

      setState(() {
        _cachedMessages = processedMessages;
        _currentPage = 0;
        _hasMoreMessages = processedMessages.length == _messagesPerPage;
      });
    } catch (e) {}
  }

  Map<String, dynamic> _processServerMessage(Map<String, dynamic> serverMsg) {
    // Check if this is a reply message based on server data
    final isReplyFromServer =
        serverMsg['isReply'] == true || serverMsg['repliedToMessageId'] != null;

    if (isReplyFromServer) {
      // Determine if the original message was from the current user
      final repliedMessageSender =
          serverMsg['repliedMessageSender']?.toString();
      final isOriginalFromSelf = repliedMessageSender == 'You';

      // Create a properly formatted message map with ALL reply fields
      return {
        'id': serverMsg['id'].toString(),
        'message': serverMsg['message']?.toString() ?? '',
        'senderId': serverMsg['senderId']?.toString() ?? '',
        'receiverId': serverMsg['receiverId']?.toString() ?? '',
        'timestamp': _parseTimestamp(serverMsg['timestamp']) ?? DateTime.now(),
        'isRead': serverMsg['isRead'] as bool? ?? false,
        'delivered': serverMsg['delivered'] as bool? ?? false,
        'type': serverMsg['type']?.toString() ?? 'text',
        'postShare': serverMsg['postShare'],
        'isReply': true,
        'repliedToMessageId': serverMsg['repliedToMessageId']?.toString(),
        'repliedMessagePreview':
            serverMsg['repliedMessagePreview']?.toString() ??
                'Original message',
        'repliedMessageSender': repliedMessageSender,
        'repliedMessageSenderIsSelf': isOriginalFromSelf,
        'repliedMessageType':
            serverMsg['repliedMessageType']?.toString() ?? 'text',
      };
    }

    // Return non-reply message with proper id
    return {
      'id': serverMsg['id'].toString(),
      'message': serverMsg['message']?.toString() ?? '',
      'senderId': serverMsg['senderId']?.toString() ?? '',
      'receiverId': serverMsg['receiverId']?.toString() ?? '',
      'timestamp': _parseTimestamp(serverMsg['timestamp']) ?? DateTime.now(),
      'isRead': serverMsg['isRead'] as bool? ?? false,
      'delivered': serverMsg['delivered'] as bool? ?? false,
      'type': serverMsg['type']?.toString() ?? 'text',
      'postShare': serverMsg['postShare'],
      'isReply': false,
    };
  }

  // Helper method to parse timestamp
  DateTime? _parseTimestamp(dynamic timestamp) {
    if (timestamp == null) return null;
    try {
      if (timestamp is DateTime) return timestamp;
      if (timestamp is String) return DateTime.parse(timestamp);
      if (timestamp is int)
        return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } catch (e) {}
    return null;
  }

  void _markMessagesAsRead() async {
    if (chatId == null || _hasMarkedAsRead || currentUserId == null) return;

    try {
      await SupabaseMessagesMethods()
          .markMessagesAsRead(chatId!, currentUserId!);
      _hasMarkedAsRead = true;
    } catch (e) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_scrollListener);

    if (chatId != null && !_hasMarkedAsRead && currentUserId != null) {
      SupabaseMessagesMethods().markMessagesAsRead(chatId!, currentUserId!);
    }
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _animationController.dispose();

    // Dispose all video controllers
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();

    // Dispose recipient profile video controller
    _disposeRecipientProfileVideoController();

    super.dispose();
  }

  void _pauseAllVideos() {
    for (final controller in _videoControllers.values) {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        controller.pause();
      }
    }
  }

  void _handleSwipeStart(String messageId, DragStartDetails details) {
    if (!_swipeEnabled || _isReplying) return;

    setState(() {
      _swipeOffsets[messageId] = 0;
      _isSwiping[messageId] = true;
    });
  }

  void _handleSwipeUpdate(String messageId, DragUpdateDetails details) {
    if (!_swipeEnabled || _isReplying) return;

    double newOffset = (_swipeOffsets[messageId] ?? 0) + details.primaryDelta!;

    if (newOffset > _maxSwipeDistance) {
      newOffset = _maxSwipeDistance;
    }
    if (newOffset < 0) {
      newOffset = 0;
    }

    setState(() {
      _swipeOffsets[messageId] = newOffset;
    });
  }

  void _handleSwipeEnd(
      String messageId, DragEndDetails details, Map<String, dynamic> message) {
    if (!_swipeEnabled || _isReplying) return;

    final offset = _swipeOffsets[messageId] ?? 0;

    if (offset > _maxSwipeDistance * 0.4) {
      _startReply(message);
      HapticFeedback.mediumImpact();
    }

    Future.delayed(Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _swipeOffsets.remove(messageId);
          _isSwiping.remove(messageId);
        });
      }
    });
  }

  void _resetSwipe(String messageId) {
    setState(() {
      _swipeOffsets.remove(messageId);
      _isSwiping.remove(messageId);
    });
  }

  void _startReply(Map<String, dynamic> message) {
    HapticFeedback.lightImpact();

    setState(() {
      _replyingToMessage = {
        'id': message['id'],
        'message': message['message'],
        'senderId': message['senderId'],
        'type': message['type'] ?? 'text',
        'repliedMessageSender':
            message['senderId'] == currentUserId ? 'You' : 'Them',
        'repliedMessageSenderIsSelf': message['senderId'] == currentUserId,
      };
      _isReplying = true;
    });

    _focusNode.requestFocus();

    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollToBottom(immediate: true);
    });
  }

  void _cancelReply() {
    setState(() {
      _replyingToMessage = null;
      _isReplying = false;
    });
  }

  String _getMessagePreview(Map<String, dynamic> message) {
    if (message['type'] == 'post') {
      return 'Shared a post';
    }

    String text = message['message'] ?? '';
    if (text.length > 30) {
      return '${text.substring(0, 30)}...';
    }
    return text;
  }

  Future<void> _initializeVideoController(String videoUrl) async {
    if (_videoControllers.containsKey(videoUrl) ||
        _videoControllersInitialized[videoUrl] == true) {
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      _videoControllers[videoUrl] = controller;
      _videoControllersInitialized[videoUrl] = false;

      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_videoControllersInitialized[videoUrl]!) {
          _videoControllersInitialized[videoUrl] = true;
          _configureVideoLoop(controller);

          if (mounted) {
            setState(() {});
          }
        }
      });

      await controller.initialize();
      await controller.setVolume(0.0);
    } catch (e) {
      _videoControllers.remove(videoUrl)?.dispose();
      _videoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureVideoLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final endPosition =
        duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;

    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        final currentPosition = controller.value.position;
        if (currentPosition >= endPosition) {
          controller.seekTo(Duration.zero);
        }
      }
    });

    controller.play();
  }

  VideoPlayerController? _getVideoController(String videoUrl) {
    return _videoControllers[videoUrl];
  }

  bool _isVideoControllerInitialized(String videoUrl) {
    return _videoControllersInitialized[videoUrl] == true;
  }

  bool _isVideoFile(String url) {
    if (url.isEmpty) return false;

    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.endsWith('.avi') ||
        lowerUrl.endsWith('.wmv') ||
        lowerUrl.endsWith('.flv') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.webm') ||
        lowerUrl.endsWith('.m4v') ||
        lowerUrl.endsWith('.3gp') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.contains('video=true');
  }

  Widget _buildVideoPlayer(String videoUrl, _MessagingColorSet colors) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);

    if (!isInitialized || controller == null) {
      return Container(
        height: 150,
        color: colors.otherUserMessageColor,
        child: Center(
          child: CircularProgressIndicator(
            color: colors.progressIndicatorColor,
          ),
        ),
      );
    }

    return Container(
      height: 150,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
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

  // ADDED: Build profile picture widget for post owner
  Widget _buildPostOwnerProfilePicture(
      String photoUrl, _MessagingColorSet colors) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    final isVideo = !isDefault && _isVideoFile(photoUrl);

    if (isDefault) {
      return CircleAvatar(
        radius: 16,
        backgroundColor: colors.otherUserMessageColor,
        child: Icon(
          Icons.account_circle,
          size: 32,
          color: colors.iconColor,
        ),
      );
    }

    if (isVideo) {
      // Initialize video controller if needed
      _initializeVideoController(photoUrl);
      final controller = _getVideoController(photoUrl);
      final isInitialized = _isVideoControllerInitialized(photoUrl);

      if (controller != null && isInitialized) {
        return ClipOval(
          child: SizedBox(
            width: 32,
            height: 32,
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
      } else {
        return Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.otherUserMessageColor,
          ),
          child: Center(
            child: CircularProgressIndicator(
              color: colors.progressIndicatorColor,
              strokeWidth: 2.0,
            ),
          ),
        );
      }
    }

    // Regular image
    return CircleAvatar(
      radius: 16,
      backgroundColor: colors.otherUserMessageColor,
      backgroundImage:
          photoUrl.startsWith('http') ? NetworkImage(photoUrl) : null,
      child: !photoUrl.startsWith('http')
          ? Icon(
              Icons.account_circle,
              size: 32,
              color: colors.iconColor,
            )
          : null,
    );
  }

  Future<bool> _checkIfPostExists(String postId) async {
    try {
      final response =
          await _supabase.from('posts').select().eq('postId', postId);

      return response != null && response.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _checkPostStatus(
      Map<String, dynamic> postShare) async {
    try {
      final bool postExists = await _checkIfPostExists(postShare['postId']);
      final bool isBlocked = await _blockMethods.isMutuallyBlocked(
        currentUserId!,
        postShare['postOwnerId'] ?? '',
      );

      return {
        'exists': postExists,
        'isBlocked': isBlocked,
        'postData': postShare,
      };
    } catch (e) {
      return {
        'exists': false,
        'isBlocked': false,
        'postData': postShare,
      };
    }
  }

  Widget _buildDeletedPostMessage(_MessagingColorSet colors) {
    return Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.otherUserMessageColor.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colors.textColor.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.delete_outline,
              color: colors.textColor.withOpacity(0.6),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Original post deleted',
                    style: TextStyle(
                      color: colors.textColor.withOpacity(0.8),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'The shared post is no longer available',
                    style: TextStyle(
                      color: colors.textColor.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ));
  }

  Widget _buildPostContent(Map<String, dynamic> postShare,
      Map<String, dynamic> data, _MessagingColorSet colors) {
    final postImageUrl = postShare['postImageUrl'] ?? '';
    final postOwnerPhotoUrl = postShare['postOwnerPhotoUrl'] ?? '';
    final isVideo = _isVideoFile(postImageUrl);

    if (isVideo) {
      _initializeVideoController(postImageUrl);
    }

    return GestureDetector(
      onTap: () => _navigateToPost(postShare),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          0,
          data['isReply'] == true ? 4 : 12,
          0,
          12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  _buildPostOwnerProfilePicture(postOwnerPhotoUrl, colors),
                  const SizedBox(width: 8),
                  VerifiedUsernameWidget(
                    username: postShare['postOwnerUsername'] ?? 'Unknown User',
                    uid: postShare['postOwnerId'] ?? '',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: colors.textColor),
                  ),
                ],
              ),
            ),
            if (postImageUrl.isNotEmpty)
              isVideo
                  ? _buildVideoPlayer(postImageUrl, colors)
                  : Image.network(
                      postImageUrl,
                      height: 150,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        height: 150,
                        color: Colors.grey,
                        child: Center(
                            child: Icon(Icons.error, color: colors.iconColor)),
                      ),
                    )
            else
              Container(
                height: 150,
                color: colors.otherUserMessageColor,
                child: Center(
                  child: Icon(Icons.broken_image, color: colors.iconColor),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(postShare['postCaption'] ?? '',
                      style: TextStyle(color: colors.textColor)),
                  const SizedBox(height: 4),
                  Text(
                    _formatTimestamp(data['timestamp']),
                    style: TextStyle(
                        color: colors.textColor.withOpacity(0.6), fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    if (_controller.text.isEmpty || _isMutuallyBlocked || currentUserId == null)
      return;

    final messageText = _controller.text.trim();

    // Capture the reply message before clearing it
    final capturedReplyMessage = _replyingToMessage;

    // Determine if the original message was from the current user
    final isOriginalFromSelf = capturedReplyMessage != null &&
        capturedReplyMessage['repliedMessageSenderIsSelf'] == true;

    // Create optimistic message with all reply data
    final optimisticMessage = {
      'id': 'optimistic_${DateTime.now().millisecondsSinceEpoch}',
      'message': messageText,
      'senderId': currentUserId!,
      'receiverId': widget.recipientUid,
      'timestamp': DateTime.now(),
      'isRead': false,
      'delivered': false,
      'type': 'text',
      'isOptimistic': true,
      'isReply': capturedReplyMessage != null,
      'repliedToMessageId': capturedReplyMessage?['id'],
      'repliedMessagePreview': capturedReplyMessage != null
          ? _getMessagePreview(capturedReplyMessage)
          : null,
      'repliedMessageSender': capturedReplyMessage != null
          ? (isOriginalFromSelf ? 'You' : 'Them')
          : null,
      'repliedMessageSenderIsSelf': isOriginalFromSelf,
      'repliedMessageType': capturedReplyMessage?['type'] ?? 'text',
    };

    setState(() {
      _optimisticMessages.add(optimisticMessage);
      _controller.clear();

      if (_isReplying) {
        _cancelReply();
      }
    });

    _focusNode.requestFocus();
    _scrollToBottom(immediate: true);

    try {
      final chatId = await SupabaseMessagesMethods().getOrCreateChat(
        currentUserId!,
        widget.recipientUid,
      );

      if (chatId.startsWith('Error') || chatId.isEmpty) {
        throw Exception('Failed to get chat');
      }

      final res = await SupabaseMessagesMethods().sendMessageWithReply(
        chatId: chatId,
        senderId: currentUserId!,
        receiverId: widget.recipientUid,
        message: messageText,
        repliedToMessage: capturedReplyMessage,
      );

      if (res != 'success') {
        if (mounted) {
          setState(() {
            _optimisticMessages
                .removeWhere((msg) => msg['id'] == optimisticMessage['id']);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to send message'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        // Instead of refreshing immediately, wait a moment for the server
        Future.delayed(Duration(seconds: 2), () {
          if (mounted) {
            _refreshMessages();
          }
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom(immediate: false);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _optimisticMessages
              .removeWhere((msg) => msg['id'] == optimisticMessage['id']);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send message'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _refreshMessages() async {
    if (chatId == null) return;

    try {
      final refreshedMessages =
          await SupabaseMessagesMethods().getMessagesPaginated(
        chatId!,
        page: 0,
        limit:
            (_currentPage + 1) * _messagesPerPage, // Get all pages we've loaded
      );

      // Process messages to ensure proper structure
      final processedMessages = refreshedMessages.map((msg) {
        return _processServerMessage(msg);
      }).toList();

      if (processedMessages.isNotEmpty) {
        final oldest = _parseTimestamp(processedMessages.last['timestamp']);
        if (oldest != null) {
          _oldestMessageTimestamp = oldest;
        }
      }

      setState(() {
        _cachedMessages = processedMessages;
        _hasMoreMessages =
            processedMessages.length >= ((_currentPage + 1) * _messagesPerPage);
      });
    } catch (e) {}
  }

  bool _areTimestampsClose(DateTime? timestamp1, DateTime? timestamp2) {
    if (timestamp1 == null || timestamp2 == null) return false;
    final difference = timestamp1.difference(timestamp2).abs();
    return difference.inSeconds < 60;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return WillPopScope(
      onWillPop: () async {
        // Pause videos before navigating away
        _pauseAllVideos();
        _pauseRecipientProfileVideo();
        Navigator.pop(context, true);
        return false;
      },
      child: Scaffold(
        backgroundColor: colors.backgroundColor,
        appBar: AppBar(
          iconTheme: IconThemeData(color: colors.appBarIconColor),
          backgroundColor: colors.appBarBackgroundColor,
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: colors.appBarIconColor),
            onPressed: () {
              // Pause videos before navigating away
              _pauseAllVideos();
              _pauseRecipientProfileVideo();
              Navigator.pop(context, true);
            },
          ),
          title: _buildAppBarTitle(colors),
          elevation: 0,
        ),
        body: Stack(
          children: [
            if (!_isMutuallyBlocked)
              _FallingNumbersBackground(
                animationController: _animationController,
                onInit: (screenHeight) {
                  _screenHeight = screenHeight;
                  _initializeParticles(colors);
                },
                onUpdate: _updateParticles,
                particles: _particles,
              ),
            _isMutuallyBlocked
                ? _buildBlockedUI(colors)
                : _buildChatBody(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildBlockedUI(_MessagingColorSet colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.block, size: 60, color: colors.iconColor),
          const SizedBox(height: 20),
          Text(
            'Messages with ${widget.recipientUsername} are unavailable',
            style: TextStyle(color: colors.textColor, fontSize: 16),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.buttonColor,
              foregroundColor: colors.buttonTextColor,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Back to Messages'),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBarTitle(_MessagingColorSet colors) {
    return GestureDetector(
        onTap: () {
          // Pause videos before navigating to profile
          _pauseAllVideos();
          _pauseRecipientProfileVideo();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ProfileScreen(uid: widget.recipientUid),
            ),
          );
        },
        child: Row(
          children: [
            _buildRecipientProfilePicture(colors),
            const SizedBox(width: 10),
            VerifiedUsernameWidget(
              username: widget.recipientUsername,
              uid: widget.recipientUid,
              style: TextStyle(color: colors.textColor),
            ),
          ],
        ));
  }

  // ADDED: Build recipient profile picture widget
  Widget _buildRecipientProfilePicture(_MessagingColorSet colors) {
    final isDefault = widget.recipientPhotoUrl.isEmpty ||
        widget.recipientPhotoUrl == 'default';
    final isVideo = !isDefault && _isProfileVideo(widget.recipientPhotoUrl);

    if (isDefault) {
      return CircleAvatar(
        radius: 21,
        backgroundColor: colors.otherUserMessageColor,
        child: Icon(
          Icons.account_circle,
          size: 42,
          color: colors.iconColor,
        ),
      );
    }

    if (isVideo) {
      return _buildRecipientProfileVideoPlayer(colors);
    }

    // Regular image
    return CircleAvatar(
      radius: 21,
      backgroundColor: colors.otherUserMessageColor,
      backgroundImage: NetworkImage(widget.recipientPhotoUrl),
    );
  }

  Widget _buildChatBody(_MessagingColorSet colors) {
    return Column(
      children: [
        Expanded(child: _buildMessageList(colors)),
        _buildMessageInput(colors),
      ],
    );
  }

  Widget _buildReplyPreview(_MessagingColorSet colors) {
    if (!_isReplying || _replyingToMessage == null) {
      return const SizedBox.shrink();
    }

    // Determine if we're replying to ourselves or the other user
    final isReplyingToSelf =
        _replyingToMessage!['repliedMessageSenderIsSelf'] == true;
    final targetUsername =
        isReplyingToSelf ? 'yourself' : widget.recipientUsername;

    return Container(
      key: ValueKey('reply_preview_${_replyingToMessage!['id']}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.otherUserMessageColor.withOpacity(0.2),
        border: Border(
          left: BorderSide(
            color: colors.currentUserMessageColor,
            width: 4,
          ),
          bottom: BorderSide(
            color: colors.otherUserMessageColor.withOpacity(0.3),
            width: 1.0,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.reply,
                      size: 16,
                      color: colors.textColor.withOpacity(0.7),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Replying to $targetUsername',
                      style: TextStyle(
                        color: colors.textColor.withOpacity(0.7),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.only(left: 22),
                  child: Text(
                    _getMessagePreview(_replyingToMessage!),
                    style: TextStyle(
                      color: colors.textColor.withOpacity(0.9),
                      fontSize: 13,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: colors.iconColor),
            onPressed: () {
              _cancelReply();
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 32,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagePlaceholderSkeleton(_MessagingColorSet colors) {
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        _buildReceivedMessagePlaceholder(colors),
        const SizedBox(height: 16),
        _buildSentMessagePlaceholder(colors),
        const SizedBox(height: 16),
        _buildReceivedMessagePlaceholder(colors),
        const SizedBox(height: 16),
        _buildSentMessagePlaceholder(colors),
        const SizedBox(height: 16),
        _buildReceivedMessagePlaceholder(colors),
      ],
    );
  }

  Widget _buildReceivedMessagePlaceholder(_MessagingColorSet colors) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: colors.otherUserMessageColor.withOpacity(0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 14,
                width: 120,
                decoration: BoxDecoration(
                  color: colors.otherUserMessageColor.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 12,
                width: 180,
                decoration: BoxDecoration(
                  color: colors.otherUserMessageColor.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 10,
                width: 80,
                decoration: BoxDecoration(
                  color: colors.otherUserMessageColor.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSentMessagePlaceholder(_MessagingColorSet colors) {
    return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: colors.currentUserMessageColor.withOpacity(0.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  height: 14,
                  width: 100,
                  decoration: BoxDecoration(
                    color: colors.currentUserMessageColor.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 12,
                  width: 160,
                  decoration: BoxDecoration(
                    color: colors.currentUserMessageColor.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: 60,
                  decoration: BoxDecoration(
                    color: colors.currentUserMessageColor.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ));
  }

  Widget _buildEmptyStatePlaceholder(_MessagingColorSet colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 50, color: colors.iconColor),
          const SizedBox(height: 16),
          Text(
            'No messages yet',
            style: TextStyle(color: colors.textColor),
          ),
          const SizedBox(height: 8),
          Text(
            'Send the first message!',
            style: TextStyle(
              color: colors.textColor.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(_MessagingColorSet colors) {
    if (_isInitializing) {
      return _buildMessagePlaceholderSkeleton(colors);
    }

    if (currentUserId == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 50, color: colors.iconColor),
            const SizedBox(height: 16),
            Text(
              'Please sign in to view messages',
              style: TextStyle(color: colors.textColor),
            ),
          ],
        ),
      );
    }

    if (chatId == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 50, color: colors.iconColor),
            const SizedBox(height: 16),
            Text(
              'Failed to load chat',
              style: TextStyle(color: colors.textColor),
            ),
          ],
        ),
      );
    }

    // Combine cached messages with optimistic messages
    List<Map<String, dynamic>> allMessages = [..._cachedMessages];

    // Remove optimistic messages that have been confirmed by server
    final List<Map<String, dynamic>> remainingOptimisticMessages = [];

    for (final optimisticMsg in _optimisticMessages) {
      final isConfirmed = _cachedMessages.any((serverMsg) {
        return serverMsg['message'] == optimisticMsg['message'] &&
            serverMsg['senderId'] == optimisticMsg['senderId'] &&
            _areTimestampsClose(_parseTimestamp(serverMsg['timestamp']),
                optimisticMsg['timestamp']);
      });

      if (!isConfirmed) {
        remainingOptimisticMessages.add(optimisticMsg);
      }
    }

    // Update optimistic messages list
    if (remainingOptimisticMessages.length != _optimisticMessages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _optimisticMessages.clear();
            _optimisticMessages.addAll(remainingOptimisticMessages);
          });
        }
      });
    }

    // Add remaining optimistic messages
    allMessages.addAll(remainingOptimisticMessages);

    // Sort all messages by timestamp
    allMessages.sort((a, b) {
      try {
        DateTime? timeA = _parseTimestamp(a['timestamp']);
        DateTime? timeB = _parseTimestamp(b['timestamp']);
        if (timeA == null || timeB == null) return 0;
        return timeA.compareTo(timeB);
      } catch (e) {
        return 0;
      }
    });

    if (allMessages.isNotEmpty && !_hasMarkedAsRead) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _markMessagesAsRead();
      });
    }

    if (allMessages.isNotEmpty && !_hasInitialScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients && mounted) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          setState(() => _hasInitialScroll = true);
        }
      });
    }

    final shouldShowEmptyState =
        allMessages.isEmpty && _optimisticMessages.isEmpty;

    if (shouldShowEmptyState) {
      return _buildEmptyStatePlaceholder(colors);
    }

    return Column(
      children: [
        // Load more indicator at top (only shown when loading)
        if (_isLoadingMore)
          Container(
            padding: EdgeInsets.all(8),
            child: Center(
              child: CircularProgressIndicator(
                color: colors.progressIndicatorColor,
              ),
            ),
          ),

        // Messages list
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            reverse: false,
            itemCount: allMessages.length,
            itemBuilder: (context, index) {
              final message = allMessages[index];
              return _buildMessageBubble(message, colors);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTextMessage(
      Map<String, dynamic> data, _MessagingColorSet colors) {
    final isReply = data['isReply'] == true;
    final isMe = data['senderId'] == currentUserId;
    final messageText = data['message'] ?? '';
    final isOptimistic = data['isOptimistic'] == true;

    return Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        padding: EdgeInsets.fromLTRB(
          12,
          isReply ? 8 : 12,
          12,
          12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              messageText,
              style: TextStyle(color: colors.textColor),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTimestamp(data['timestamp']),
              style: TextStyle(
                  color: colors.textColor.withOpacity(0.6), fontSize: 10),
            ),
          ],
        ));
  }

  Widget _buildMessageBubble(
      Map<String, dynamic> message, _MessagingColorSet colors) {
    final isMe = message['senderId'] == currentUserId;
    final isPost = message['type'] == 'post';
    final isReply = message['isReply'] == true;
    final messageId = message['id'].toString();
    final swipeOffset = _swipeOffsets[messageId] ?? 0;
    final isSwiping = _isSwiping[messageId] ?? false;
    final isOptimistic = message['isOptimistic'] == true;

    return GestureDetector(
      onLongPress: () => _startReply(message),
      onHorizontalDragStart: (details) => _handleSwipeStart(messageId, details),
      onHorizontalDragUpdate: (details) =>
          _handleSwipeUpdate(messageId, details),
      onHorizontalDragEnd: (details) =>
          _handleSwipeEnd(messageId, details, message),
      onTap: () => _resetSwipe(messageId),
      child: Stack(
        children: [
          if (swipeOffset > 0 && !isMe)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  child: Transform.translate(
                    offset: Offset(-(30 - (swipeOffset / 2)), 0),
                    child: Opacity(
                      opacity:
                          (swipeOffset / _maxSwipeDistance).clamp(0.0, 1.0),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color:
                              colors.currentUserMessageColor.withOpacity(0.3),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.reply,
                          color: colors.iconColor,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(swipeOffset, 0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: Row(
                mainAxisAlignment:
                    isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75,
                      ),
                      decoration: BoxDecoration(
                        color: isMe
                            ? colors.currentUserMessageColor
                            : colors.otherUserMessageColor,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: isSwiping
                            ? [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : [],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: isPost || isReply
                            ? CrossAxisAlignment.stretch
                            : (isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start),
                        children: [
                          if (isReply)
                            _buildReplyIndicator(message, colors, isMe),
                          isPost
                              ? _buildPostMessage(message, colors)
                              : _buildTextMessage(message, colors),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyIndicator(
      Map<String, dynamic> message, _MessagingColorSet colors, bool isMe) {
    final repliedMessagePreview =
        message['repliedMessagePreview'] ?? 'Original message';
    final repliedMessageSender = message['repliedMessageSender'] ?? 'Them';
    final isOriginalFromSelf = message['repliedMessageSenderIsSelf'] == true;

    // Determine the reply text based on who sent the reply and who they're replying to
    String replyText;

    if (isMe) {
      // Current user is replying
      if (isOriginalFromSelf) {
        // Replying to own message
        replyText = 'You replied to yourself';
      } else {
        // Replying to other user's message
        replyText = 'You replied to ${widget.recipientUsername}';
      }
    } else {
      // Other user is replying
      if (isOriginalFromSelf) {
        // Other user is replying to their own message
        replyText = '${widget.recipientUsername} replied to themselves';
      } else {
        // Other user is replying to current user's message
        replyText = '${widget.recipientUsername} replied to you';
      }
    }

    return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: colors.otherUserMessageColor.withOpacity(isMe ? 0.2 : 0.3),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
          border: Border(
            left: BorderSide(
              color: isMe ? colors.currentUserMessageColor : colors.iconColor,
              width: 4,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.reply,
                  size: 14,
                  color: colors.textColor.withOpacity(0.7),
                ),
                const SizedBox(width: 6),
                Text(
                  replyText,
                  style: TextStyle(
                    color: colors.textColor.withOpacity(0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.only(left: 22),
              child: Text(
                repliedMessagePreview,
                style: TextStyle(
                  color: colors.textColor.withOpacity(0.9),
                  fontSize: 12,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ));
  }

  Widget _buildPostMessage(
      Map<String, dynamic> data, _MessagingColorSet colors) {
    final postShare = data['postShare'] as Map<String, dynamic>?;

    if (postShare == null) {
      return BlockedContentMessage(
          message: 'Post data unavailable', colors: colors);
    }

    return FutureBuilder<Map<String, dynamic>>(
      future: _checkPostStatus(postShare),
      builder: (context, statusSnapshot) {
        if (statusSnapshot.connectionState == ConnectionState.waiting &&
            !statusSnapshot.hasData) {
          return Container(
            padding: EdgeInsets.fromLTRB(
              12,
              data['isReply'] == true ? 4 : 12,
              12,
              12,
            ),
            child: Center(
              child: CircularProgressIndicator(
                color: colors.progressIndicatorColor,
                strokeWidth: 2,
              ),
            ),
          );
        }

        final status = statusSnapshot.data ??
            {'exists': false, 'isBlocked': false, 'postData': postShare};

        final bool postExists = status['exists'] ?? false;
        final bool isBlocked = status['isBlocked'] ?? false;

        if (!postExists) {
          return _buildDeletedPostMessage(colors);
        }

        if (isBlocked) {
          return BlockedContentMessage(colors: colors);
        }

        return _buildPostContent(postShare, data, colors);
      },
    );
  }

  void _navigateToPost(Map<String, dynamic> postShare) {
    // Pause all videos before navigation
    _pauseAllVideos();
    _pauseRecipientProfileVideo();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImageViewScreen(
          imageUrl: postShare['postImageUrl'],
          postId: postShare['postId'],
          description: postShare['postCaption'] ?? '',
          userId: postShare['postOwnerId'],
          username: postShare['postOwnerUsername'] ?? 'Unknown',
          profImage: postShare['postOwnerPhotoUrl'] ?? '',
          datePublished: postShare['datePublished'],
        ),
      ),
    );
  }

  Widget _buildMessageInput(_MessagingColorSet colors) {
    return Column(
      children: [
        _buildReplyPreview(colors),
        Container(
          key: ValueKey('message_input_${_isReplying}'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          decoration: BoxDecoration(
            color: colors.backgroundColor,
            border: Border(
              top: BorderSide(
                color: colors.otherUserMessageColor.withOpacity(0.5),
                width: 1.0,
              ),
            ),
          ),
          child: Row(
            children: [
              if (_isReplying)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: IconButton(
                    icon: Icon(Icons.close, color: colors.iconColor, size: 20),
                    onPressed: () {
                      _cancelReply();
                    },
                    tooltip: 'Cancel reply',
                    padding: const EdgeInsets.all(6),
                  ),
                ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.otherUserMessageColor,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          enabled: !_isMutuallyBlocked && currentUserId != null,
                          style: TextStyle(color: colors.textColor),
                          decoration: InputDecoration(
                            hintText: _isMutuallyBlocked
                                ? 'Messaging is blocked'
                                : currentUserId == null
                                    ? 'Please sign in'
                                    : _isReplying
                                        ? 'Type your reply...'
                                        : 'Type a message...',
                            hintStyle: TextStyle(
                                color: colors.textColor.withOpacity(0.6)),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            isDense: true,
                          ),
                          minLines: 1,
                          maxLines: 3,
                          onTap: () {
                            Future.delayed(const Duration(milliseconds: 250),
                                () {
                              _scrollToBottom(immediate: true);
                            });
                          },
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: colors.buttonColor,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(Icons.send, color: colors.iconColor),
                  onPressed: _isMutuallyBlocked || currentUserId == null
                      ? null
                      : _sendMessage,
                  padding: const EdgeInsets.all(12),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) return 'Just now';
    try {
      final localTime = timestamp.toLocal();
      final now = DateTime.now();
      final difference = now.difference(localTime);

      if (difference.inSeconds < 60) {
        return 'Now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d';
      } else {
        return '${localTime.day}/${localTime.month}';
      }
    } catch (e) {
      return 'Now';
    }
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
            particles: widget.particles,
            repaint: widget.animationController,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class BlockedContentMessage extends StatelessWidget {
  final String message;
  final _MessagingColorSet colors;

  const BlockedContentMessage({
    super.key,
    this.message = 'This content is unavailable due to blocking',
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.block, color: Colors.red[400], size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: colors.textColor.withOpacity(0.6),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ));
  }
}
