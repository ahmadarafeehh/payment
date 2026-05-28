import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SupabasePostsMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final NotificationService _notificationService = NotificationService();
  final Uuid _uuid = const Uuid();
  final StorageMethods _storageMethods = StorageMethods();

  // ===========================================================================
  // ERROR LOGGING HELPER
  // ===========================================================================
  Future<void> _logPostError({
    required String operationType,
    String? userId,
    String? mediaUrl,
    required dynamic error,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('posts_errors').insert({
        'user_id': userId,
        'operation_type': operationType,
        'media_url': mediaUrl,
        'error_message': error.toString(),
        'stack_trace': error is Error ? error.stackTrace?.toString() : null,
        'additional_data': additionalData,
      });
    } catch (_) {}
  }

  dynamic _unwrap(dynamic res) {
    try {
      if (res == null) return null;
      if (res is Map && res.containsKey('data')) return res['data'];
    } catch (_) {}
    return res;
  }

  bool _isVideoUrl(String url) {
    final isSupabaseVideo =
        url.contains('supabase.co/storage/v1/object/public/videos');
    final hasVideoExtension = url.endsWith('.mp4') ||
        url.endsWith('.mov') ||
        url.endsWith('.avi') ||
        url.endsWith('.mkv');
    return isSupabaseVideo || hasVideoExtension;
  }

  Future<void> _deleteVideoFromUrl(String videoUrl) async {
    try {
      final uri = Uri.parse(videoUrl);
      final pathSegments = uri.pathSegments;
      final videosIndex = pathSegments.indexOf('videos');
      if (videosIndex != -1 && videosIndex < pathSegments.length - 1) {
        final filePath = pathSegments.sublist(videosIndex + 1).join('/');
        await _storageMethods.deleteVideoFromSupabase('videos', filePath);
      } else {
        throw Exception('Invalid video URL format');
      }
    } catch (e) {
      rethrow;
    }
  }

  // ----------------------
  // UPLOAD POST METHODS
  // ----------------------

  Future<String> uploadVideoPost(
    String description,
    Uint8List file,
    String uid,
    String username,
    String profImage,
    String gender, {
    int boostViews = 0,
    bool isBoosted = false,
  }) async {
    String res = "Some error occurred";
    try {
      String postId = _uuid.v1();
      String fileName = 'video_$postId.mp4';

      final String videoUrl = await _storageMethods.uploadVideoToSupabase(
        file,
        fileName,
        useUserFolder: true,
      );

      await _supabase.from('posts').insert({
        'postId': postId,
        'description': description,
        'gender': gender,
        'postUrl': videoUrl,
        'profImage': profImage,
        'uid': uid,
        'username': username,
        'commentsCount': 0,
        'datePublished': DateTime.now().toUtc().toIso8601String(),
        'boost_views': boostViews,
        'is_boosted': isBoosted,
        'viewers_count': boostViews,
      });

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'upload_video_post',
        userId: uid,
        mediaUrl: description,
        error: err,
        additionalData: {
          'username': username,
          'gender': gender,
          'boostViews': boostViews,
          'isBoosted': isBoosted,
        },
      );
    }
    return res;
  }

  Future<String> uploadPost(
    String description,
    Uint8List file,
    String uid,
    String username,
    String profImage,
    String gender, {
    int boostViews = 0,
    bool isBoosted = false,
    String? reactionEmoji,
  }) async {
    String res = "Some error occurred";
    try {
      String postId = _uuid.v1();
      String fileName = 'post_$postId.jpg';

      final String photoUrl = await _storageMethods.uploadImageToSupabase(
        file,
        fileName,
        useUserFolder: true,
      );

      await _supabase.from('posts').insert({
        'postId': postId,
        'description': description,
        'gender': gender,
        'postUrl': photoUrl,
        'profImage': profImage,
        'uid': uid,
        'username': username,
        'commentsCount': 0,
        'datePublished': DateTime.now().toUtc().toIso8601String(),
        'boost_views': boostViews,
        'is_boosted': isBoosted,
        'viewers_count': boostViews,
        'reaction_emoji': reactionEmoji ?? '❤️',
      });

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'upload_post',
        userId: uid,
        mediaUrl: description,
        error: err,
        additionalData: {
          'username': username,
          'gender': gender,
          'boostViews': boostViews,
          'isBoosted': isBoosted,
        },
      );
    }
    return res;
  }

  Future<String> uploadVideoPostFromFile(
    String description,
    File videoFile,
    String uid,
    String username,
    String profImage,
    String gender, {
    int boostViews = 0,
    bool isBoosted = false,
    Map<String, dynamic>? editMetadata,
    String? reactionEmoji,
  }) async {
    String res = "Some error occurred";
    try {
      String postId = _uuid.v1();
      String fileName = 'video_$postId.mp4';

      final String videoUrl = await _storageMethods.uploadVideoFileToSupabase(
        videoFile,
        fileName,
        useUserFolder: true,
      );

      final Map<String, dynamic> payload = {
        'postId': postId,
        'description': description,
        'gender': gender,
        'postUrl': videoUrl,
        'profImage': profImage,
        'uid': uid,
        'username': username,
        'commentsCount': 0,
        'datePublished': DateTime.now().toUtc().toIso8601String(),
        'boost_views': boostViews,
        'is_boosted': isBoosted,
        'viewers_count': boostViews,
        'reaction_emoji': reactionEmoji ?? '❤️',
      };

      if (editMetadata != null) {
        payload['video_edit_metadata'] = editMetadata;
      }

      await _supabase.from('posts').insert(payload);

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'upload_video_post_file',
        userId: uid,
        mediaUrl: description,
        error: err,
        additionalData: {
          'username': username,
          'gender': gender,
          'boostViews': boostViews,
          'isBoosted': isBoosted,
          'hasEditMetadata': editMetadata != null,
        },
      );
    }
    return res;
  }

  Future<String> uploadPostFromFile(
    String description,
    File imageFile,
    String uid,
    String username,
    String profImage,
    String gender, {
    int boostViews = 0,
    bool isBoosted = false,
  }) async {
    String res = "Some error occurred";
    try {
      String postId = _uuid.v1();
      String fileName = 'post_$postId.jpg';

      final String photoUrl = await _storageMethods.uploadImageFileToSupabase(
        imageFile,
        fileName,
        useUserFolder: true,
      );

      await _supabase.from('posts').insert({
        'postId': postId,
        'description': description,
        'gender': gender,
        'postUrl': photoUrl,
        'profImage': profImage,
        'uid': uid,
        'username': username,
        'commentsCount': 0,
        'datePublished': DateTime.now().toUtc().toIso8601String(),
        'boost_views': boostViews,
        'is_boosted': isBoosted,
        'viewers_count': boostViews,
      });

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'upload_post_file',
        userId: uid,
        mediaUrl: description,
        error: err,
        additionalData: {
          'username': username,
          'gender': gender,
          'boostViews': boostViews,
          'isBoosted': isBoosted,
        },
      );
    }
    return res;
  }

  // ----------------------
  // Delete a post
  // ----------------------
  Future<String> deletePost(String postId) async {
    String res = "Some error occurred";
    String? postOwnerUid;
    String? postUrl;
    try {
      final postSel = await _supabase
          .from('posts')
          .select('postUrl, uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;

      if (postData == null) throw Exception('Post does not exist');

      postUrl = postData['postUrl']?.toString() ?? '';
      postOwnerUid = postData['uid']?.toString() ?? '';

      if (postUrl.isNotEmpty) {
        if (_isVideoUrl(postUrl)) {
          await _deleteVideoFromUrl(postUrl);
        } else {
          await _storageMethods.deleteImage(postUrl);
        }
      }

      await _supabase.from('user_post_views').delete().eq('post_id', postId);
      await _supabase.from('posts').delete().eq('postId', postId);
      await _supabase.from('comments').delete().eq('postid', postId);
      await _supabase.from('replies').delete().eq('postid', postId);
      await _supabase.from('post_rating').delete().eq('postid', postId);
      await _supabase
          .from('notifications')
          .delete()
          .eq('custom_data->>postId', postId);

      res = 'success';
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'delete_post',
        userId: postOwnerUid,
        mediaUrl: postUrl,
        error: err,
        additionalData: {'postId': postId},
      );
    }
    return res;
  }

  // ----------------------
  // Get viewed post ids
  // ----------------------
  Future<List<String>> getViewedPostIds(String userId) async {
    try {
      final sel = await _supabase
          .from('user_post_views')
          .select('post_id, viewed_at')
          .eq('user_id', userId);

      final data = _unwrap(sel) ?? sel;
      if (data is List) {
        final rows = List<Map<String, dynamic>>.from(data);
        rows.sort((a, b) => (b['viewed_at'] ?? '')
            .toString()
            .compareTo((a['viewed_at'] ?? '').toString()));
        return rows.map((r) => r['post_id'].toString()).toList();
      }
      return [];
    } catch (e) {
      await _logPostError(
        operationType: 'get_viewed_post_ids',
        userId: userId,
        error: e,
      );
      return [];
    }
  }

  // ----------------------
  // Share a post through chat
  // ----------------------
  Future<String> sharePostThroughChat({
    required String chatId,
    required String senderId,
    required String receiverId,
    required String postId,
    required String postImageUrl,
    required String postCaption,
    required String postOwnerId,
    String? postOwnerUsername,
    String? postOwnerPhotoUrl,
  }) async {
    try {
      final messageId = _uuid.v1();

      await _supabase.from('messages').insert({
        'id': messageId,
        'chat_id': chatId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'message': 'Shared a post: $postCaption',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'is_read': false,
        'delivered': false,
        'post_share': {
          'postId': postId,
          'postImageUrl': postImageUrl,
          'postCaption': postCaption,
          'postOwnerId': postOwnerId,
          'postOwnerUsername': postOwnerUsername ?? 'Unknown User',
          'postOwnerPhotoUrl': postOwnerPhotoUrl ?? '',
          'sharedAt': DateTime.now().toUtc().toIso8601String(),
          'isDirectOwner': senderId == postOwnerId,
        },
      });

      await _supabase.from('chats').update({
        'last_message': 'Shared a post',
        'last_updated': DateTime.now().toIso8601String(),
      }).eq('id', chatId);

      return 'success';
    } catch (e) {
      await _logPostError(
        operationType: 'share_post_through_chat',
        userId: senderId,
        error: e,
        additionalData: {
          'chatId': chatId,
          'receiverId': receiverId,
          'postId': postId,
          'postImageUrl': postImageUrl,
        },
      );
      return e.toString();
    }
  }

  // ----------------------
  // Record post view
  // ----------------------
  Future<void> recordPostView(String postId, String userId) async {
    try {
      await _supabase.from('user_post_views').upsert(
        {
          'post_id': postId,
          'user_id': userId,
          'viewed_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,post_id',
        ignoreDuplicates: true,
      );
    } catch (e) {
      await _logPostError(
        operationType: 'record_post_view',
        userId: userId,
        error: e,
        additionalData: {'postId': postId},
      );
    }
  }

  // ----------------------
  // Mutual block check
  // ----------------------
  Future<bool> checkMutualBlock(String userId1, String userId2) async {
    try {
      final sel1 = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', userId1)
          .maybeSingle();
      final sel2 = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', userId2)
          .maybeSingle();
      final data1 = _unwrap(sel1) ?? sel1;
      final data2 = _unwrap(sel2) ?? sel2;

      final List<dynamic> blocked1 =
          data1 != null ? (data1['blockedUsers'] ?? []) : [];
      final List<dynamic> blocked2 =
          data2 != null ? (data2['blockedUsers'] ?? []) : [];

      return blocked1.contains(userId2) && blocked2.contains(userId1);
    } catch (e) {
      await _logPostError(
        operationType: 'check_mutual_block',
        userId: userId1,
        error: e,
        additionalData: {'otherUserId': userId2},
      );
      return false;
    }
  }

  // ----------------------
  // Report a post
  // ----------------------
  Future<String> reportPost(String postId, String reason) async {
    try {
      await _supabase.from('reports').insert({
        'postId': postId,
        'reason': reason,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'post',
      });
      return 'success';
    } catch (err) {
      await _logPostError(
        operationType: 'report_post',
        error: err,
        additionalData: {'postId': postId, 'reason': reason},
      );
      return err.toString();
    }
  }

  // ----------------------
  // First-post nudge notification
  // ----------------------
  Future<void> scheduleFirstPostNudge(String userId) async {
    try {
      final userRow = await _supabase
          .from('users')
          .select('test')
          .eq('uid', userId)
          .maybeSingle();

      final bool isTestGroup = userRow?['test'] ?? false;
      if (!isTestGroup) return;

      final existing = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', userId)
          .limit(1)
          .maybeSingle();
      if (existing != null) return;

      final prefs = await SharedPreferences.getInstance();
      final sendAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 59))
          .toIso8601String();
      await prefs.setString('nudge_send_at_$userId', sendAt);
      await prefs.setString('nudge_user_id', userId);

      Future.delayed(const Duration(seconds: 59), () async {
        await trySendNudge();
      });
    } catch (e) {
      await _logPostError(
        operationType: 'schedule_first_post_nudge',
        userId: userId,
        error: e,
      );
    }
  }

  Future<void> trySendNudge() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('nudge_user_id');
      if (userId == null || userId.isEmpty) return;

      final sendAtStr = prefs.getString('nudge_send_at_$userId');
      if (sendAtStr == null) return;

      final sendAt = DateTime.parse(sendAtStr);
      if (DateTime.now().toUtc().isBefore(sendAt)) return;

      final check = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', userId)
          .limit(1)
          .maybeSingle();

      await prefs.remove('nudge_send_at_$userId');
      await prefs.remove('nudge_user_id');

      if (check != null) return;

      await _notificationService.triggerServerNotification(
        type: 'first_post_nudge',
        targetUserId: userId,
        title: 'Don\'t miss out!',
        body: '⏳ You\'re missing reactions by not posting yet — fix that now.',
        customData: {
          'nudgeType': 'first_post',
          'userId': userId,
        },
      );
    } catch (e) {
      await _logPostError(
        operationType: 'try_send_nudge',
        error: e,
      );
    }
  }
}
