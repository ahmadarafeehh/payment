import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/providers/user_provider.dart';

class _BlockedProfileColorSet {
  final Color backgroundColor;
  final Color textColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;
  final Color progressIndicatorColor;
  final Color avatarBackgroundColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color dividerColor;
  final Color skeletonColor;
  final Color errorTextColor;

  _BlockedProfileColorSet({
    required this.backgroundColor,
    required this.textColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
    required this.progressIndicatorColor,
    required this.avatarBackgroundColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.dividerColor,
    required this.skeletonColor,
    required this.errorTextColor,
  });
}

class _BlockedProfileDarkColors extends _BlockedProfileColorSet {
  _BlockedProfileDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          textColor: const Color(0xFFd9d9d9),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          avatarBackgroundColor: const Color(0xFF333333),
          buttonBackgroundColor: const Color(0xFF333333),
          buttonTextColor: const Color(0xFFd9d9d9),
          dividerColor: const Color(0xFF333333),
          skeletonColor: const Color(0xFF333333),
          errorTextColor: Colors.grey,
        );
}

class _BlockedProfileLightColors extends _BlockedProfileColorSet {
  _BlockedProfileLightColors()
      : super(
          backgroundColor: Colors.white,
          textColor: Colors.black,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
          progressIndicatorColor: Colors.grey,
          avatarBackgroundColor: Colors.grey,
          buttonBackgroundColor: Colors.grey,
          buttonTextColor: Colors.black,
          dividerColor: Colors.grey,
          skeletonColor: Colors.grey,
          errorTextColor: Colors.grey,
        );
}

class BlockedProfileScreen extends StatefulWidget {
  final String uid;
  final bool isBlocker;
  final bool performBlock;
  final String? currentUserId;
  final bool isTestUser;

  const BlockedProfileScreen({
    Key? key,
    required this.uid,
    required this.isBlocker,
    this.performBlock = false,
    this.currentUserId,
    required this.isTestUser,
  }) : super(key: key);

  @override
  State<BlockedProfileScreen> createState() => _BlockedProfileScreenState();
}

class _BlockedProfileScreenState extends State<BlockedProfileScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabaseBlockMethods _blockMethods = SupabaseBlockMethods();

  // When performBlock is true we show the screen immediately,
  // so start with _isLoading = false in that case.
  bool get _startLoaded => widget.performBlock;

  late bool _isLoading;
  bool _isBlocker = false;
  bool _isTestUser = false;
  String _currentUserId = '';

  static const int _postLen = 0;
  static const int _followers = 0;
  static const int _following = 0;

  static const Color _igBlue = Color(0xFF0095F6);

  _BlockedProfileColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? _BlockedProfileDarkColors()
        : _BlockedProfileLightColors();
  }

  Future<void> _logError(
    String operationType,
    dynamic error,
    StackTrace? stackTrace, {
    String? targetUserId,
  }) async {
    try {
      await _supabase.from('messages_error').insert({
        'user_id': _currentUserId.isNotEmpty ? _currentUserId : null,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': stackTrace?.toString(),
        'additional_data': targetUserId != null
            ? {'target_user_id': targetUserId}
            : null,
      });
    } catch (_) {
      // Avoid infinite loops – silently ignore logging failures
    }
  }

  @override
  void initState() {
    super.initState();
    _isBlocker = widget.isBlocker;
    _isTestUser = widget.isTestUser;
    // If performBlock is true, show content immediately (optimistic).
    // If false (e.g. navigated here because block already exists),
    // wait for the check before showing.
    _isLoading = !widget.performBlock;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_currentUserId.isEmpty) {
      _resolveCurrentUserId();
    }
  }

  void _resolveCurrentUserId() {
    if (widget.currentUserId != null && widget.currentUserId!.isNotEmpty) {
      _currentUserId = widget.currentUserId!;
      _initScreen();
      _fetchOwnTestStatus();
      return;
    }
    final firebaseUser = FirebaseAuth.instance.currentUser?.uid;
    if (firebaseUser != null && firebaseUser.isNotEmpty) {
      _currentUserId = firebaseUser;
      _initScreen();
      _fetchOwnTestStatus();
      return;
    }
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    final supabaseUid = userProvider.supabaseUid;
    if (supabaseUid != null && supabaseUid.isNotEmpty) {
      _currentUserId = supabaseUid;
      _initScreen();
      _fetchOwnTestStatus();
      return;
    }
    // Could not resolve — just show the screen anyway
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _fetchOwnTestStatus() async {
    if (_currentUserId.isEmpty) return;
    if (_isTestUser) return;
    try {
      final response = await _supabase
          .from('users')
          .select('test')
          .eq('uid', _currentUserId)
          .maybeSingle();
      if (mounted && response != null) {
        final dbTest = response['test'] ?? false;
        if (dbTest != _isTestUser) {
          setState(() => _isTestUser = dbTest);
        }
      }
    } catch (e, stackTrace) {
      _logError('fetch_test_status', e, stackTrace);
    }
  }

  Future<void> _initScreen() async {
    if (_currentUserId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    if (widget.performBlock) {
      // Fire-and-forget — screen is already visible, block runs in background
      _blockMethods
          .blockUser(
            currentUserId: _currentUserId,
            targetUserId: widget.uid,
          )
          .catchError((e) =>
              _logError('block_user', e, null, targetUserId: widget.uid));

      // We already know the caller is the blocker, no need to query
      if (mounted) setState(() => _isBlocker = true);
      // _isLoading was already false, nothing else to do
      return;
    }

    // performBlock == false: came here because a block already exists,
    // verify who the initiator is before showing the screen.
    try {
      final isBlocker = await SupabaseBlockMethods().isBlockInitiator(
        currentUserId: _currentUserId,
        targetUserId: widget.uid,
      );
      if (mounted) setState(() => _isBlocker = isBlocker);
    } catch (e, stackTrace) {
      _logError('check_block_initiator', e, stackTrace,
          targetUserId: widget.uid);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  Future<void> _unblockUser() async {
    if (_currentUserId.isEmpty) {
      showSnackBar(context, "User not authenticated");
      return;
    }
    try {
      await _blockMethods.unblockUser(
        currentUserId: _currentUserId,
        targetUserId: widget.uid,
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ProfileScreen(uid: widget.uid),
          ),
        );
        showSnackBar(context, "User unblocked");
      }
    } catch (e, stackTrace) {
      _logError('unblock_user', e, stackTrace, targetUserId: widget.uid);
      if (mounted) showSnackBar(context, "Error: ${e.toString()}");
    }
  }

  Future<void> _reportUser() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final colors = _getColors(themeProvider);

    final reasons = [
      'Spam',
      'Harassment or bullying',
      'Inappropriate content',
      'Fake account',
      'Other',
    ];
    String? selectedReason;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: colors.appBarBackgroundColor,
          title: Text('Report', style: TextStyle(color: colors.textColor)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: reasons.map((reason) {
              return RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: reason,
                groupValue: selectedReason,
                activeColor: colors.textColor,
                title: Text(reason,
                    style: TextStyle(color: colors.textColor, fontSize: 14)),
                onChanged: (val) => setDialogState(() => selectedReason = val),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: colors.textColor)),
            ),
            TextButton(
              onPressed: selectedReason == null
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      try {
                        await _supabase.from('reports').insert({
                          'reporter_id': _currentUserId,
                          'reported_id': widget.uid,
                          'reason': selectedReason,
                          'created_at':
                              DateTime.now().toUtc().toIso8601String(),
                        });
                        if (mounted) showSnackBar(context, 'Report submitted');
                      } catch (e, stackTrace) {
                        _logError('report_user', e, stackTrace,
                            targetUserId: widget.uid);
                        if (mounted) {
                          showSnackBar(context, 'Failed to submit report');
                        }
                      }
                    },
              style: TextButton.styleFrom(
                backgroundColor: selectedReason != null
                    ? Colors.red[900]
                    : Colors.red[900]!.withOpacity(0.3),
              ),
              child: Text('Submit', style: TextStyle(color: Colors.red[100])),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: colors.backgroundColor,
        body: Center(
          child:
              CircularProgressIndicator(color: colors.progressIndicatorColor),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.appBarIconColor),
        backgroundColor: colors.appBarBackgroundColor,
        elevation: 0,
        centerTitle: true,
        title: Text(
          'Reactly User',
          style: TextStyle(
            color: colors.textColor,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        leading: BackButton(color: colors.appBarIconColor),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: colors.appBarIconColor),
            color: colors.appBarBackgroundColor,
            onSelected: (value) {
              if (value == 'unblock') {
                _unblockUser();
              } else if (value == 'report') {
                _reportUser();
              }
            },
            itemBuilder: (_) => [
              if (_isBlocker)
                PopupMenuItem(
                  value: 'unblock',
                  child: Row(
                    children: [
                      Icon(Icons.lock_open, color: colors.textColor, size: 20),
                      const SizedBox(width: 8),
                      Text('Unblock User',
                          style: TextStyle(color: colors.textColor)),
                    ],
                  ),
                ),
              PopupMenuItem(
                value: 'report',
                child: Row(
                  children: [
                    Icon(Icons.flag, color: Colors.red[400], size: 20),
                    const SizedBox(width: 8),
                    Text('Report', style: TextStyle(color: Colors.red[400])),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildProfileHeader(colors),
                  const SizedBox(height: 20),
                  _buildBioSection(colors),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _buildTabBar(colors),
            const SizedBox(height: 40),
            _buildRestrictedContent(colors),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section builders
  // ---------------------------------------------------------------------------
  Widget _buildProfileHeader(_BlockedProfileColorSet colors) {
    return Column(
      children: [
        CircleAvatar(
          radius: 45,
          backgroundColor: colors.avatarBackgroundColor,
          child: Icon(
            Icons.account_circle,
            size: 90,
            color: colors.iconColor,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildMetric(_postLen, "Posts", colors),
                        _buildMetric(_followers, "Followers", colors),
                        _buildMetric(_following, "Following", colors),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: SizedBox(
                        width: 140,
                        height: 40,
                        child: ElevatedButton(
                          onPressed: _isBlocker ? _unblockUser : null,
                          style: _isTestUser
                              ? ElevatedButton.styleFrom(
                                  backgroundColor: _igBlue,
                                  disabledBackgroundColor:
                                      _igBlue.withOpacity(0.4),
                                  foregroundColor: Colors.white,
                                  disabledForegroundColor:
                                      Colors.white.withOpacity(0.6),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                )
                              : ElevatedButton.styleFrom(
                                  backgroundColor: colors.buttonBackgroundColor,
                                  disabledBackgroundColor: colors
                                      .buttonBackgroundColor
                                      .withOpacity(0.4),
                                  foregroundColor: colors.buttonTextColor,
                                  disabledForegroundColor:
                                      colors.buttonTextColor.withOpacity(0.6),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                          child: Text(
                            'Unblock',
                            style: TextStyle(
                              color: _isTestUser
                                  ? Colors.white
                                  : colors.buttonTextColor,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetric(int value, String label, _BlockedProfileColorSet colors) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value.toString(),
          style: TextStyle(
            fontSize: 13.6,
            fontWeight: FontWeight.bold,
            color: colors.textColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: colors.textColor,
          ),
        ),
      ],
    );
  }

  Widget _buildBioSection(_BlockedProfileColorSet colors) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        'Reactly User',
        style: TextStyle(
          color: colors.textColor,
          fontWeight: FontWeight.bold,
          fontSize: 16,
        ),
      ),
    );
  }

  Widget _buildTabBar(_BlockedProfileColorSet colors) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.textColor, width: 2),
              ),
            ),
            child: Column(
              children: [
                Icon(Icons.grid_on, color: colors.textColor),
                const SizedBox(height: 4),
                Text(
                  'POSTS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: colors.textColor,
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.dividerColor, width: 2),
              ),
            ),
            child: Column(
              children: [
                Icon(Icons.collections,
                    color: colors.textColor.withOpacity(0.5)),
                const SizedBox(height: 4),
                Text(
                  'GALLERIES',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: colors.textColor.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRestrictedContent(_BlockedProfileColorSet colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          Icon(Icons.lock_outline, size: 60, color: colors.errorTextColor),
          const SizedBox(height: 16),
          Text(
            'Content not available',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.textColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'This content is unavailable.',
            style: TextStyle(
              fontSize: 14,
              color: colors.textColor.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
