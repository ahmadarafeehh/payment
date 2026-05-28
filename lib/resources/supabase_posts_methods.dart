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
  // Like/unlike a comment
  // ----------------------
  Future<String> likeComment(
      String postId, String commentId, String uid) async {
    try {
      final likeCheck = await _supabase
          .from('comment_likes')
          .select()
          .eq('comment_id', commentId)
          .eq('uid', uid)
          .maybeSingle();

      final alreadyLiked = likeCheck != null;

      if (alreadyLiked) {
        await _supabase
            .from('comment_likes')
            .delete()
            .eq('comment_id', commentId)
            .eq('uid', uid);

        final commentSel = await _supabase
            .from('comments')
            .select('like_count')
            .eq('id', commentId)
            .maybeSingle();

        final commentData = _unwrap(commentSel) ?? commentSel;
        if (commentData != null) {
          int currentCount = commentData['like_count'] ?? 0;
          int newCount = (currentCount - 1).clamp(0, 99999);
          await _supabase
              .from('comments')
              .update({'like_count': newCount}).eq('id', commentId);
        }

        await deleteCommentLikeNotification(postId, commentId, uid);
      } else {
        await _supabase.from('comment_likes').insert({
          'comment_id': commentId,
          'uid': uid,
          'liked_at': DateTime.now().toUtc().toIso8601String(),
        });

        final commentSel = await _supabase
            .from('comments')
            .select('like_count, uid, comment_text')
            .eq('id', commentId)
            .maybeSingle();

        final commentData = _unwrap(commentSel) ?? commentSel;
        if (commentData != null) {
          int currentCount = commentData['like_count'] ?? 0;
          int newCount = currentCount + 1;

          await _supabase
              .from('comments')
              .update({'like_count': newCount}).eq('id', commentId);

          final String commentOwnerId = commentData['uid'];
          final String commentText = commentData['comment_text'] ?? '';

          if (commentOwnerId != uid) {
            await createCommentLikeNotification(
              postId: postId,
              commentId: commentId,
              commentOwnerUid: commentOwnerId,
              likerUid: uid,
              commentText: commentText,
            );

            final likerSel = await _supabase
                .from('users')
                .select('username')
                .eq('uid', uid)
                .maybeSingle();
            final likerData = _unwrap(likerSel) ?? likerSel;
            final String likerUsername = likerData?['username'] ?? 'Someone';

            await _notificationService.triggerServerNotification(
              type: 'comment_like',
              targetUserId: commentOwnerId,
              title: 'New Like',
              body: '$likerUsername liked your comment: $commentText',
              customData: {
                'likerId': uid,
                'postId': postId,
                'commentId': commentId,
              },
            );
          }
        }
      }

      return 'success';
    } catch (err) {
      await _logPostError(
        operationType: 'like_comment',
        userId: uid,
        error: err,
        additionalData: {'postId': postId, 'commentId': commentId},
      );
      return err.toString();
    }
  }

  // ----------------------
  // Create comment-like notification
  // ----------------------
  Future<void> createCommentLikeNotification({
    required String postId,
    required String commentId,
    required String commentOwnerUid,
    required String likerUid,
    required String commentText,
  }) async {
    try {
      await _supabase.from('notifications').insert({
        'type': 'comment_like',
        'target_user_id': commentOwnerUid,
        'custom_data': {
          'likerUid': likerUid,
          'postId': postId,
          'commentId': commentId,
          'commentText': commentText,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logPostError(
        operationType: 'create_comment_like_notification',
        userId: likerUid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'commentOwnerUid': commentOwnerUid,
        },
      );
    }
  }

  // ----------------------
  // Create reaction notification
  // ----------------------
  Future<void> createNotification({
    required String postId,
    required String postOwnerUid,
    required String raterUid,
    required double rating,
  }) async {
    if (raterUid == postOwnerUid || postOwnerUid.isEmpty) return;

    // ── Step 1: DB write (best-effort — failure must NOT block the push) ────
    try {
      await _supabase.from('notifications').insert({
        'type': 'post_rating',
        'target_user_id': postOwnerUid,
        'custom_data': {
          'postId': postId,
          'raterUid': raterUid,
          'rating': rating,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logPostError(
        operationType: 'create_notification_db_write',
        userId: raterUid,
        error: e,
        additionalData: {'postId': postId, 'postOwnerUid': postOwnerUid},
      );
    }

    // ── Step 2: Resolve display name (failure falls back gracefully) ─────────
    String raterUsername = 'Someone';
    try {
      final raterSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', raterUid)
          .maybeSingle();
      final raterData = _unwrap(raterSel) ?? raterSel;
      raterUsername = raterData?['username'] ?? 'Someone';
    } catch (_) {}

    // ── Step 3: Push notification (always attempted, independent of above) ───
    try {
      await _notificationService.triggerServerNotification(
        type: 'post_rating',
        targetUserId: postOwnerUid,
        title: 'New Reaction',
        body: '$raterUsername reacted to your post',
        customData: {'raterId': raterUid, 'postId': postId},
      );
    } catch (e) {
      await _logPostError(
        operationType: 'create_notification_push',
        userId: raterUid,
        error: e,
        additionalData: {'postId': postId, 'postOwnerUid': postOwnerUid},
      );
    }
  }

  // ----------------------
  // Delete previous reaction notification
  // ----------------------
  Future<void> _deletePreviousReactionNotification(
      String postId, String raterUid) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'post_rating')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>raterUid', raterUid);
    } catch (e) {
      await _logPostError(
        operationType: 'delete_previous_reaction_notification',
        userId: raterUid,
        error: e,
        additionalData: {'postId': postId},
      );
    }
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
  // Delete comment
  // ----------------------
  Future<String> deleteComment(String postId, String commentId) async {
    String res = "Some error occurred";
    try {
      await _supabase.from('comments').delete().eq('id', commentId);
      await _changeCommentsCount(postId, -1);
      await _supabase
          .from('notifications')
          .delete()
          .eq('custom_data->>commentId', commentId);
      res = 'success';
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'delete_comment',
        error: err,
        additionalData: {'postId': postId, 'commentId': commentId},
      );
    }
    return res;
  }

  // ----------------------
  // Delete comment-like notification
  // ----------------------
  Future<void> deleteCommentLikeNotification(
      String postId, String commentId, String likerUid) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'comment_like')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>commentId', commentId)
          .eq('custom_data->>likerUid', likerUid);
    } catch (e) {
      await _logPostError(
        operationType: 'delete_comment_like_notification',
        userId: likerUid,
        error: e,
        additionalData: {'postId': postId, 'commentId': commentId},
      );
    }
  }

  // ----------------------
  // Rate a post (react to a post)
  // ----------------------
  Future<String> ratePost(String postId, String uid, double rating) async {
    String res = "Some error occurred";
    String postOwnerUid = '';
    try {
      final roundedRating = double.parse(rating.toStringAsFixed(1));

      final postSel = await _supabase
          .from('posts')
          .select('uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;
      if (postData == null) throw Exception('Post not found');
      postOwnerUid = postData['uid']?.toString() ?? '';

      final existingRating = await _supabase
          .from('post_rating')
          .select('rating')
          .eq('postid', postId)
          .eq('userid', uid)
          .maybeSingle();

      final bool isUpdate = existingRating != null;

      await _supabase.from('post_rating').upsert({
        'postid': postId,
        'userid': uid,
        'rating': roundedRating,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'postid,userid');

      if (uid != postOwnerUid && postOwnerUid.isNotEmpty) {
        if (isUpdate) {
          await _deletePreviousReactionNotification(postId, uid);
        }
        await createNotification(
          postId: postId,
          postOwnerUid: postOwnerUid,
          raterUid: uid,
          rating: roundedRating,
        );
      }

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logPostError(
        operationType: 'rate_post',
        userId: uid,
        error: err,
        additionalData: {'postId': postId, 'rating': rating},
      );
    }
    return res;
  }

  // ----------------------
  // Post comment
  // ----------------------
  Future<String> postComment(String postId, String text, String uid,
      String name, String profilePic) async {
    String res = "Some error occurred";
    try {
      if (text.isEmpty) return "Please enter text";

      final commentId = _uuid.v1();
      await _supabase.from('comments').insert({
        'id': commentId,
        'postid': postId,
        'uid': uid,
        'name': name,
        'comment_text': text,
        'date_published': DateTime.now().toUtc().toIso8601String(),
        'like_count': 0,
      });

      await _changeCommentsCount(postId, 1);

      final postSel = await _supabase
          .from('posts')
          .select('uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;
      final postOwnerUid = postData?['uid']?.toString() ?? '';

      if (uid != postOwnerUid && postOwnerUid.isNotEmpty) {
        await createCommentNotification(postId, uid, text, commentId);

        await _notificationService.triggerServerNotification(
          type: 'comment',
          targetUserId: postOwnerUid,
          title: 'New Comment',
          body: '$name commented: $text',
          customData: {
            'commenterId': uid,
            'postId': postId,
            'commentId': commentId,
          },
        );
      }

      res = 'success';
    } catch (e) {
      res = e.toString();
      await _logPostError(
        operationType: 'post_comment',
        userId: uid,
        error: e,
        additionalData: {'postId': postId, 'text': text},
      );
    }
    return res;
  }

  Future<void> createCommentNotification(
    String postId,
    String commenterUid,
    String commentText,
    String commentId,
  ) async {
    try {
      final postSel = await _supabase
          .from('posts')
          .select('uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;
      final postOwnerUid = postData?['uid']?.toString() ?? '';
      if (postOwnerUid.isEmpty || postOwnerUid == commenterUid) return;

      await _supabase.from('notifications').insert({
        'type': 'comment',
        'target_user_id': postOwnerUid,
        'custom_data': {
          'commenterUid': commenterUid,
          'commentText': commentText,
          'postId': postId,
          'commentId': commentId,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logPostError(
        operationType: 'create_comment_notification',
        userId: commenterUid,
        error: e,
        additionalData: {'postId': postId, 'commentId': commentId},
      );
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
  // Report post / comment
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

  Future<String> reportComment({
    required String postId,
    required String commentId,
    required String reason,
  }) async {
    try {
      await _supabase.from('reports').insert({
        'postId': postId,
        'commentId': commentId,
        'reason': reason,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'type': 'comment',
      });
      return 'success';
    } catch (err) {
      await _logPostError(
        operationType: 'report_comment',
        error: err,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'reason': reason,
        },
      );
      return err.toString();
    }
  }

  // ----------------------
  // Replies
  // ----------------------
  Future<String> postReply({
    required String postId,
    required String commentId,
    required String uid,
    required String name,
    required String profilePic,
    required String text,
    String? parentReplyId,
  }) async {
    try {
      final replyId = _uuid.v1();

      await _supabase.from('replies').insert({
        'id': replyId,
        'postid': postId,
        'commentid': commentId,
        'uid': uid,
        'name': name,
        'reply_text': text,
        'date_published': DateTime.now().toUtc().toIso8601String(),
        'like_count': 0,
        'parent_reply_id': parentReplyId,
      });

      String parentOwnerUid = '';
      if (parentReplyId != null) {
        final sel = await _supabase
            .from('replies')
            .select('uid')
            .eq('id', parentReplyId)
            .maybeSingle();
        final d = _unwrap(sel) ?? sel;
        parentOwnerUid = d?['uid']?.toString() ?? '';
      } else {
        final sel = await _supabase
            .from('comments')
            .select('uid')
            .eq('id', commentId)
            .maybeSingle();
        final d = _unwrap(sel) ?? sel;
        parentOwnerUid = d?['uid']?.toString() ?? '';
      }

      if (parentOwnerUid.isNotEmpty && parentOwnerUid != uid) {
        await createReplyNotification(
          postId: postId,
          commentId: commentId,
          replyId: replyId,
          replyOwnerUid: parentOwnerUid,
          replierUid: uid,
          replyText: text,
        );
      }

      return 'success';
    } catch (e) {
      await _logPostError(
        operationType: 'post_reply',
        userId: uid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'text': text,
          'parentReplyId': parentReplyId,
        },
      );
      return e.toString();
    }
  }

  Future<String> deleteReply({
    required String postId,
    required String commentId,
    required String replyId,
  }) async {
    try {
      await _supabase.from('replies').delete().eq('id', replyId);
      await _supabase
          .from('notifications')
          .delete()
          .eq('custom_data->>replyId', replyId);
      return 'success';
    } catch (e) {
      await _logPostError(
        operationType: 'delete_reply',
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
        },
      );
      return e.toString();
    }
  }

  Future<Map<String, dynamic>> likeReply({
    required String postId,
    required String commentId,
    required String replyId,
    required String uid,
  }) async {
    try {
      final likeCheck = await _supabase
          .from('reply_likes')
          .select()
          .eq('reply_id', replyId)
          .eq('uid', uid)
          .maybeSingle();

      final alreadyLiked = likeCheck != null;

      if (alreadyLiked) {
        await _supabase
            .from('reply_likes')
            .delete()
            .eq('reply_id', replyId)
            .eq('uid', uid);

        final replySel = await _supabase
            .from('replies')
            .select('like_count')
            .eq('id', replyId)
            .maybeSingle();

        final replyData = _unwrap(replySel) ?? replySel;
        int newCount = 0;
        if (replyData != null) {
          int currentCount = replyData['like_count'] ?? 0;
          newCount = (currentCount - 1).clamp(0, 99999);
          await _supabase
              .from('replies')
              .update({'like_count': newCount}).eq('id', replyId);
        }

        await deleteReplyLikeNotification(postId, commentId, replyId, uid);
        return {'action': 'unliked', 'like_count': newCount, 'is_liked': false};
      } else {
        await _supabase.from('reply_likes').insert({
          'reply_id': replyId,
          'uid': uid,
          'liked_at': DateTime.now().toUtc().toIso8601String(),
        });

        final replySel = await _supabase
            .from('replies')
            .select('like_count, uid, reply_text')
            .eq('id', replyId)
            .maybeSingle();

        final replyData = _unwrap(replySel) ?? replySel;
        int newCount = 0;
        if (replyData != null) {
          int currentCount = replyData['like_count'] ?? 0;
          newCount = currentCount + 1;

          await _supabase
              .from('replies')
              .update({'like_count': newCount}).eq('id', replyId);

          final String replyOwnerUid = replyData['uid'];
          final String replyText = replyData['reply_text'] ?? '';

          if (replyOwnerUid != uid) {
            await createReplyLikeNotification(
              postId: postId,
              commentId: commentId,
              replyId: replyId,
              replyOwnerUid: replyOwnerUid,
              likerUid: uid,
              replyText: replyText,
            );
          }
        }

        return {'action': 'liked', 'like_count': newCount, 'is_liked': true};
      }
    } catch (e) {
      await _logPostError(
        operationType: 'like_reply',
        userId: uid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
        },
      );
      return {'action': 'error', 'error': e.toString()};
    }
  }

  Future<void> deleteReplyLikeNotification(
    String postId,
    String commentId,
    String replyId,
    String likerUid,
  ) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'reply_like')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>commentId', commentId)
          .eq('custom_data->>replyId', replyId)
          .eq('custom_data->>likerUid', likerUid);
    } catch (e) {
      await _logPostError(
        operationType: 'delete_reply_like_notification',
        userId: likerUid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
        },
      );
    }
  }

  Future<void> createReplyNotification({
    required String postId,
    required String commentId,
    required String replyId,
    required String replyOwnerUid,
    required String replierUid,
    required String replyText,
  }) async {
    try {
      if (replyOwnerUid == replierUid) return;

      await _supabase.from('notifications').insert({
        'type': 'reply',
        'target_user_id': replyOwnerUid,
        'custom_data': {
          'replierUid': replierUid,
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
          'replyText': replyText,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      final replierSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', replierUid)
          .maybeSingle();
      final replierData = _unwrap(replierSel) ?? replierSel;
      final String replierName = replierData?['username'] ?? 'Someone';

      await _notificationService.triggerServerNotification(
        type: 'reply',
        targetUserId: replyOwnerUid,
        title: 'New Reply',
        body: '$replierName replied: $replyText',
        customData: {
          'replierId': replierUid,
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
        },
      );
    } catch (e) {
      await _logPostError(
        operationType: 'create_reply_notification',
        userId: replierUid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
          'replyOwnerUid': replyOwnerUid,
        },
      );
    }
  }

  Future<void> createReplyLikeNotification({
    required String postId,
    required String commentId,
    required String replyId,
    required String replyOwnerUid,
    required String likerUid,
    required String replyText,
  }) async {
    try {
      if (replyOwnerUid == likerUid) return;

      await _supabase.from('notifications').insert({
        'type': 'reply_like',
        'target_user_id': replyOwnerUid,
        'custom_data': {
          'likerUid': likerUid,
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
          'replyText': replyText,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      final likerSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', likerUid)
          .maybeSingle();
      final likerData = _unwrap(likerSel) ?? likerSel;
      final String likerName = likerData?['username'] ?? 'Someone';

      await _notificationService.triggerServerNotification(
        type: 'reply_like',
        targetUserId: replyOwnerUid,
        title: 'Reply Liked',
        body: '$likerName liked your reply',
        customData: {
          'likerId': likerUid,
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
        },
      );
    } catch (e) {
      await _logPostError(
        operationType: 'create_reply_like_notification',
        userId: likerUid,
        error: e,
        additionalData: {
          'postId': postId,
          'commentId': commentId,
          'replyId': replyId,
          'replyOwnerUid': replyOwnerUid,
        },
      );
    }
  }

  // ----------------------
  // First-post nudge notification
  //
  // FIX 1: The send-time is now persisted to SharedPreferences so the nudge
  //         survives the app being backgrounded during the 59-second wait.
  // FIX 2: trySendNudge() is public so the app's AppLifecycleState.resumed
  //         handler can re-check and fire the nudge after the app foregrounds.
  //
  // HOW TO CALL AT REGISTRATION (in your sign-up flow, after the user row is
  // created in Supabase — do NOT await, this must be fire-and-forget):
  //
  //   import 'dart:async' show unawaited;
  //   unawaited(SupabasePostsMethods().scheduleFirstPostNudge(newUser.uid));
  //
  // HOW TO HOOK INTO APP LIFECYCLE (in your root widget):
  //
  //   @override
  //   void didChangeAppLifecycleState(AppLifecycleState state) {
  //     if (state == AppLifecycleState.resumed) {
  //       SupabasePostsMethods().trySendNudge();
  //     }
  //   }
  // ----------------------
  Future<void> scheduleFirstPostNudge(String userId) async {
    try {
      // Only schedule for test-group users
      final userRow = await _supabase
          .from('users')
          .select('test')
          .eq('uid', userId)
          .maybeSingle();

      final bool isTestGroup = userRow?['test'] ?? false;
      if (!isTestGroup) return;

      // Skip if they already have a post
      final existing = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', userId)
          .limit(1)
          .maybeSingle();
      if (existing != null) return;

      // Persist the target send-time and userId so it survives backgrounding
      final prefs = await SharedPreferences.getInstance();
      final sendAt = DateTime.now()
          .toUtc()
          .add(const Duration(seconds: 59))
          .toIso8601String();
      await prefs.setString('nudge_send_at_$userId', sendAt);
      await prefs.setString('nudge_user_id', userId);

      // Also attempt via an in-process timer — works when the app stays open
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

  /// Checks SharedPreferences for a pending nudge and sends it if the
  /// scheduled time has passed and the user still has no posts.
  ///
  /// Call this:
  ///   • From the Future.delayed callback inside scheduleFirstPostNudge
  ///     (covers the case where the app stays open the whole time).
  ///   • From didChangeAppLifecycleState when state == AppLifecycleState.resumed
  ///     (covers the case where the app was backgrounded during the wait).
  Future<void> trySendNudge() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('nudge_user_id');
      if (userId == null || userId.isEmpty) return;

      final sendAtStr = prefs.getString('nudge_send_at_$userId');
      if (sendAtStr == null) return;

      final sendAt = DateTime.parse(sendAtStr);
      if (DateTime.now().toUtc().isBefore(sendAt)) return; // not yet time

      // Check if they posted during the wait
      final check = await _supabase
          .from('posts')
          .select('postId')
          .eq('uid', userId)
          .limit(1)
          .maybeSingle();

      // Clear the pending nudge regardless of outcome to prevent double-send
      await prefs.remove('nudge_send_at_$userId');
      await prefs.remove('nudge_user_id');

      if (check != null) return; // user posted — skip the nudge

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

  // ----------------------
  // Helper: change commentsCount
  // ----------------------
  Future<void> _changeCommentsCount(String postId, int delta) async {
    try {
      final sel = await _supabase
          .from('posts')
          .select('commentsCount')
          .eq('postId', postId)
          .maybeSingle();
      final data = _unwrap(sel) ?? sel;
      int current = 0;
      if (data != null) {
        final val = data['commentsCount'];
        if (val is int)
          current = val;
        else if (val is String)
          current = int.tryParse(val) ?? current;
        else if (val is num) current = val.toInt();
      }
      int updated = (current + delta).clamp(0, 99999);
      await _supabase
          .from('posts')
          .update({'commentsCount': updated}).eq('postId', postId);
    } catch (e) {
      await _logPostError(
        operationType: 'change_comments_count',
        error: e,
        additionalData: {'postId': postId, 'delta': delta},
      );
    }
  }
}
