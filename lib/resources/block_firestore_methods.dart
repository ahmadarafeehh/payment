import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/resources/messages_firestore_methods.dart';
import 'package:flutter/foundation.dart'; // For debugPrint

class SupabaseBlockMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabaseMessagesMethods _messagesMethods = SupabaseMessagesMethods();

  Future<void> blockUser({
    required String currentUserId,
    required String targetUserId,
  }) async {
    try {
      // Get current user's blockedUsers array

      final currentUserResponse = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId)
          .single();

      List<dynamic> blockedUsers = currentUserResponse['blockedUsers'] ?? [];

      // Add target user to blocked list
      blockedUsers.add(targetUserId);

      // Update user's blockedUsers array

      await _supabase
          .from('users')
          .update({'blockedUsers': blockedUsers}).eq('uid', currentUserId);
      // Remove follow relationships
      await _removeFollowRelationships(currentUserId, targetUserId);

      // Delete notifications

      await _deleteMutualNotifications(currentUserId, targetUserId);

      // Remove profile ratings

      await _removeMutualProfileRatings(currentUserId, targetUserId);

      // Remove post ratings

      await _removeMutualPostRatings(currentUserId, targetUserId);

      // Delete comments

      await _deleteMutualComments(currentUserId, targetUserId);

      // Delete chat messages

      await _deleteChatMessages(currentUserId, targetUserId);
    } catch (e) {
      throw Exception("Block failed: $e");
    }
  }

  Future<void> unblockUser({
    required String currentUserId,
    required String targetUserId,
  }) async {
    try {
      // Get current user's blockedUsers array
      final currentUserResponse = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId)
          .single();

      List<dynamic> blockedUsers = currentUserResponse['blockedUsers'] ?? [];

      // Remove target user from blocked list
      blockedUsers.remove(targetUserId);

      // Update user's blockedUsers array
      await _supabase
          .from('users')
          .update({'blockedUsers': blockedUsers}).eq('uid', currentUserId);
    } catch (e) {
      throw Exception("Unblock failed: $e");
    }
  }

  Future<bool> isUserBlocked({
    required String currentUserId,
    required String targetUserId,
  }) async {
    try {
      // Check if target user has blocked current user
      final targetUserResponse = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', targetUserId)
          .single();

      List<dynamic> blockedUsers = targetUserResponse['blockedUsers'] ?? [];
      return blockedUsers.contains(currentUserId);
    } catch (e) {
      return false;
    }
  }

  Future<bool> isBlockInitiator({
    required String currentUserId,
    required String targetUserId,
  }) async {
    try {
      // Check if current user has blocked target user
      final currentUserResponse = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId)
          .single();

      List<dynamic> blockedUsers = currentUserResponse['blockedUsers'] ?? [];
      return blockedUsers.contains(targetUserId);
    } catch (e) {
      return false;
    }
  }

  Future<void> _removeFollowRelationships(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Remove from followers/following tables
      await _supabase
          .from('user_followers')
          .delete()
          .eq('user_id', currentUserId)
          .eq('follower_id', targetUserId);

      await _supabase
          .from('user_followers')
          .delete()
          .eq('user_id', targetUserId)
          .eq('follower_id', currentUserId);

      await _supabase
          .from('user_following')
          .delete()
          .eq('user_id', currentUserId)
          .eq('following_id', targetUserId);

      await _supabase
          .from('user_following')
          .delete()
          .eq('user_id', targetUserId)
          .eq('following_id', currentUserId);
    } catch (e) {}
  }

  Future<void> _deleteMutualNotifications(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Delete follow-related notifications
      await _supabase
          .from('notifications')
          .delete()
          .or(
              'target_user_id.eq.$currentUserId,target_user_id.eq.$targetUserId')
          .filter('type', 'in',
              '(${'follow'}, ${'follow_request'}, ${'follow_request_accepted'})')
          .filter('custom_data->>requesterId', 'in',
              '($currentUserId, $targetUserId)')
          .filter('custom_data->>followerId', 'in',
              '($currentUserId, $targetUserId)')
          .filter('custom_data->>approverId', 'in',
              '($currentUserId, $targetUserId)');

      // Delete rating-related notifications
      await _supabase
          .from('notifications')
          .delete()
          .or(
              'target_user_id.eq.$currentUserId,target_user_id.eq.$targetUserId')
          .filter('type', 'in', '(${'rating'}, ${'profile_rating'})')
          .filter('custom_data->>raterUserId', 'in',
              '($currentUserId, $targetUserId)');

      // Delete comment-related notifications
      await _supabase
          .from('notifications')
          .delete()
          .or(
              'target_user_id.eq.$currentUserId,target_user_id.eq.$targetUserId')
          .eq('type', 'comment')
          .filter('custom_data->>commenterId', 'in',
              '($currentUserId, $targetUserId)');
    } catch (e) {}
  }

  Future<void> _removeMutualProfileRatings(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Check if the ratings column exists in the users table

    } catch (e) {}
  }

  Future<void> _removeMutualPostRatings(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Get all posts by target user
      final targetPosts =
          await _supabase.from('posts').select().eq('uid', targetUserId);

      for (var post in targetPosts) {
        if (post['rate'] != null) {
          final filteredRates = (post['rate'] as List)
              .where((rate) => rate['userId'] != currentUserId)
              .toList();

          await _supabase
              .from('posts')
              .update({'rate': filteredRates}).eq('postId', post['postId']);
        }
      }

      // Get all posts by current user
      final currentPosts =
          await _supabase.from('posts').select().eq('uid', currentUserId);

      for (var post in currentPosts) {
        if (post['rate'] != null) {
          final filteredRates = (post['rate'] as List)
              .where((rate) => rate['userId'] != targetUserId)
              .toList();

          await _supabase
              .from('posts')
              .update({'rate': filteredRates}).eq('postId', post['postId']);
        }
      }
    } catch (e) {}
  }

  Future<void> _deleteMutualComments(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Since the comments table doesn't have post_owner_uid, we need a different approach
      // First, get all posts by the target user
      final targetPosts = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', targetUserId);

      // Delete comments by current user on target user's posts
      if (targetPosts.isNotEmpty) {
        final postIds =
            targetPosts.map((post) => post['postId'] as String).toList();
        await _supabase
            .from('comments')
            .delete()
            .eq('uid', currentUserId)
            .inFilter('postid', postIds);
      }

      // Get all posts by the current user
      final currentPosts = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', currentUserId);

      // Delete comments by target user on current user's posts
      if (currentPosts.isNotEmpty) {
        final postIds =
            currentPosts.map((post) => post['postId'] as String).toList();
        await _supabase
            .from('comments')
            .delete()
            .eq('uid', targetUserId)
            .inFilter('postid', postIds);
      }
    } catch (e) {}
  }

  Future<void> _deleteChatMessages(
    String currentUserId,
    String targetUserId,
  ) async {
    try {
      // Delete chat messages between users
      await _supabase
          .from('messages')
          .delete()
          .or('sender_id.eq.$currentUserId,receiver_id.eq.$targetUserId')
          .or('sender_id.eq.$targetUserId,receiver_id.eq.$currentUserId');
    } catch (e) {}
  }

  Future<List<String>> getBlockedUsers(String userId) async {
    try {
      final response = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', userId)
          .single();

      List<dynamic> blockedUsers = response['blockedUsers'] ?? [];
      return blockedUsers.map((uid) => uid.toString()).toList();
    } catch (e) {
      return [];
    }
  }

  Future<bool> isMutuallyBlocked(String userId1, String userId2) async {
    final results = await Future.wait([
      isUserBlocked(currentUserId: userId1, targetUserId: userId2),
      isUserBlocked(currentUserId: userId2, targetUserId: userId1)
    ]);
    return results[0] || results[1];
  }
}
