// lib/utils/global_variable.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:Ratedly/screens/feed/feed_screen.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart'; // Changed import to profile_screen.dart
import 'package:Ratedly/screens/search_screen.dart';
import 'package:Ratedly/screens/notification_screen.dart';
import 'package:Ratedly/providers/user_provider.dart';

const webScreenSize = 600;

List<Widget> homeScreenItems(BuildContext context) {
  return [
    const FeedScreen(),
    const SearchScreen(),
    const NotificationScreen(),

    // Create ProfileScreen dynamically, using UserProvider to get Firebase UID
    Builder(
      builder: (context) {
        final userProvider = Provider.of<UserProvider>(context, listen: true);
        String? currentUserUid = userProvider.firebaseUid;

        if (currentUserUid == null || currentUserUid.isEmpty) {
          // Try to get from FirebaseAuth as fallback (for non-migrated users)
          final firebaseAuthUid = FirebaseAuth.instance.currentUser?.uid;
          if (firebaseAuthUid != null && firebaseAuthUid.isNotEmpty) {
            currentUserUid = firebaseAuthUid;
          } else {
            // If still no UID, try to get from Supabase UID for migrated users
            if (userProvider.supabaseUid != null && userProvider.isMigrated) {
              // We need to get the Firebase UID from the database using the Supabase UID
              // For now, show loading and we'll handle it in ProfileScreen
              return const Center(
                child: CircularProgressIndicator(),
              );
            }

            // Show loading indicator
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        }

        // Make sure we have a non-null UID
        if (currentUserUid == null || currentUserUid.isEmpty) {
          return const Center(
            child: Text('Unable to load profile'),
          );
        }

        return ProfileScreen(uid: currentUserUid);
      },
    ),
  ];
}

// Helper function to get the current Firebase UID from any screen
String? getCurrentFirebaseUid(BuildContext context) {
  try {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    String? firebaseUid = userProvider.firebaseUid;

    if (firebaseUid == null || firebaseUid.isEmpty) {
      // Fallback to FirebaseAuth for non-migrated users
      final firebaseAuthUid = FirebaseAuth.instance.currentUser?.uid;
      if (firebaseAuthUid != null && firebaseAuthUid.isNotEmpty) {
        return firebaseAuthUid;
      }

      return null;
    }

    return firebaseUid;
  } catch (e) {
    return null;
  }
}

// Helper function to check if user is migrated
bool isUserMigrated(BuildContext context) {
  try {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    return userProvider.isMigrated;
  } catch (e) {
    return false;
  }
}

// Helper function to get Supabase UID
String? getCurrentSupabaseUid(BuildContext context) {
  try {
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    return userProvider.supabaseUid;
  } catch (e) {
    return null;
  }
}
