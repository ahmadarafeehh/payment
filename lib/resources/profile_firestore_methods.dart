import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/services/notification_service.dart';

class SupabaseProfileMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final NotificationService _notificationService = NotificationService();

  dynamic _unwrap(dynamic res) {
    try {
      if (res == null) return null;
      if (res is Map && res.containsKey('data')) return res['data'];
    } catch (_) {}
    return res;
  }

  bool _isGooglePhoto(String? url) {
    if (url == null || url == 'default') return false;
    return url.contains('googleusercontent.com') ||
        url.contains('lh3.googleusercontent.com');
  }

  bool _isFirebasePhoto(String? url) {
    if (url == null || url == 'default') return false;
    return url.contains('firebasestorage.googleapis.com');
  }

  bool _isSupabaseUrl(String? url) {
    if (url == null || url == 'default') return false;
    return url.contains('supabase.co/storage');
  }

  bool _isVideoUrl(String url) {
    return url.contains('supabase.co/storage/v1/object/public/videos') ||
        url.endsWith('.mp4') ||
        url.endsWith('.mov') ||
        url.endsWith('.avi') ||
        url.endsWith('.mkv');
  }

  Future<void> _deleteVideoFromUrl(String videoUrl) async {
    try {
      final uri = Uri.parse(videoUrl);
      final pathSegments = uri.pathSegments;
      final videosIndex = pathSegments.indexOf('videos');
      if (videosIndex != -1 && videosIndex < pathSegments.length - 1) {
        final filePath = pathSegments.sublist(videosIndex + 1).join('/');
        await StorageMethods().deleteVideoFromSupabase('videos', filePath);
      } else {
        final fileName = videoUrl.split('/').last;
        await StorageMethods().deleteVideoFromSupabase('videos', fileName);
      }
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteProfileMedia(String mediaUrl) async {
    try {
      if (mediaUrl.isEmpty || mediaUrl == 'default') return;
      if (_isVideoUrl(mediaUrl)) {
        await _deleteVideoFromUrl(mediaUrl);
      } else if (_isSupabaseUrl(mediaUrl)) {
        await StorageMethods().deleteImage(mediaUrl);
      }
    } catch (e) {
      // Silently ignore
    }
  }

  Future<void> _deleteAllUserPosts(String uid) async {
    try {
      final postsResponse = await _supabase
          .from('posts')
          .select('postId, postUrl')
          .eq('uid', uid);

      final posts = _unwrap(postsResponse) ?? postsResponse;

      if (posts is List && posts.isNotEmpty) {
        for (final post in posts) {
          final postUrl = post['postUrl']?.toString() ?? '';
          final postId = post['postId']?.toString() ?? '';

          if (postUrl.isNotEmpty) {
            if (_isVideoUrl(postUrl)) {
              await _deleteVideoFromUrl(postUrl);
            } else {
              await StorageMethods().deleteImage(postUrl);
            }
          }

          await _supabase
              .from('user_post_views')
              .delete()
              .eq('post_id', postId);
          await _supabase.from('comments').delete().eq('postid', postId);
          await _supabase.from('replies').delete().eq('postid', postId);
          await _supabase.from('post_rating').delete().eq('postid', postId);
          await _supabase
              .from('notifications')
              .delete()
              .eq('custom_data->>postId', postId);
        }
      }

      await _supabase.from('posts').delete().eq('uid', uid);
    } catch (e) {
      rethrow;
    }
  }

  // ----------------------
  // Privacy
  // ----------------------
  Future<void> toggleAccountPrivacy(String uid, bool isPrivate) async {
    await _supabase
        .from('users')
        .update({'isPrivate': isPrivate}).eq('uid', uid);
  }

  Future<void> approveAllFollowRequests(String userId) async {
    try {
      final response = await _supabase
          .from('user_follow_request')
          .select('requester_id, requested_at')
          .eq('user_id', userId);

      final List<dynamic> requests = _unwrap(response) ?? response;
      if (requests.isEmpty) return;

      for (final request in requests) {
        try {
          final requesterId = request['requester_id'] as String;

          await _supabase.from('user_followers').upsert({
            'user_id': userId,
            'follower_id': requesterId,
            'followed_at': DateTime.now().toUtc().toIso8601String(),
          });

          await _supabase.from('user_following').upsert({
            'user_id': requesterId,
            'following_id': userId,
            'followed_at': DateTime.now().toUtc().toIso8601String(),
          });

          final userResponse = await _supabase
              .from('users')
              .select('username')
              .eq('uid', userId)
              .maybeSingle();
          final userData = _unwrap(userResponse) ?? userResponse;
          final String username = userData?['username'] ?? 'Someone';

          await _supabase
              .from('notifications')
              .delete()
              .eq('target_user_id', userId)
              .eq('type', 'follow_request')
              .eq('custom_data->>requesterId', requesterId);

          await _supabase.from('notifications').insert({
            'target_user_id': userId,
            'type': 'follow',
            'custom_data': {'followerId': requesterId},
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });

          _notificationService.triggerServerNotification(
            type: 'follow',
            targetUserId: userId,
            title: 'New Follower',
            body: '$username started following you',
            customData: {'followerId': requesterId},
          );
        } catch (e) {
          // Continue with other requests
        }
      }

      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', userId);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> removeFollower(String currentUserId, String followerId) async {
    try {
      await _supabase
          .from('user_followers')
          .delete()
          .eq('user_id', currentUserId)
          .eq('follower_id', followerId);

      await _supabase
          .from('user_following')
          .delete()
          .eq('user_id', followerId)
          .eq('following_id', currentUserId);

      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', currentUserId)
          .eq('requester_id', followerId);

      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', followerId)
          .eq('requester_id', currentUserId);

      await _supabase
          .from('notifications')
          .delete()
          .eq('target_user_id', followerId)
          .eq('type', 'follow_request_accepted')
          .eq('custom_data->>approverId', currentUserId);
    } catch (e) {
      rethrow;
    }
  }

  // ----------------------
  // Profile views
  // ----------------------
  Future<void> recordProfileView(
      String profileOwnerUid, String viewerUid) async {
    try {
      if (profileOwnerUid == viewerUid) return;
      await _supabase.from('user_profile_views').upsert({
        'user_id': viewerUid,
        'profileowneruid': profileOwnerUid,
        'viewed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {}
  }

  Future<int> getProfileViewCount(String profileOwnerUid) async {
    try {
      final response = await _supabase
          .from('user_profile_views')
          .select()
          .eq('profileowneruid', profileOwnerUid);
      return response.length;
    } catch (e) {
      return 0;
    }
  }

  Future<List<Map<String, dynamic>>> getProfileViewers(
      String profileOwnerUid) async {
    try {
      final response = await _supabase
          .from('user_profile_views')
          .select('''
          user_id,
          viewed_at,
          users:user_id (username, photoUrl)
        ''')
          .eq('profileowneruid', profileOwnerUid)
          .order('viewed_at', ascending: false);

      List<Map<String, dynamic>> viewers = [];
      for (var item in response) {
        viewers.add({
          'user_id': item['user_id'],
          'viewed_at': item['viewed_at'],
          'username': item['users']['username'],
          'photoUrl': item['users']['photoUrl'],
        });
      }
      return viewers;
    } catch (e) {
      return [];
    }
  }

  // ----------------------
  // Follow / unfollow
  // ----------------------
  Future<void> unfollowUser(String uid, String unfollowId) async {
    try {
      await _supabase
          .from('user_following')
          .delete()
          .eq('user_id', uid)
          .eq('following_id', unfollowId);

      await _supabase
          .from('user_followers')
          .delete()
          .eq('user_id', unfollowId)
          .eq('follower_id', uid);

      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', unfollowId)
          .eq('requester_id', uid);

      await _supabase
          .from('notifications')
          .delete()
          .eq('target_user_id', unfollowId)
          .eq('type', 'follow')
          .eq('custom_data->>followerId', uid);
    } catch (e) {
      rethrow;
    }
  }

  Future<void> followUser(String uid, String followId) async {
    print('');
    print('┌─────────────────────────────────────────────────┐');
    print('│  [PROFILE:follow] followUser() called           │');
    print('└─────────────────────────────────────────────────┘');
    print('[PROFILE:follow] uid (follower):  $uid');
    print('[PROFILE:follow] followId (target): $followId');

    try {
      // Check if already following
      final existingFollowing = await _supabase
          .from('user_following')
          .select()
          .eq('user_id', uid)
          .eq('following_id', followId)
          .maybeSingle();

      if (existingFollowing != null) {
        print(
            '[PROFILE:follow] Already following — calling unfollowUser() instead');
        await unfollowUser(uid, followId);
        return;
      }

      // Check if target account is private
      final targetSel = await _supabase
          .from('users')
          .select('isPrivate')
          .eq('uid', followId)
          .maybeSingle();
      final targetUser = _unwrap(targetSel) ?? targetSel;
      final isPrivate = targetUser?['isPrivate'] ?? false;
      final timestamp = DateTime.now();

      print('[PROFILE:follow] Target account isPrivate: $isPrivate');

      if (isPrivate) {
        print('[PROFILE:follow] ▶ Private account — sending follow REQUEST');

        final existingRequest = await _supabase
            .from('user_follow_request')
            .select()
            .eq('user_id', followId)
            .eq('requester_id', uid)
            .maybeSingle();

        if (existingRequest != null) {
          print('[PROFILE:follow] Request already exists — skipping');
          return;
        }

        await _supabase.from('user_follow_request').insert({
          'user_id': followId,
          'requester_id': uid,
          'requested_at': timestamp.toIso8601String(),
        });
        print(
            '[PROFILE:follow] ✅ Follow request inserted to user_follow_request');

        final requesterSel = await _supabase
            .from('users')
            .select('username')
            .eq('uid', uid)
            .maybeSingle();
        final requesterData = _unwrap(requesterSel) ?? requesterSel;
        final String requesterUsername =
            requesterData?['username'] ?? 'Someone';

        print('[PROFILE:follow] Requester username: $requesterUsername');
        print(
            '[PROFILE:follow] ▶ Calling triggerServerNotification(follow_request)...');

        _notificationService.triggerServerNotification(
          type: 'follow_request',
          targetUserId: followId,
          title: 'New Follow Request',
          body: '$requesterUsername wants to follow you',
          customData: {'requesterId': uid},
        );

        print(
            '[PROFILE:follow] ▶ Writing follow_request to Supabase notifications...');
        await _createFollowRequestNotification(uid, followId);
        print(
            '[PROFILE:follow] ✅ follow_request notification saved to Supabase');
      } else {
        print('[PROFILE:follow] ▶ Public account — following directly');

        await _supabase.from('user_followers').insert({
          'user_id': followId,
          'follower_id': uid,
          'followed_at': timestamp.toIso8601String(),
        });
        print('[PROFILE:follow] ✅ Inserted into user_followers');

        await _supabase.from('user_following').insert({
          'user_id': uid,
          'following_id': followId,
          'followed_at': timestamp.toIso8601String(),
        });
        print('[PROFILE:follow] ✅ Inserted into user_following');

        final followerSel = await _supabase
            .from('users')
            .select('username')
            .eq('uid', uid)
            .maybeSingle();
        final followerData = _unwrap(followerSel) ?? followerSel;
        final String followerUsername = followerData?['username'] ?? 'Someone';

        print('[PROFILE:follow] Follower username: $followerUsername');
        print(
            '[PROFILE:follow] ▶ Calling triggerServerNotification(follow)...');

        _notificationService.triggerServerNotification(
          type: 'follow',
          targetUserId: followId,
          title: 'New Follower',
          body: '$followerUsername started following you',
          customData: {'followerId': uid},
        );

        print('[PROFILE:follow] ▶ Writing follow notification to Supabase...');
        await createFollowNotification(uid, followId);
        print('[PROFILE:follow] ✅ Follow notification saved to Supabase');
      }
    } catch (e) {
      print('[PROFILE:follow] ❌ EXCEPTION in followUser(): $e');
      rethrow;
    }
    print('');
  }

  Future<void> _createFollowRequestNotification(
      String requesterUid, String targetUid) async {
    print('[PROFILE:notif] Writing follow_request notification to Supabase...');
    await _supabase.from('notifications').insert({
      'target_user_id': targetUid,
      'type': 'follow_request',
      'custom_data': {'requesterId': requesterUid},
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    print(
        '[PROFILE:notif] ✅ follow_request inserted to Supabase notifications');
  }

  Future<void> acceptFollowRequest(
      String targetUid, String requesterUid) async {
    print('[PROFILE:accept] ▶ acceptFollowRequest() called');
    print(
        '[PROFILE:accept] targetUid: $targetUid, requesterUid: $requesterUid');
    try {
      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', targetUid)
          .eq('requester_id', requesterUid);
      print('[PROFILE:accept] ✅ Deleted from user_follow_request');

      await _supabase
          .from('notifications')
          .delete()
          .eq('target_user_id', targetUid)
          .eq('type', 'follow_request')
          .eq('custom_data->>requesterId', requesterUid);
      print(
          '[PROFILE:accept] ✅ Deleted follow_request notification from Supabase');

      final timestamp = DateTime.now();
      await _supabase.from('user_followers').upsert({
        'user_id': targetUid,
        'follower_id': requesterUid,
        'followed_at': timestamp.toIso8601String(),
      });

      await _supabase.from('user_following').upsert({
        'user_id': requesterUid,
        'following_id': targetUid,
        'followed_at': timestamp.toIso8601String(),
      });
      print('[PROFILE:accept] ✅ Upserted followers/following tables');

      final targetSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', targetUid)
          .maybeSingle();
      final targetUserData = _unwrap(targetSel) ?? targetSel;
      final String username = targetUserData?['username'] ?? 'Someone';

      await _supabase.from('notifications').insert({
        'target_user_id': requesterUid,
        'type': 'follow_request_accepted',
        'custom_data': {'approverId': targetUid},
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      print(
          '[PROFILE:accept] ✅ follow_request_accepted written to Supabase notifications');

      print(
          '[PROFILE:accept] ▶ Calling triggerServerNotification(follow_request_accepted)...');
      _notificationService.triggerServerNotification(
        type: 'follow_request_accepted',
        targetUserId: requesterUid,
        title: 'Follow Request Approved',
        body: '$username approved your follow request',
        customData: {'approverId': targetUid},
      );

      await createFollowNotification(requesterUid, targetUid);
      print('[PROFILE:accept] ✅ acceptFollowRequest() complete');
    } catch (e) {
      print('[PROFILE:accept] ❌ EXCEPTION in acceptFollowRequest(): $e');
      rethrow;
    }
  }

  Future<void> declineFollowRequest(
      String targetUid, String requesterUid) async {
    try {
      await _supabase
          .from('user_follow_request')
          .delete()
          .eq('user_id', targetUid)
          .eq('requester_id', requesterUid);

      await _supabase
          .from('notifications')
          .delete()
          .eq('target_user_id', targetUid)
          .eq('type', 'follow_request')
          .eq('custom_data->>requesterId', requesterUid);

      await _supabase
          .from('user_following')
          .delete()
          .eq('user_id', requesterUid)
          .eq('following_id', targetUid);
    } catch (e) {
      rethrow;
    }
  }

  Future<String> reportProfile(String userId, String reason) async {
    String res = "Some error occurred";
    try {
      await _supabase.from('reports').insert({
        'user_id': userId,
        'reason': reason,
        'type': 'profile',
        'created_at': DateTime.now().toIso8601String(),
      });
      res = 'success';
    } catch (err) {
      res = err.toString();
    }
    return res;
  }

  Future<bool> hasPendingRequest(String requesterUid, String targetUid) async {
    try {
      final requests = await _supabase
          .from('user_follow_request')
          .select()
          .eq('user_id', targetUid)
          .eq('requester_id', requesterUid);
      final data = _unwrap(requests) ?? requests;
      return data.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  Future<void> createFollowNotification(
    String followerUid,
    String followedUid,
  ) async {
    print(
        '[PROFILE:notif] Writing follow notification to Supabase notifications...');
    await _supabase.from('notifications').insert({
      'target_user_id': followedUid,
      'type': 'follow',
      'custom_data': {'followerId': followerUid},
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    print('[PROFILE:notif] ✅ Follow notification inserted');
  }

  Future<void> _deleteUserActorNotifications(String uid) async {
    try {
      await _supabase.from('notifications').delete().or(
          'custom_data->>raterUid.eq.$uid,' +
              'custom_data->>followerId.eq.$uid,' +
              'custom_data->>commenterUid.eq.$uid,' +
              'custom_data->>likerUid.eq.$uid,' +
              'custom_data->>requesterId.eq.$uid,' +
              'custom_data->>approverId.eq.$uid,' +
              'custom_data->>replierUid.eq.$uid');
    } catch (e) {}
  }

  Future<void> _deleteUserPostViews(String uid) async {
    try {
      await _supabase.from('user_post_views').delete().eq('user_id', uid);

      final postsResponse =
          await _supabase.from('posts').select('postId').eq('uid', uid);
      final posts = _unwrap(postsResponse) ?? postsResponse;

      if (posts is List && posts.isNotEmpty) {
        for (final post in posts) {
          await _supabase
              .from('user_post_views')
              .delete()
              .eq('post_id', post['postId'] as String);
        }
      }
    } catch (e) {}
  }

  Future<String> deleteEntireUserAccount(
      String uid, firebase_auth.AuthCredential? credential) async {
    String res = "Some error occurred";

    try {
      final userSel =
          await _supabase.from('users').select().eq('uid', uid).maybeSingle();
      final userData = _unwrap(userSel) ?? userSel;

      if (userData == null) throw Exception("User record not found");

      final firebaseUser = firebase_auth.FirebaseAuth.instance.currentUser;
      final supabaseSession = _supabase.auth.currentSession;

      final bool isFirebaseUser =
          firebaseUser != null && firebaseUser.uid == uid;
      final bool isSupabaseUser = supabaseSession != null &&
          userData['supabase_uid'] == supabaseSession.user.id;

      if (!isFirebaseUser && !isSupabaseUser) {
        throw Exception("User not authenticated or UID mismatch");
      }

      if (isFirebaseUser && credential != null) {
        await firebaseUser!.reauthenticateWithCredential(credential);
      }

      if (isFirebaseUser && firebaseUser != null) {
        await firebaseUser.delete();
      }

      if (isSupabaseUser) {
        await _supabase.auth.signOut();
      }

      await _supabase.from('users').delete().eq('uid', uid);

      res = "success";
    } on firebase_auth.FirebaseAuthException catch (e) {
      res = e.code == 'requires-recent-login'
          ? "Re-authentication required. Please sign in again."
          : e.message ?? "Authentication error";
    } catch (e) {
      res = e.toString();
    }

    return res;
  }
}
