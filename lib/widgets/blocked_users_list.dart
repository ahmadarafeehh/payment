import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/resources/block_firestore_methods.dart';
import 'package:Ratedly/screens/Profile_page/blocked_profile_screen.dart';

class BlockedUsersList extends StatefulWidget {
  final String uid;
  final bool isTestUser;

  const BlockedUsersList({
    Key? key,
    required this.uid,
    required this.isTestUser,
  }) : super(key: key);

  @override
  State<BlockedUsersList> createState() => _BlockedUsersListState();
}

class _BlockedUsersListState extends State<BlockedUsersList> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabaseBlockMethods _blockMethods = SupabaseBlockMethods();

  bool _isLoading = true;
  bool _hasError = false;
  List<String> _blockedUserIds = [];
  final Map<String, Map<String, dynamic>> _userDetailsCache = {};

  @override
  void initState() {
    super.initState();
    _loadBlockedUsers();
  }

  Future<void> _loadBlockedUsers() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final ids = await _blockMethods.getBlockedUsers(widget.uid);
      if (mounted) {
        setState(() {
          _blockedUserIds = ids;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _getUserDetails(String userId) async {
    if (_userDetailsCache.containsKey(userId)) {
      return _userDetailsCache[userId]!;
    }
    try {
      final response = await _supabase
          .from('users')
          .select('username, photoUrl')
          .eq('uid', userId)
          .single();
      _userDetailsCache[userId] = response;
      return response;
    } catch (e) {
      return {};
    }
  }

  Future<void> _unblockUser(String targetUserId) async {
    try {
      await _blockMethods.unblockUser(
        currentUserId: widget.uid,
        targetUserId: targetUserId,
      );
      print('✅ Unblock succeeded for $targetUserId');
      if (mounted) {
        setState(() {
          _blockedUserIds.remove(targetUserId);
          _userDetailsCache.remove(targetUserId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User unblocked successfully')),
        );
      }
    } catch (e) {
      print('❌ Unblock failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to unblock user: ${e.toString()}')),
        );
      }
    }
  }

  void _openBlockedProfile(String blockedUserId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => BlockedProfileScreen(
          uid: blockedUserId,
          isBlocker: true,
          isTestUser: widget.isTestUser,
        ),
      ),
    ).then((_) {
      // Refresh the list when returning from the profile screen
      // in case the user was unblocked from within that screen
      _loadBlockedUsers();
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    final colors = isDarkMode ? _DarkColors() : _LightColors();

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        title: Text('Blocked Users', style: TextStyle(color: colors.textColor)),
        backgroundColor: colors.backgroundColor,
        iconTheme: IconThemeData(color: colors.textColor),
      ),
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(_ColorSet colors) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: colors.textColor),
      );
    }

    if (_hasError) {
      return Center(
        child: Text(
          'Error loading blocked users',
          style: TextStyle(color: colors.textColor),
        ),
      );
    }

    if (_blockedUserIds.isEmpty) {
      return Center(
        child: Text(
          'No blocked users',
          style: TextStyle(color: colors.textColor),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _blockedUserIds.length,
      separatorBuilder: (context, index) =>
          Divider(color: colors.cardColor, height: 20),
      itemBuilder: (context, index) {
        final blockedUserId = _blockedUserIds[index];
        return FutureBuilder<Map<String, dynamic>>(
          future: _getUserDetails(blockedUserId),
          builder: (context, userSnapshot) {
            if (userSnapshot.connectionState == ConnectionState.waiting) {
              return ListTile(
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: colors.cardColor,
                  child: Icon(
                    Icons.account_circle,
                    size: 44,
                    color: colors.iconColor,
                  ),
                ),
                title: Text(
                  'Loading...',
                  style: TextStyle(color: colors.textColor),
                ),
              );
            }

            if (userSnapshot.hasError || !userSnapshot.hasData) {
              return ListTile(
                leading: CircleAvatar(
                  radius: 22,
                  backgroundColor: colors.cardColor,
                  child: Icon(Icons.error, color: colors.textColor),
                ),
                title: Text(
                  'Unknown User',
                  style: TextStyle(color: colors.textColor),
                ),
                subtitle: Text(
                  blockedUserId,
                  style: TextStyle(color: colors.textColor.withOpacity(0.6)),
                ),
              );
            }

            final userData = userSnapshot.data!;
            final username = userData['username'] ?? 'Unknown User';
            final photoUrl = userData['photoUrl'] ?? '';
            final hasPhoto = photoUrl.isNotEmpty && photoUrl != 'default';

            return ListTile(
              leading: CircleAvatar(
                radius: 22,
                backgroundColor: colors.cardColor,
                backgroundImage: hasPhoto ? NetworkImage(photoUrl) : null,
                onBackgroundImageError: hasPhoto ? (_, __) {} : null,
                child: !hasPhoto
                    ? Icon(
                        Icons.account_circle,
                        size: 44,
                        color: colors.iconColor,
                      )
                    : null,
              ),
              title: Text(
                username,
                style: TextStyle(
                  color: colors.textColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
              trailing: IconButton(
                icon: Icon(Icons.lock_open, color: colors.textColor),
                onPressed: () => _unblockUser(blockedUserId),
              ),
              onTap: () => _openBlockedProfile(blockedUserId),
            );
          },
        );
      },
    );
  }
}

class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
        );
}
