import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:Ratedly/services/notification_service.dart';

class SupabaseCommentsMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final NotificationService _notificationService = NotificationService();
  final Uuid _uuid = const Uuid();

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

  // ----------------------
  // Helper: change commentsCount on a post
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

  // ----------------------
  // Post a comment
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
        await _createCommentNotification(postId, uid, text, commentId);

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

  Future<void> _createCommentNotification(
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
  // Delete a comment
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
  // Like / unlike a comment
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

        await _deleteCommentLikeNotification(postId, commentId, uid);
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
            await _createCommentLikeNotification(
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

  Future<void> _createCommentLikeNotification({
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

  Future<void> _deleteCommentLikeNotification(
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
  // Report a comment
  // ----------------------
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
        await _createReplyNotification(
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

        await _deleteReplyLikeNotification(postId, commentId, replyId, uid);
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
            await _createReplyLikeNotification(
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

  Future<void> _deleteReplyLikeNotification(
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

  Future<void> _createReplyNotification({
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

  Future<void> _createReplyLikeNotification({
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
}
