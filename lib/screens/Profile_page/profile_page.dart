// lib/screens/profile_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/screens/Profile_page/current_profile_screen.dart';
import 'package:Ratedly/screens/Profile_page/other_user_profile.dart';
import 'package:Ratedly/providers/user_provider.dart';

class ProfileScreen extends StatelessWidget {
  final String uid;
  const ProfileScreen({Key? key, required this.uid}) : super(key: key);

  /// Returns the current user's uid column value — which is:
  /// - Firebase UID for migrated users  (e.g. "uAodpgVeviTGUtLo3duENwOvZMo1")
  /// - Supabase UUID for pure Supabase users (e.g. "996502b5-...")
  ///   because for pure Supabase users uid == supabase_uid in the DB.
  ///
  /// We deliberately do NOT use FirebaseAuth here because pure Supabase
  /// users have no Firebase session, so FirebaseAuth.currentUser == null,
  /// which previously broke the "is this my profile?" comparison and caused
  /// a 500ms delay before falling back to UserProvider anyway.
  String? _resolveCurrentUserId(BuildContext context) {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    // firebaseUid holds the DB uid column value for ALL user types:
    //   migrated users  → real Firebase UID
    //   pure Supabase   → their Supabase UUID (also stored in uid column)
    return userProvider.firebaseUid ?? userProvider.supabaseUid;
  }

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('Invalid user ID')),
      );
    }

    final currentUserId = _resolveCurrentUserId(context);

    if (currentUserId == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'Unable to load profile',
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'Please try logging in again',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return uid == currentUserId
        ? CurrentUserProfileScreen(uid: uid)
        : OtherUserProfileScreen(uid: uid);
  }
}
