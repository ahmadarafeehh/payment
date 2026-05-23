import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/utils/theme_provider.dart'; // Add this import
import 'package:provider/provider.dart'; // Add this import

// Define color schemes for both themes at top level
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
  final Color containerBackgroundColor;
  final Color blockIconColor;

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
    required this.containerBackgroundColor,
    required this.blockIconColor,
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
          buttonBackgroundColor: const Color(0xFF444444),
          buttonTextColor: const Color(0xFFd9d9d9),
          containerBackgroundColor: const Color(0xFF333333),
          blockIconColor: Colors.red[400]!,
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
          progressIndicatorColor: Colors.grey[700]!,
          avatarBackgroundColor: Colors.grey[300]!,
          buttonBackgroundColor: Colors.grey[300]!,
          buttonTextColor: Colors.black,
          containerBackgroundColor: Colors.grey[200]!,
          blockIconColor: Colors.red[400]!,
        );
}

class BlockedProfileScreen extends StatefulWidget {
  final String uid;
  final bool isBlocker;

  const BlockedProfileScreen({
    Key? key,
    required this.uid,
    required this.isBlocker,
  }) : super(key: key);

  @override
  State<BlockedProfileScreen> createState() => _BlockedProfileScreenState();
}

class _BlockedProfileScreenState extends State<BlockedProfileScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabaseBlockMethods _blockMethods = SupabaseBlockMethods();
  bool _isLoading = true;
  Map<String, dynamic> userData = {};
  bool _isBlocker = false;
  bool _isBlockedByThem = false;
  int postLen = 0;
  int followers = 0;
  int following = 0;

  // Helper method to get the appropriate color scheme
  _BlockedProfileColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode
        ? _BlockedProfileDarkColors()
        : _BlockedProfileLightColors();
  }

  @override
  void initState() {
    super.initState();
    _isBlocker = widget.isBlocker;
    _loadBlockedProfileData();
  }

  Future<void> _loadBlockedProfileData() async {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;

    try {
      final isBlocker = await SupabaseBlockMethods().isBlockInitiator(
        currentUserId: currentUserId,
        targetUserId: widget.uid,
      );

      final isBlockedByThem = await SupabaseBlockMethods().isUserBlocked(
        currentUserId: currentUserId,
        targetUserId: widget.uid,
      );

      setState(() {
        _isBlocker = isBlocker;
        _isBlockedByThem = isBlockedByThem;
      });

      if (!_isBlockedByThem) {
        // Fetch user data from Supabase
        final userResponse = await _supabase
            .from('users')
            .select()
            .eq('uid', widget.uid)
            .single();

        // Fetch posts count from Supabase
        final postsResponse = await _supabase
            .from('posts')
            .select('postId')
            .eq('uid', widget.uid);

        // Fetch followers count from Supabase
        final followersResponse = await _supabase
            .from('user_followers')
            .select('follower_id')
            .eq('user_id', widget.uid);

        // Fetch following count from Supabase
        final followingResponse = await _supabase
            .from('user_following')
            .select('following_id')
            .eq('user_id', widget.uid);

        setState(() {
          userData = userResponse;
          postLen = postsResponse.length;
          followers = followersResponse.length;
          following = followingResponse.length;
        });
      }
    } catch (e) {
      showSnackBar(
          context, "Please try again or contact us at ratedly9@gmail.com");
    }
    setState(() => _isLoading = false);
  }

  Future<void> _unblockUser() async {
    try {
      await _blockMethods.unblockUser(
        currentUserId: FirebaseAuth.instance.currentUser!.uid,
        targetUserId: widget.uid,
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ProfileScreen(uid: widget.uid),
        ),
      );
      showSnackBar(context, "User unblocked");
    } catch (e) {
      showSnackBar(context, "Unblock error: ${e.toString()}");
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (_isLoading) {
      return Scaffold(
        body: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title:
            Text('Blocked Profile', style: TextStyle(color: colors.textColor)),
        backgroundColor: colors.appBarBackgroundColor,
        iconTheme: IconThemeData(color: colors.appBarIconColor),
      ),
      backgroundColor: colors.backgroundColor,
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildProfileHeader(colors),
              const SizedBox(height: 20),
              _buildBlockedContent(colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileHeader(_BlockedProfileColorSet colors) {
    return Stack(
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 21,
              backgroundColor: colors.avatarBackgroundColor,
              backgroundImage: !_isBlockedByThem &&
                      userData['photoUrl'] != null &&
                      userData['photoUrl'].isNotEmpty &&
                      userData['photoUrl'] != "default"
                  ? NetworkImage(userData['photoUrl'])
                  : null,
              child: _isBlockedByThem
                  ? Icon(
                      Icons.block,
                      size: 42,
                      color: colors.blockIconColor,
                    )
                  : (userData['photoUrl'] == null ||
                          userData['photoUrl'].isEmpty ||
                          userData['photoUrl'] == "default"
                      ? Icon(
                          Icons.account_circle,
                          size: 42,
                          color: colors.iconColor,
                        )
                      : null),
            ),
            Expanded(
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildMetric(_isBlockedByThem ? 0 : postLen, "Rate",
                          colors.textColor),
                      _buildMetric(_isBlockedByThem ? 0 : followers, "Voters",
                          colors.textColor),
                      _buildMetric(_isBlockedByThem ? 0 : following,
                          "Followers", colors.textColor),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBlockedContent(_BlockedProfileColorSet colors) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: colors.containerBackgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.block, size: 60, color: colors.iconColor),
          const SizedBox(height: 16),
          Text(
            _isBlocker
                ? "You've blocked this account"
                : "This account has blocked you",
            style: TextStyle(fontSize: 18, color: colors.textColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (_isBlocker)
            ElevatedButton(
              onPressed: _unblockUser,
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.buttonBackgroundColor,
                foregroundColor: colors.buttonTextColor,
              ),
              child: Text("Unblock Account",
                  style: TextStyle(color: colors.buttonTextColor)),
            ),
        ],
      ),
    );
  }

  Widget _buildMetric(int value, String label, Color textColor) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value.toString(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: textColor,
          ),
        ),
      ],
    );
  }
}
